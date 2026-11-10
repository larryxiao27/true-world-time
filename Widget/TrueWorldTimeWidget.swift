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
        completion(ProbeEntry(date: .now, problem: "打开我的时区以完成校时"))
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
                    if entries.isEmpty { entries = [ProbeEntry(date: now, problem: "暂时无法显示时间，请重新校时")] }
                } else { entries = [ProbeEntry(date: now, problem: "等待网络校时")] }
            } catch {
                entries = [ProbeEntry(date: .now, problem: "打开我的时区以更新时间")]
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
            Text("我的时区").font(.caption.weight(.semibold))
            if let sample = entry.snapshot, let projection = entry.projection, let systemProjection = entry.systemProjection {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("真实时间").font(.system(size: 11)).foregroundStyle(.secondary)
                        CalibratedClockText(projection: projection)
                            .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(width: 140, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("系统时间").font(.system(size: 11)).foregroundStyle(.secondary)
                        CalibratedClockText(projection: systemProjection)
                            .font(.system(size: 26, weight: .medium, design: .rounded)).monospacedDigit()
                            .frame(width: 140, alignment: .leading)
                    }
                }
                HStack {
                    Text("系统" + ClockPresentation.systemDifference(correction: sample.correction))
                    Spacer()
                    Text(ClockPresentation.status(sample.status)).foregroundStyle(.secondary)
                }.font(.system(size: 10))
                Text("最近校时 " + ClockPresentation.lastSync(sample, hourFormat: sample.hourFormat ?? .twentyFour))
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text(entry.problem ?? "尚未校准").font(.callout)
                Text("联网并打开 App 后自动校时").font(.caption).foregroundStyle(.secondary)
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
            .configurationDisplayName("我的时区")
            .description("独立网络校时，随时分清真实时间与系统时间。")
            .supportedFamilies([.systemMedium])
    }
}
#endif
