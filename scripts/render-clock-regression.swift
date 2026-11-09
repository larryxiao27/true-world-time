import SwiftUI
import AppKit
import Vision

/// Offscreen rendering of the actual production text component. Opens no UI.
@main struct ClockRenderRegression {
    @MainActor static func main() throws {
        let wall = Date()
        let correction = -597.3269
        let real = wall.addingTimeInterval(correction)
        guard let projection = WidgetClockProjection(realDate: real, systemDate: wall, timeZone: .current) else { fatalError("Projection failed") }
        let system24 = WidgetClockProjection(realDate: wall, systemDate: wall, timeZone: .current)!
        let real12 = WidgetClockProjection(realDate: real, systemDate: wall, timeZone: .current, hourFormat: .twelve)!
        let system12 = WidgetClockProjection(realDate: wall, systemDate: wall, timeZone: .current, hourFormat: .twelve)!
        let oldZone = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT(for: wall) + Int(correction.rounded()))!
        let oldFormat = Date.FormatStyle(date: .omitted, time: .standard, locale: Locale(identifier: "en_GB"), timeZone: oldZone)
        let expected = ClockHourFormat.twentyFour.string(from: real)
        let content = VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) { Text("OLD").frame(width: 160, alignment: .leading); Text(.currentDate, format: oldFormat).frame(width: 230, alignment: .leading) }
            HStack(spacing: 12) { Text("NEW").frame(width: 160, alignment: .leading); CalibratedClockText(projection: projection).frame(width: 230, alignment: .leading) }
            HStack(spacing: 12) { Text("EXPECTED").frame(width: 160, alignment: .leading); Text(expected) }
            HStack(spacing: 12) { Text("SYS24").frame(width: 160, alignment: .leading); CalibratedClockText(projection: system24).frame(width: 230, alignment: .leading) }
            HStack(spacing: 12) { Text("REAL12").frame(width: 160, alignment: .leading); CalibratedClockText(projection: real12).frame(width: 230, alignment: .leading) }
            HStack(spacing: 12) { Text("SYS12").frame(width: 160, alignment: .leading); CalibratedClockText(projection: system12).frame(width: 230, alignment: .leading) }
            Text("REF SYS24 " + ClockHourFormat.twentyFour.string(from: wall))
            Text("REF REAL12 " + ClockHourFormat.twelve.string(from: real))
            Text("REF SYS12 " + ClockHourFormat.twelve.string(from: wall))
        }.font(.system(size: 27)).monospacedDigit().foregroundStyle(.black).padding(26).frame(width: 540, alignment: .leading).background(.white)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.cgImage, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fatalError("Offscreen rendering failed") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        try png.write(to: directory.appendingPathComponent("hour-format-render-regression.png"))
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let observations = (request.results ?? []).compactMap { observation -> (x: Double, y: Double, text: String)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            return (Double(observation.boundingBox.midX), Double(observation.boundingBox.midY), text)
        }.sorted { $0.y > $1.y }
        var groups: [[(x: Double, y: Double, text: String)]] = []
        for observation in observations {
            if let last = groups.last, abs(last[0].y - observation.y) < 0.05 { groups[groups.count - 1].append(observation) }
            else { groups.append([observation]) }
        }
        let lines = groups.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
        func row(_ label: String) -> String? {
            let key = label.replacingOccurrences(of: " ", with: "")
            return lines.first { $0.replacingOccurrences(of: " ", with: "").hasPrefix(key) }
        }
        func seconds(_ label: String) throws -> Int {
            guard let line = row(label), !line.contains("−"),
                  let match = line.range(of: "[0-9]{1,2}:[0-9]{2}:[0-9]{2}", options: .regularExpression) else {
                throw ClockError.message("OCR missing or invalid \(label): \(lines)")
            }
            let values = line[match].split(separator: ":").compactMap { Int($0) }
            return values[0] * 3600 + values[1] * 60 + values[2]
        }
        let reference = try seconds("EXPECTED")
        func difference(_ value: Int) -> Int { let d = abs(value - reference); return min(d, 86400 - d) }
        let oldError = difference(try seconds("OLD"))
        let newError = difference(try seconds("NEW"))
        var formatErrors: [String: Int] = [:]
        var periodsMatch = true
        for label in ["SYS24", "REAL12", "SYS12"] {
            formatErrors[label] = abs(try seconds(label) - seconds("REF " + label))
            if label.hasSuffix("12") {
                let actualLine = row(label) ?? ""
                let expectedLine = row("REF " + label) ?? ""
                let actualPeriod = actualLine.contains("PM") ? "PM" : actualLine.contains("AM") ? "AM" : "missing"
                let expectedPeriod = expectedLine.contains("PM") ? "PM" : expectedLine.contains("AM") ? "AM" : "missing"
                periodsMatch = periodsMatch && actualPeriod != "missing" && actualPeriod == expectedPeriod
            }
        }
        let passed = oldError > 590 && newError <= 1 && formatErrors.values.allSatisfy { $0 <= 1 } && periodsMatch
        let results: [String: Any] = ["ocrLines": lines, "oldErrorSeconds": oldError, "newErrorSeconds": newError, "hourFormatErrorsSeconds": formatErrors, "periodsMatch": periodsMatch, "passed": passed, "coverage": "Offscreen SwiftUI rendering; does not claim WidgetKit-host acceptance"]
        let data = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("hour-format-render-regression.json"))
        print(String(decoding: data, as: UTF8.self))
        guard passed else { throw ClockError.message("Clock rendering regression failed") }
    }
}
