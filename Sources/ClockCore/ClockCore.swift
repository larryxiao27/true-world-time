import Foundation
import Darwin

public enum ContinuousTime {
    public static var now: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }
    public static var bootID: String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

public struct NetworkSample: Codable, Sendable {
    public var utc: Double
    public var continuous: Double
    public var roundTrip: Double
    public var uncertainty: Double
    public var source: String
    public var stratum: Int
    public init(utc: Double, continuous: Double, roundTrip: Double, uncertainty: Double, source: String, stratum: Int) {
        self.utc = utc; self.continuous = continuous; self.roundTrip = roundTrip
        self.uncertainty = uncertainty; self.source = source; self.stratum = stratum
    }
}

public enum ClockHourFormat: String, Codable, CaseIterable, Sendable {
    case twentyFour = "24h"
    case twelve = "12h"
    public static let preferenceKey = "clockHourFormat"
    public func string(from date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = self == .twentyFour ? "HH:mm:ss" : "hh:mm:ss a"
        return formatter.string(from: date)
    }
}

public struct TimeSnapshot: Codable, Sendable {
    public var trueUTC: Double?
    public var systemUTC: Double
    public var continuous: Double
    public var correction: Double?
    public var sampleAge: Double?
    public var uncertainty: Double?
    public var status: String
    public var source: String?
    public var generation: Int
    public var bootID: String
    public var hourFormat: ClockHourFormat? = nil
}

/// Maps corrected local wall-clock components to a built-in elapsed-time text.
/// The anchor is in the system Date domain; fractional correction is preserved.
/// Rebuild on a wall-clock jump, and prepare a new anchor at midnight or DST.
public struct WidgetClockProjection: Codable, Sendable {
    public let anchor: Date
    public let nextBoundary: Date
    public let period: String?
    public init?(realDate: Date, systemDate: Date, timeZone: TimeZone, hourFormat: ClockHourFormat = .twentyFour) {
        guard realDate.timeIntervalSince1970.isFinite, systemDate.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .second], from: realDate)
        guard let hour = parts.hour, let minute = parts.minute, let second = parts.second,
              let day = calendar.dateInterval(of: .day, for: realDate) else { return nil }
        let fraction = realDate.timeIntervalSince1970 - floor(realDate.timeIntervalSince1970)
        let displayHour = hourFormat == .twentyFour ? hour : (hour % 12 == 0 ? 12 : hour % 12)
        let localSeconds = Double(displayHour * 3600 + minute * 60 + second) + fraction
        period = hourFormat == .twelve ? (hour < 12 ? "AM" : "PM") : nil
        anchor = systemDate.addingTimeInterval(-localSeconds)
        var boundary = day.end
        if hourFormat == .twelve, let hourInterval = calendar.dateInterval(of: .hour, for: realDate) {
            boundary = min(boundary, hourInterval.end)
        }
        if let transition = timeZone.nextDaylightSavingTimeTransition(after: realDate), transition > realDate, transition < boundary {
            boundary = transition
        }
        nextBoundary = systemDate.addingTimeInterval(boundary.timeIntervalSince(realDate))
    }
}

// All access to the mutable sample and flags is protected by the same lock.
public final class ClockEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: NetworkSample?
    private var sampleBoot: String?
    private var failed = false
    private var generation = 0
    public init() {}
    public func accept(_ value: NetworkSample, bootID: String = ContinuousTime.bootID) {
        lock.withLock { sample = value; sampleBoot = bootID; failed = false; generation += 1 }
    }
    public func markNetworkFailure() { lock.withLock { failed = true } }
    public func snapshot(systemUTC: Double = Date().timeIntervalSince1970, continuous: Double = ContinuousTime.now, bootID: String = ContinuousTime.bootID) -> TimeSnapshot {
        lock.withLock {
            guard let sample, sampleBoot == bootID, bootID != "unknown", continuous >= sample.continuous else {
                return TimeSnapshot(trueUTC: nil, systemUTC: systemUTC, continuous: continuous, correction: nil, sampleAge: nil, uncertainty: nil, status: "unsynchronized", source: nil, generation: generation, bootID: bootID)
            }
            let age = continuous - sample.continuous
            let utc = sample.utc + age
            return TimeSnapshot(trueUTC: utc, systemUTC: systemUTC, continuous: continuous, correction: utc - systemUTC, sampleAge: age, uncertainty: sample.uncertainty + age * 0.00005, status: failed ? "offlineHoldover" : age > 1800 ? "stale" : "calibrated", source: sample.source, generation: generation, bootID: bootID)
        }
    }
}

public enum ClockError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

public enum SNTPPacket {
    public static func request() -> [UInt8] {
        var data = [UInt8](repeating: 0, count: 48)
        data[0] = 0x23
        for i in 40..<48 { data[i] = UInt8.random(in: 1...255) }
        return data
    }
    private static func uint32(_ data: [UInt8], _ offset: Int) -> UInt32 {
        data[offset..<offset + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
    private static func timestamp(_ data: [UInt8], _ offset: Int, reference: Double) -> Double {
        let seconds = Double(uint32(data, offset))
        let fraction = Double(uint32(data, offset + 4)) / 4_294_967_296
        let base = seconds - 2_208_988_800
        let era = ((reference - base) / 4_294_967_296).rounded()
        return base + era * 4_294_967_296 + fraction
    }
    public static func decode(_ data: [UInt8], request: [UInt8], sent: Double, received: Double, reference: Double, source: String) throws -> NetworkSample {
        guard data.count >= 48, request.count == 48 else { throw ClockError.message("Truncated NTP packet") }
        guard data[0] & 7 == 4, (3...4).contains((data[0] >> 3) & 7), data[0] >> 6 != 3 else { throw ClockError.message("Invalid / unsynchronized NTP server") }
        guard (1...15).contains(data[1]) else { throw ClockError.message("NTP server refused request or invalid stratum") }
        guard Array(data[24..<32]) == Array(request[40..<48]) else { throw ClockError.message("NTP request/response mismatch") }
        guard data[32..<40].contains(where: { $0 != 0 }), data[40..<48].contains(where: { $0 != 0 }) else { throw ClockError.message("Missing server timestamp") }
        let t2 = timestamp(data, 32, reference: reference)
        let t3 = timestamp(data, 40, reference: reference)
        let rtt = received - sent
        let networkDelay = rtt - (t3 - t2)
        guard rtt >= 0, rtt < 3, t3 >= t2, networkDelay >= -0.002 else { throw ClockError.message("Invalid or excessive NTP delay") }
        let dispersion = Double(uint32(data, 8)) / 65_536
        guard dispersion < 2 else { throw ClockError.message("Excessive NTP dispersion") }
        return NetworkSample(utc: t3 + max(0, networkDelay) / 2, continuous: received, roundTrip: rtt, uncertainty: max(0, networkDelay) / 2 + dispersion, source: source, stratum: Int(data[1]))
    }
}

public enum SNTPClient {
    public static func query(host: String) async throws -> NetworkSample {
        try await Task.detached(priority: .utility) { try queryBlocking(host: host) }.value
    }
    private static func queryBlocking(host: String) throws -> NetworkSample {
        var hints = addrinfo()
        hints.ai_family = AF_INET; hints.ai_socktype = SOCK_DGRAM; hints.ai_protocol = IPPROTO_UDP
        var address: UnsafeMutablePointer<addrinfo>?
        let lookup = getaddrinfo(host, "123", &hints, &address)
        guard lookup == 0, let address else { throw ClockError.message("DNS failed: \(host) (\(lookup))") }
        defer { freeaddrinfo(address) }
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ClockError.message("UDP socket unavailable") }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Connected UDP filters replies from unrelated endpoints.
        guard Darwin.connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else { throw ClockError.message("UDP connect failed") }
        let packet = SNTPPacket.request()
        let sent = ContinuousTime.now
        guard packet.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == packet.count else { throw ClockError.message("UDP send failed") }
        var bytes = [UInt8](repeating: 0, count: 512)
        let count = bytes.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
        let received = ContinuousTime.now
        guard count > 0 else { throw ClockError.message("NTP timeout / no network: \(host)") }
        return try SNTPPacket.decode(Array(bytes.prefix(count)), request: packet, sent: sent, received: received, reference: Date().timeIntervalSince1970, source: host)
    }
}
