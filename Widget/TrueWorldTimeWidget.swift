import SwiftUI
import WidgetKit
import Foundation

struct ProbeEntry: TimelineEntry {
    var date: Date
    var snapshot: TimeSnapshot?
    var problem: String?
    var projection: WidgetClockProjection? = nil
    var systemProjection: WidgetClockProjection? = nil
}

struct ProbeProvider: TimelineProvider {
    func placeholder(in context: Context) -> ProbeEntry { ProbeEntry(date: .now, problem: "尚未校准") }
    func getSnapshot(in context: Context, completion: @escaping (ProbeEntry) -> Void) {
        completion(ProbeEntry(date: .now, problem: "运行验证 App 后读取真实校准"))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ProbeEntry>) -> Void) {
        // Detached from the app: only the system's actual widget renderer can validate this path.
        let box = CompletionBox(completion)
        Task {
            var entries: [ProbeEntry]
            do {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:45931/time")!)
                request.timeoutInterval = 3; request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ClockError.message("本地快照请求失败") }
                let sample = try JSONDecoder().decode(TimeSnapshot.self, from: data)
                let now = Date()
                let elapsed = ContinuousTime.now - sample.continuous
                if let utc = sample.trueUTC, sample.bootID == ContinuousTime.bootID, elapsed >= 0 {
                    var real = Date(timeIntervalSince1970: utc + elapsed)
                    var system = now
                    let hourFormat = sample.hourFormat ?? .twentyFour
                    entries = []
                    // Both clocks can cross an hour boundary at different times.
                    // Prepare up to a day of anchors, including AM/PM and DST changes.
                    for _ in 0..<60 {
                        guard let projection = WidgetClockProjection(realDate: real, systemDate: system, timeZone: .current, hourFormat: hourFormat),
                              let systemProjection = WidgetClockProjection(realDate: system, systemDate: system, timeZone: .current, hourFormat: hourFormat) else { break }
                        entries.append(ProbeEntry(date: system, snapshot: sample, projection: projection, systemProjection: systemProjection))
                        if system.timeIntervalSince(now) >= 86400 { break }
                        let next = min(projection.nextBoundary, systemProjection.nextBoundary)
                        let delta = next.timeIntervalSince(system)
                        guard delta > 0 else { break }
                        real = real.addingTimeInterval(delta)
                        system = next
                    }
                    if entries.isEmpty { entries = [ProbeEntry(date: now, problem: "无法构建校准显示")] }
                } else { entries = [ProbeEntry(date: now, problem: "网络尚未校准")] }
            } catch {
                entries = [ProbeEntry(date: .now, problem: "请保持验证 App 运行")]
            }
            box.complete(Timeline(entries: entries, policy: .after(Date().addingTimeInterval(900))))
        }
    }
}

// WidgetKit's callback is called exactly once, from the one producer task.
final class CompletionBox: @unchecked Sendable {
    private let callback: (Timeline<ProbeEntry>) -> Void
    init(_ callback: @escaping (Timeline<ProbeEntry>) -> Void) { self.callback = callback }
    func complete(_ timeline: Timeline<ProbeEntry>) { callback(timeline) }
}

struct ProbeWidgetView: View {
    let entry: ProbeEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text("真世界时验证").font(.caption.weight(.semibold)); Spacer(); Text("原生验证 0.6").font(.system(size: 9)).foregroundStyle(.secondary) }
            if let sample = entry.snapshot, let correction = sample.correction, let utc = sample.trueUTC, let projection = entry.projection, let systemProjection = entry.systemProjection {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("独立校准 · 计时锚点").font(.system(size: 10))
                        CalibratedClockText(projection: projection)
                            .font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(width: 140, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统 · 动态文本").font(.system(size: 10)).foregroundStyle(.secondary)
                        CalibratedClockText(projection: systemProjection)
                            .font(.system(size: 23, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(width: 140, alignment: .leading)
                    }
                }
                Text("抓取时真值 " + (sample.hourFormat ?? .twentyFour).string(from: Date(timeIntervalSince1970: utc)))
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                Text(String(format: "系统快 %+.1f 秒 · 样本 #%d", -correction, sample.generation)).font(.system(size: 10))
                Text(sample.status + " · 这是验证组件").font(.system(size: 9)).foregroundStyle(.secondary)
            } else {
                Text(entry.problem ?? "尚未校准").font(.callout)
                Text("不会用系统时间冒充真实时间").font(.caption).foregroundStyle(.secondary)
            }
        }.containerBackground(.background, for: .widget)
    }
}

struct CalibratedClockText: View {
    let projection: WidgetClockProjection
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(.durationOffset(to: projection.anchor), format: .time(pattern: .hourMinuteSecond(padHourToLength: 2, roundFractionalSeconds: .down)))
            if let period = projection.period { Text(period).font(.system(size: 10, weight: .medium)) }
        }
    }
}

#if !PROBE_RENDER_TEST
@main struct TrueWorldTimeProbeWidget: Widget {
    let kind = "TrueWorldTimeProbeWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ProbeProvider()) { entry in ProbeWidgetView(entry: entry) }
            .configurationDisplayName("真世界时验证")
            .description("验证独立校时与系统时间变化，不是正式产品。")
            .supportedFamilies([.systemMedium])
    }
}
#endif
