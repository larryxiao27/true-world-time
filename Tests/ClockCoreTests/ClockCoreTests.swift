import Foundation
import Testing
@testable import ClockCore

@Test func independentOfWallClockChanges() throws {
    let engine = ClockEngine()
    engine.accept(NetworkSample(utc: 1_800_000_000, continuous: 100, roundTrip: 0.04, uncertainty: 0.02, source: "fixture", stratum: 2), bootID: "boot-A")
    for wallShift in [0.0, 600, -600, 0] {
        let s = engine.snapshot(systemUTC: 1_800_000_010 + wallShift, continuous: 110, bootID: "boot-A")
        #expect(s.trueUTC == 1_800_000_010)
        #expect(s.correction == -wallShift)
    }
}
@Test func elapsedSleepAndOfflineHoldover() {
    let engine = ClockEngine()
    engine.accept(NetworkSample(utc: 1_800_000_000, continuous: 100, roundTrip: 0.04, uncertainty: 0.02, source: "fixture", stratum: 2), bootID: "boot-A")
    engine.markNetworkFailure()
    let s = engine.snapshot(systemUTC: 1_800_004_200, continuous: 3700, bootID: "boot-A")
    #expect(s.trueUTC == 1_800_003_600)
    #expect(s.status == "offlineHoldover")
    #expect((s.uncertainty ?? 0) > 0.02)
}
@Test func rejectInvalidAnchors() {
    let engine = ClockEngine()
    #expect(engine.snapshot().trueUTC == nil)
    engine.accept(NetworkSample(utc: 1_800_000_000, continuous: 100, roundTrip: 0.04, uncertainty: 0.02, source: "fixture", stratum: 2), bootID: "boot-A")
    #expect(engine.snapshot(continuous: 120, bootID: "boot-B").trueUTC == nil)
    #expect(engine.snapshot(continuous: 90, bootID: "boot-A").trueUTC == nil)
}

func writeStamp(_ unix: Double, into data: inout [UInt8], at offset: Int) {
    let ntp = unix + 2_208_988_800
    let seconds = UInt32(truncatingIfNeeded: UInt64(ntp.rounded(.down)))
    let fraction = UInt32((ntp - ntp.rounded(.down)) * 4_294_967_296)
    for (position, number) in [(offset, seconds), (offset + 4, fraction)] {
        for i in 0..<4 { data[position+i] = UInt8(truncatingIfNeeded: number >> (24-i*8)) }
    }
}
func response(_ request: [UInt8], utc: Double = 1_800_000_000) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: 48); data[0] = 0x24; data[1] = 2
    data.replaceSubrange(24..<32, with: request[40..<48])
    writeStamp(utc, into: &data, at: 32); writeStamp(utc + 0.01, into: &data, at: 40)
    return data
}
@Test func compensateDelayWithoutUsingLocalWallClock() throws {
    let request = SNTPPacket.request()
    let sample = try SNTPPacket.decode(response(request), request: request, sent: 1, received: 1.05, reference: 1_800_000_600, source: "fixture")
    #expect(abs(sample.utc - 1_800_000_000.03) < 0.00001)
}
@Test func malformedNTPResponsesAreRejected() {
    let request = SNTPPacket.request()
    let good = response(request)
    var mismatch = good; mismatch[24] ^= 1
    var unsync = good; unsync[0] |= 0xc0
    var denied = good; denied[1] = 0
    var noStamp = good; noStamp.replaceSubrange(40..<48, with: [UInt8](repeating: 0, count: 8))
    for data in [Array(good.prefix(12)), mismatch, unsync, denied, noStamp] {
        #expect(throws: ClockError.self) { try SNTPPacket.decode(data, request: request, sent: 1, received: 1.05, reference: 1_800_000_600, source: "fixture") }
    }
}
@Test func ntpEraAfter2036() throws {
    let request = SNTPPacket.request()
    let utc = 2_300_000_000.0
    let sample = try SNTPPacket.decode(response(request, utc: utc), request: request, sent: 1, received: 1.05, reference: utc + 600, source: "fixture")
    #expect(abs(sample.utc - utc - 0.03) < 0.00001)
}

@Test func widgetProjectionPreservesTheReported597SecondCorrection() throws {
    let wall = Date(timeIntervalSince1970: 1794221294.305326)
    let real = Date(timeIntervalSince1970: 1794220696.978426)
    let projection = try #require(WidgetClockProjection(realDate: real, systemDate: wall, timeZone: TimeZone(identifier: "Asia/Singapore")!))
    let expected: TimeInterval = 67_096.978426
    let actual = wall.timeIntervalSince(projection.anchor)
    let advanced = wall.addingTimeInterval(17).timeIntervalSince(projection.anchor)
    #expect(abs(actual - expected) < 0.00001)
    #expect(abs(advanced - expected - 17) < 0.00001)
}

@Test func widgetProjectionReanchorsAfterForwardAndBackwardWallJumps() throws {
    let real = Date(timeIntervalSince1970: 1794220696.978426)
    for jump in [0.0, 597.3269, -600, 0] {
        let wall = real.addingTimeInterval(jump)
        let projection = try #require(WidgetClockProjection(realDate: real, systemDate: wall, timeZone: TimeZone(identifier: "Asia/Singapore")!))
        let expected: TimeInterval = 67_096.978426
        let actual = wall.timeIntervalSince(projection.anchor)
        #expect(abs(actual - expected) < 0.00001)
    }
}

@Test func widgetProjectionResetsAtLocalMidnight() throws {
    let real = Date(timeIntervalSince1970: 1794239999.5) // 2026-11-09 23:59:59.5 Singapore
    let wall = real.addingTimeInterval(597.3269)
    let zone = TimeZone(identifier: "Asia/Singapore")!
    let projection = try #require(WidgetClockProjection(realDate: real, systemDate: wall, timeZone: zone))
    #expect(abs(wall.timeIntervalSince(projection.anchor) - 86399.5) < 0.00001)
    #expect(abs(projection.nextBoundary.timeIntervalSince(wall) - 0.5) < 0.00001)
    let next = try #require(WidgetClockProjection(realDate: real.addingTimeInterval(0.5), systemDate: projection.nextBoundary, timeZone: zone))
    #expect(abs(projection.nextBoundary.timeIntervalSince(next.anchor)) < 0.00001)
}

@Test func widgetProjectionResetsAtDSTTransition() throws {
    let iso = ISO8601DateFormatter()
    let real = iso.date(from: "2026-11-01T05:59:59Z")!
    let wall = real.addingTimeInterval(600)
    let zone = TimeZone(identifier: "America/New_York")!
    let projection = try #require(WidgetClockProjection(realDate: real, systemDate: wall, timeZone: zone))
    #expect(abs(projection.nextBoundary.timeIntervalSince(wall) - 1) < 0.00001)
    let next = try #require(WidgetClockProjection(realDate: real.addingTimeInterval(1), systemDate: projection.nextBoundary, timeZone: zone))
    #expect(abs(projection.nextBoundary.timeIntervalSince(next.anchor) - 3600) < 0.00001)
}

@Test func explicitHourFormatsCoverMidnightNoonAndEvening() throws {
    let base = ISO8601DateFormatter().date(from: "2026-11-09T00:34:56Z")!.addingTimeInterval(0.75)
    let zone = TimeZone(secondsFromGMT: 0)!
    for hour in [0, 1, 11, 12, 13, 23] {
        let date = base.addingTimeInterval(Double(hour * 3600))
        let displayHour = hour % 12 == 0 ? 12 : hour % 12
        let period = hour < 12 ? "AM" : "PM"
        let text24 = String(format: "%02d:34:56", hour)
        let text12 = String(format: "%02d:34:56 %@", displayHour, period)
        #expect(ClockHourFormat.twentyFour.string(from: date, timeZone: zone) == text24)
        #expect(ClockHourFormat.twelve.string(from: date, timeZone: zone) == text12)
        let projection = try #require(WidgetClockProjection(realDate: date, systemDate: date.addingTimeInterval(600), timeZone: zone, hourFormat: .twelve))
        let expected = Double(displayHour * 3600 + 34 * 60) + 56.75
        let actual = date.addingTimeInterval(600).timeIntervalSince(projection.anchor)
        #expect(abs(actual - expected) < 0.00001)
        #expect(projection.period == period)
    }
}

@Test func twelveHourProjectionResetsWithoutDisplayingThirteen() throws {
    let base = ISO8601DateFormatter().date(from: "2026-11-09T00:59:59Z")!
    let zone = TimeZone(secondsFromGMT: 0)!
    for hour in [0, 11, 12, 23] {
        let real = base.addingTimeInterval(Double(hour * 3600))
        let wall = real.addingTimeInterval(600)
        let before = try #require(WidgetClockProjection(realDate: real, systemDate: wall, timeZone: zone, hourFormat: .twelve))
        #expect(before.nextBoundary.timeIntervalSince(wall) == 1)
        let after = try #require(WidgetClockProjection(realDate: real.addingTimeInterval(1), systemDate: before.nextBoundary, timeZone: zone, hourFormat: .twelve))
        let nextHour = (hour + 1) % 24
        let expected = Double((nextHour % 12 == 0 ? 12 : nextHour % 12) * 3600)
        #expect(before.nextBoundary.timeIntervalSince(after.anchor) == expected)
        #expect(after.period == (nextHour < 12 ? "AM" : "PM"))
    }
}

@Test func twoClocksCanHaveDifferentAMPMPeriods() throws {
    let real = ISO8601DateFormatter().date(from: "2026-11-09T11:55:00Z")!
    let system = real.addingTimeInterval(600)
    let zone = TimeZone(secondsFromGMT: 0)!
    let left = try #require(WidgetClockProjection(realDate: real, systemDate: system, timeZone: zone, hourFormat: .twelve))
    let right = try #require(WidgetClockProjection(realDate: system, systemDate: system, timeZone: zone, hourFormat: .twelve))
    #expect(left.period == "AM")
    #expect(right.period == "PM")
    #expect(min(left.nextBoundary, right.nextBoundary).timeIntervalSince(system) == 300)
}

@Test func hourPreferenceTravelsWithSnapshotAndOldSnapshotsStillDecode() throws {
    var snapshot = ClockEngine().snapshot()
    snapshot.hourFormat = .twelve
    let encoder = JSONEncoder()
    let data = try encoder.encode(snapshot)
    #expect(try JSONDecoder().decode(TimeSnapshot.self, from: data).hourFormat == .twelve)
    var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    old.removeValue(forKey: "hourFormat")
    let oldData = try JSONSerialization.data(withJSONObject: old)
    #expect(try JSONDecoder().decode(TimeSnapshot.self, from: oldData).hourFormat == nil)
}

@Test func consumerClockLabelsDescribeFastAndSlowTime() {
    #expect(ClockPresentation.systemDifference(correction: -597.3) == "快 9 分 57 秒")
    #expect(ClockPresentation.systemDifference(correction: 600) == "慢 10 分")
    #expect(ClockPresentation.systemDifference(correction: 0.4) == "基本同步")
    #expect(ClockPresentation.systemDifference(correction: nil) == "等待校时")
    #expect(ClockPresentation.systemDifference(correction: .infinity) == "等待校时")
    #expect(ClockPresentation.status("offlineHoldover") == "离线计时")
}

@Test func lastSyncLabelUsesCorrectedTimeRatherThanSystemTime() {
    let engine = ClockEngine()
    engine.accept(NetworkSample(utc: 1794220696, continuous: 100, roundTrip: 0.01, uncertainty: 0.005, source: "fixture", stratum: 2), bootID: "boot")
    let sample = engine.snapshot(systemUTC: 1794221306, continuous: 110, bootID: "boot")
    #expect(ClockPresentation.lastSync(sample, hourFormat: .twentyFour, timeZone: TimeZone(identifier: "Asia/Singapore")!) == "11-09 18:38:16")
}
