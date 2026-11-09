import Foundation
import Dispatch

/// Isolated collector benchmark. Does not launch an app, open a window or register login items.
@main struct ResourceCostCheck {
    static func main() throws {
        let before = SystemResourceReader.physicalFootprint() ?? 0
        let hardware = HardwareSummary.current
        var readerCreations = 0
        let monitor = VisibleResourceMonitor {
            readerCreations += 1
            return SystemResourceReader()
        }
        for index in 0..<10_000 { _ = monitor.sampleIfDue(at: Double(index)) }
        let hiddenReaderCreations = readerCreations
        monitor.setVisible(true)
        for index in 0..<200 { _ = monitor.sampleIfDue(at: Double(index) * 2) }
        let warm = SystemResourceReader.physicalFootprint() ?? 0
        let start = DispatchTime.now().uptimeNanoseconds
        var peak = warm
        var atTenThousand = warm
        var atHundredThousand = warm
        for index in 200..<1_000_200 {
            _ = monitor.sampleIfDue(at: Double(index) * 2)
            if index % 1000 == 0 { peak = max(peak, SystemResourceReader.physicalFootprint() ?? 0) }
            if index == 10_199 { atTenThousand = SystemResourceReader.physicalFootprint() ?? 0 }
            if index == 100_199 { atHundredThousand = SystemResourceReader.physicalFootprint() ?? 0 }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        let after = SystemResourceReader.physicalFootprint() ?? 0
        monitor.setVisible(false)
        for index in 1_000_200..<1_010_200 { _ = monitor.sampleIfDue(at: Double(index) * 2) }
        let afterHide = SystemResourceReader.physicalFootprint() ?? 0
        let report: [String: Any] = [
            "scope": "Isolated kernel-counter collector; not a full application or UI memory comparison",
            "hiddenReaderCreations": hiddenReaderCreations,
            "totalReaderCreations": readerCreations,
            "visibleSamplesAfterWarmup": 1_000_000,
            "averageMicrosecondsPerSample": elapsed / 1_000_000 * 1_000_000,
            "initialFootprintBytes": before,
            "warmFootprintBytes": warm,
            "afterStressFootprintBytes": after,
            "afterTenThousandFootprintBytes": atTenThousand,
            "afterHundredThousandFootprintBytes": atHundredThousand,
            "growthFromHundredThousandToMillionBytes": Int64(after) - Int64(atHundredThousand),
            "peakAfterWarmupBytes": max(peak, after),
            "afterHiddenFootprintBytes": afterHide,
            "initializationDeltaBytes": Int64(warm) - Int64(before),
            "steadyStateDeltaBytes": Int64(after) - Int64(warm),
            "physicalMemoryBytes": hardware.memoryBytes
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        print(String(decoding: data, as: UTF8.self))
        guard hiddenReaderCreations == 0, readerCreations == 1 else { fatalError("Background collector gate failed") }
    }
}
