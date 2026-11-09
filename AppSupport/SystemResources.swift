import Foundation
import Darwin
import Dispatch

struct HardwareSummary: Sendable {
    static let current = HardwareSummary()
    let model: String
    let chip: String
    let physicalCores: Int
    let logicalCores: Int
    let memoryBytes: UInt64
    let systemVersion: String
    private init() {
        model = Self.sysctlString("hw.model") ?? "Mac"
        chip = Self.sysctlString("machdep.cpu.brand_string") ?? "未知芯片"
        var cores: UInt32 = 0
        var length = MemoryLayout<UInt32>.size
        let result = sysctlbyname("hw.physicalcpu", &cores, &length, nil, 0)
        physicalCores = result == 0 ? Int(cores) : ProcessInfo.processInfo.processorCount
        logicalCores = ProcessInfo.processInfo.processorCount
        memoryBytes = ProcessInfo.processInfo.physicalMemory
        let version = ProcessInfo.processInfo.operatingSystemVersion
        systemVersion = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    private static func sysctlString(_ name: String) -> String? {
        var count = 0
        guard sysctlbyname(name, nil, &count, nil, 0) == 0, count > 1, count <= 4096 else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { sysctlbyname(name, $0.baseAddress, &count, nil, 0) }
        guard result == 0 else { return nil }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
}

struct CPUCounters: Sendable {
    let user: UInt32
    let system: UInt32
    let idle: UInt32
    let nice: UInt32
    func percent(since old: CPUCounters) -> Double? {
        let busy = UInt64(user &- old.user) + UInt64(system &- old.system) + UInt64(nice &- old.nice)
        let total = busy + UInt64(idle &- old.idle)
        return total == 0 ? nil : Double(busy) / Double(total) * 100
    }
}

struct ResourceSnapshot: Sendable {
    let systemCPUPercent: Double?
    let appCPUPercent: Double?
    let appMemoryBytes: UInt64?
}

protocol ResourceReading: AnyObject { func sample() -> ResourceSnapshot }

/// Fixed-size kernel counters only: no child processes, history, threads or timers.
final class SystemResourceReader: ResourceReading {
    private let hostPort = mach_host_self()
    private var previous: (time: Double, cpu: CPUCounters?, processCPU: Double?)?
    deinit { if hostPort != MACH_PORT_NULL { mach_port_deallocate(mach_task_self_, hostPort) } }

    func sample() -> ResourceSnapshot {
        let time = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
        let cpu = readCPU()
        let processCPU = Self.processCPUSeconds()
        var totalPercent: Double?
        var appPercent: Double?
        if let previous {
            if let cpu, let old = previous.cpu { totalPercent = cpu.percent(since: old) }
            if let processCPU, let old = previous.processCPU, time > previous.time, processCPU >= old {
                appPercent = (processCPU - old) / (time - previous.time) * 100
            }
        }
        previous = (time, cpu, processCPU)
        return ResourceSnapshot(systemCPUPercent: totalPercent, appCPUPercent: appPercent, appMemoryBytes: Self.physicalFootprint())
    }

    private func readCPU() -> CPUCounters? {
        var info = host_cpu_load_info_data_t()
        let capacity = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(hostPort, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return CPUCounters(user: info.cpu_ticks.0, system: info.cpu_ticks.1, idle: info.cpu_ticks.2, nice: info.cpu_ticks.3)
    }
    private static func processCPUSeconds() -> Double? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    static func physicalFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        let capacity = MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Driven by the existing clock loop. Hidden windows never create or poll a reader.
final class VisibleResourceMonitor {
    private let factory: () -> any ResourceReading
    private var reader: (any ResourceReading)?
    private var visible = false
    private var lastSample = -Double.infinity
    init(factory: @escaping () -> any ResourceReading = { SystemResourceReader() }) { self.factory = factory }
    func setVisible(_ value: Bool) {
        guard value != visible else { return }
        visible = value
        lastSample = -Double.infinity
        if !visible { reader = nil }
    }
    func sampleIfDue(at time: Double) -> ResourceSnapshot? {
        guard visible, time - lastSample >= 2 else { return nil }
        if reader == nil { reader = factory() }
        lastSample = time
        return reader?.sample()
    }
}
