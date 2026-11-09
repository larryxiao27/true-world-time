import SwiftUI
import WidgetKit
import Network
import AppKit

final class ProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    let url: URL
    init() {
        let path = Bundle.main.object(forInfoDictionaryKey: "ProbeEvidenceDirectory") as? String ?? NSTemporaryDirectory()
        let directory = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("native-run-" + UUID().uuidString + ".jsonl")
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
    @Published var pauseNetwork = false
    private var windowVisible = false
    private var server: LoopbackSnapshotServer?
    private var previousWall = Date().timeIntervalSince1970
    private var previousContinuous = ContinuousTime.now
    private var lastAutomaticSync = ContinuousTime.now
    private var tickTask: Task<Void, Never>?
    init() {
        snapshot = engine.snapshot()
        log.write("app_launch", snapshot: snapshot)
        do { server = try LoopbackSnapshotServer(engine: engine, log: log) }
        catch { lastMessage = "本地快照服务失败：\(error.localizedDescription)" }
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
        if windowVisible { snapshot = current }
        let wallElapsed = current.systemUTC - previousWall
        let continuousElapsed = current.continuous - previousContinuous
        if abs(wallElapsed - continuousElapsed) > 0.75 {
            log.write("system_clock_jump", snapshot: current, note: "jumpSeconds=\(wallElapsed-continuousElapsed)")
            lastMessage = "检测到系统改时，已请求小组件刷新"
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
        if pauseNetwork {
            engine.markNetworkFailure(); tick()
            log.write("injected_network_failure", snapshot: engine.snapshot())
            lastMessage = "测试注入：暂停网络请求，沿用独立计时（不等于实际断网）"
            WidgetCenter.shared.reloadAllTimelines(); return
        }
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
        lastMessage = succeeded ? "独立网络校准成功" : "网络校时失败，已明确标记保持状态"
        lastAutomaticSync = ContinuousTime.now
        WidgetCenter.shared.reloadAllTimelines()
    }
    func refreshWidget() {
        log.write("manual_widget_reload", snapshot: engine.snapshot())
        WidgetCenter.shared.reloadAllTimelines()
        lastMessage = "已请求刷新；实际显示时间需单独观察"
    }
}

struct ProbeSettingsView: View {
    @ObservedObject var model: ProbeModel
    var hideWindow: () -> Void
    @AppStorage(ClockHourFormat.preferenceKey) private var hourFormat: ClockHourFormat = .twentyFour
    var body: some View {
            VStack(alignment: .leading, spacing: 18) {
                Text("真世界时 · 技术验证 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")").font(.title2.weight(.semibold))
                HStack(spacing: 30) {
                    clock("独立真实时间", model.snapshot.trueUTC)
                    clock("系统时间", model.snapshot.systemUTC)
                }
                Divider()
                Picker("小时制", selection: $hourFormat) {
                    Text("24 小时制").tag(ClockHourFormat.twentyFour)
                    Text("12 小时制").tag(ClockHourFormat.twelve)
                }.pickerStyle(.segmented).frame(width: 270)
                    .onChange(of: hourFormat) { _, _ in model.refreshWidget() }
                LabeledContent("系统偏差", value: model.snapshot.correction.map { String(format: "%+.3f 秒", -$0) } ?? "尚未校准")
                LabeledContent("状态", value: model.snapshot.status)
                LabeledContent("来源", value: model.snapshot.source ?? "无")
                LabeledContent("校准年龄", value: model.snapshot.sampleAge.map { String(format: "%.0f 秒", $0) } ?? "—")
                LabeledContent("样本不确定度估计", value: model.snapshot.uncertainty.map { String(format: "± %.3f 秒", $0) } ?? "—")
                Text(model.lastMessage).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("重新校准") { Task { await model.calibrate() } }.disabled(model.syncing)
                    Button("请求小组件刷新") { model.refreshWidget() }
                }
                Toggle("注入网络失败（仅用于对照测试）", isOn: $model.pauseNetwork)
                    .onChange(of: model.pauseNetwork) { _, _ in Task { await model.calibrate() } }
                HStack {
                    Button("收起到后台", action: hideWindow)
                    Spacer()
                    Button("退出真世界时") { NSApplication.shared.terminate(nil) }
                }
                Text("请在系统「编辑小组件」中添加「真世界时验证」。此窗口运行正确不代表原生小组件通过。").font(.caption).foregroundStyle(.secondary)
                Text("日志：\(model.log.url.path)").font(.caption2).textSelection(.enabled)
            }.padding(26).frame(width: 650)
    }
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
        let applicationMenu = NSMenu(title: "真世界时")
        let settings = NSMenuItem(title: "打开设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title: "退出真世界时", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
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
            window.title = "真世界时 · 设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 650, height: 600))
            window.center()
            settingsWindow = window
        }
        model.setWindowVisible(true)
        if settingsWindow?.isMiniaturized == true { settingsWindow?.deminiaturize(nil) }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
    }
    private func hideSettings() {
        settingsWindow?.orderOut(nil)
        model.setWindowVisible(false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideSettings()
        return false
    }
    func windowDidMiniaturize(_ notification: Notification) { model.setWindowVisible(false) }
    func windowDidDeminiaturize(_ notification: Notification) { model.setWindowVisible(true) }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = settingsWindow else { return }
        model.setWindowVisible(window.isVisible && window.occlusionState.contains(.visible))
    }
}

@main struct TrueWorldTimeProbeApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = BackgroundAppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
