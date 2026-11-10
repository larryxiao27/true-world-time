import SwiftUI
import WidgetKit
import Network
import AppKit

final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    let url: URL
    init() {
        let directory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/TrueWorldTime", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("session-" + UUID().uuidString + ".jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        encoder.outputFormatting = [.sortedKeys]
    }
    func write(_ event: String, snapshot: TimeSnapshot, note: String = "") {
        struct Record: Encodable { let event: String; let snapshot: TimeSnapshot; let note: String }
        lock.withLock {
            guard let data = try? encoder.encode(Record(event: event, snapshot: snapshot, note: note)), let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data + Data([10]))
        }
    }
}

// Diagnostic-only transport. Binds loopback explicitly, never a LAN interface.
final class LoopbackSnapshotServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.xiaonan.trueworld.probe.loopback")
    private let listener: NWListener
    init(engine: ClockEngine, log: ProbeLog) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 45931)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, error in
                guard error == nil else { connection.cancel(); return }
                var snapshot = engine.snapshot()
                snapshot.hourFormat = ClockHourFormat(rawValue: UserDefaults.standard.string(forKey: ClockHourFormat.preferenceKey) ?? "") ?? .twentyFour
                log.write("widget_snapshot_request", snapshot: snapshot)
                let body = (try? JSONEncoder().encode(snapshot)) ?? Data("{}".utf8)
                let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.stateUpdateHandler = { state in log.write("loopback_listener", snapshot: engine.snapshot(), note: String(describing: state)) }
        listener.start(queue: queue)
    }
}

@MainActor final class ProbeModel: ObservableObject {
    let engine = ClockEngine()
    let log = ProbeLog()
    @Published var snapshot: TimeSnapshot
    @Published var lastMessage = "正在校准"
    @Published var syncing = false
    @Published private(set) var resources: ResourceSnapshot?
    private lazy var resourceMonitor = VisibleResourceMonitor()
    private var windowVisible = false
    private var server: LoopbackSnapshotServer?
    private var previousWall = Date().timeIntervalSince1970
    private var previousContinuous = ContinuousTime.now
    private var lastAutomaticSync = ContinuousTime.now
    private var tickTask: Task<Void, Never>?
    init(startServices: Bool = true) {
        snapshot = engine.snapshot()
        guard startServices else { return }
        log.write("app_launch", snapshot: snapshot)
        do { server = try LoopbackSnapshotServer(engine: engine, log: log) }
        catch { lastMessage = "时间服务未能启动，请退出后重新打开。" }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.log.write("will_sleep", snapshot: self.engine.snapshot()) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.log.write("did_wake", snapshot: self.engine.snapshot())
                self.tick(forceReload: true); await self.calibrate()
            }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.log.write("system_clock_notification", snapshot: self.engine.snapshot())
                self.tick(forceReload: true)
            }
        }
        NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.log.write("time_zone_changed", snapshot: self.engine.snapshot())
                self.tick(forceReload: true)
            }
        }
        startMonitoring()
        Task { await calibrate() }
    }
    func setWindowVisible(_ visible: Bool) {
        guard windowVisible != visible else { return }
        windowVisible = visible
        resourceMonitor.setVisible(visible)
        if !visible { resources = nil }
        log.write(visible ? "settings_shown" : "settings_hidden", snapshot: engine.snapshot())
        tick()
    }
    private func startMonitoring() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Preserve the validated one-second jump-detection fallback.
                // Hidden settings do not repaint or write a per-second log.
                do { try await Task.sleep(for: .seconds(1), clock: .continuous) }
                catch { return }
                self.tick()
            }
        }
    }
    func tick(forceReload: Bool = false) {
        let current = engine.snapshot()
        if windowVisible {
            snapshot = current
            if let sample = resourceMonitor.sampleIfDue(at: current.continuous) { resources = sample }
        }
        let wallElapsed = current.systemUTC - previousWall
        let continuousElapsed = current.continuous - previousContinuous
        if abs(wallElapsed - continuousElapsed) > 0.75 {
            log.write("system_clock_jump", snapshot: current, note: "jumpSeconds=\(wallElapsed-continuousElapsed)")
            lastMessage = "检测到系统时间变化，已请求更新小组件"
        }
        if forceReload || abs(wallElapsed - continuousElapsed) > 0.75 {
            WidgetCenter.shared.reloadAllTimelines()
        }
        previousWall = current.systemUTC; previousContinuous = current.continuous
        if current.continuous - lastAutomaticSync > 900 {
            lastAutomaticSync = current.continuous
            Task { await calibrate() }
        }
    }
    func calibrate() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        var succeeded = false
        for host in ["time.apple.com", "time.cloudflare.com"] {
            do {
                let sample = try await SNTPClient.query(host: host)
                let previous = engine.snapshot(continuous: sample.continuous).trueUTC
                engine.accept(sample)
                let disagreement = previous.map { sample.utc - $0 }
                log.write("network_calibrated", snapshot: engine.snapshot(), note: "host=\(host); rtt=\(sample.roundTrip); priorDisagreement=\(disagreement.map(String.init(describing:)) ?? "none")")
                succeeded = true
            } catch {
                log.write("network_error", snapshot: engine.snapshot(), note: error.localizedDescription)
            }
        }
        if !succeeded { engine.markNetworkFailure() }
        snapshot = engine.snapshot()
        lastMessage = succeeded ? "校时完成" : (snapshot.trueUTC == nil ? "暂时无法获取时间，请联网后重试" : "暂时无法校时，继续使用上次校准")
        lastAutomaticSync = ContinuousTime.now
        WidgetCenter.shared.reloadAllTimelines()
    }
    func refreshWidget() {
        log.write("manual_widget_reload", snapshot: engine.snapshot())
        WidgetCenter.shared.reloadAllTimelines()
        lastMessage = "已请求更新小组件"
    }
}

struct ProbeSettingsView: View {
    @ObservedObject var model: ProbeModel
    @StateObject private var login = LoginItemController()
    var hideWindow: () -> Void
    @AppStorage(ClockHourFormat.preferenceKey) private var hourFormat: ClockHourFormat = .twentyFour
    var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("我的时区").font(.title2.weight(.semibold))
                    Spacer()
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.caption).foregroundStyle(.secondary)
                }
                Text("每个人都有自己的时区。").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 30) {
                    clock("真实时间", model.snapshot.trueUTC)
                    clock("系统时间", model.snapshot.systemUTC)
                }
                Divider()
                HStack {
                    Picker("小时制", selection: $hourFormat) {
                        Text("24 小时制").tag(ClockHourFormat.twentyFour)
                        Text("12 小时制").tag(ClockHourFormat.twelve)
                    }.pickerStyle(.segmented).frame(width: 270)
                        .onChange(of: hourFormat) { _, _ in model.refreshWidget() }
                    Spacer()
                    Toggle("登录 Mac 时启动", isOn: Binding(get: { login.requested }, set: { enabled in
                        Task { await login.setEnabled(enabled) }
                    })).toggleStyle(.switch).disabled(login.busy)
                }
                HStack {
                    Text(login.errorMessage ?? login.statusText).font(.caption).foregroundStyle(login.errorMessage == nil ? Color.secondary : Color.red)
                    Spacer()
                    if login.status == .requiresApproval { Button("打开登录项设置") { login.openSettings() }.font(.caption) }
                }
                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 9) {
                        Text("校时状态").font(.headline)
                        LabeledContent("系统偏差", value: ClockPresentation.systemDifference(correction: model.snapshot.correction))
                        LabeledContent("状态", value: ClockPresentation.status(model.snapshot.status))
                        LabeledContent("最近校时", value: ClockPresentation.lastSync(model.snapshot, hourFormat: hourFormat))
                        LabeledContent("时间来源", value: model.snapshot.source ?? "等待获取")
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 9) {
                        Text("运行状态").font(.headline)
                        LabeledContent("整机 CPU", value: percent(model.resources?.systemCPUPercent))
                        LabeledContent("App CPU（单核）", value: percent(model.resources?.appCPUPercent))
                        LabeledContent("App 内存", value: model.resources?.appMemoryBytes.map { String(format: "%.1f MiB", Double($0) / 1_048_576) } ?? "—")
                        LabeledContent("占整机内存", value: model.resources?.appMemoryBytes.map { String(format: "%.2f%%", Double($0) / Double(HardwareSummary.current.memoryBytes) * 100) } ?? "—")
                        Text("每 2 秒更新，后台停止采样").font(.caption).foregroundStyle(.secondary)
                    }.monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
                }.font(.callout)
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(HardwareSummary.current.chip) · \(HardwareSummary.current.physicalCores) 核 / \(HardwareSummary.current.logicalCores) 线程 · \(HardwareSummary.current.memoryBytes / 1_073_741_824) GiB 内存")
                    Text("\(HardwareSummary.current.model) · \(HardwareSummary.current.systemVersion)").foregroundStyle(.secondary)
                }.font(.caption)
                Text(model.lastMessage).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("立即校时") { Task { await model.calibrate() } }.disabled(model.syncing)
                    Button("更新小组件") { model.refreshWidget() }
                }
                HStack {
                    Button("收起到后台", action: hideWindow)
                    Spacer()
                    Button("退出我的时区") { NSApplication.shared.terminate(nil) }
                }
                Text("在桌面或通知中心添加「我的时区」，随时查看真实时间。").font(.caption).foregroundStyle(.secondary)
            }.padding(26).frame(width: 720)
                .onAppear { login.refresh() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in login.refresh() }
    }
    private func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "采样中…" }
    private func clock(_ title: String, _ utc: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(utc.map { hourFormat.string(from: Date(timeIntervalSince1970: $0)) } ?? "--:--:--")
                .font(.system(size: 36, weight: .light, design: .rounded)).monospacedDigit()
        }
    }
}

@MainActor final class BackgroundAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = ProbeModel()
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "我的时区")
        let settings = NSMenuItem(title: "打开设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "退出我的时区", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApplication.shared.mainMenu = menu
        // Startup is silent. Finder/Spotlight reopen events explicitly show settings.
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }
    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            let content = ProbeSettingsView(model: model) { [weak self] in self?.hideSettings() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "我的时区 · 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.setContentSize(NSSize(width: 720, height: 640))
            window.center()
            settingsWindow = window
        }
        model.setWindowVisible(true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
    private func hideSettings() {
        settingsWindow?.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        model.setWindowVisible(false)
        window.contentViewController = nil
        window.contentView = nil
        settingsWindow = nil
    }
    func windowDidMiniaturize(_ notification: Notification) { model.setWindowVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setWindowVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = settingsWindow else { return }
        model.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible))
    }
}

#if !PROBE_SETTINGS_RENDER_TEST
@main struct TrueWorldTimeProbeApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BackgroundAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
