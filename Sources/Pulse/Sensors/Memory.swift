import Darwin
import Foundation

enum MemoryPressure: Int {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }
}

struct MemoryReading {
    var total: Double = 0
    var app: Double = 0
    var wired: Double = 0
    var compressed: Double = 0
    var cached: Double = 0
    var free: Double = 0
    var swapUsed: Double = 0
    var swapTotal: Double = 0
    /// Swap in and out in bytes/s since the last reading (nil on the first).
    var swapIn: Double?
    var swapOut: Double?
    var pressure: MemoryPressure = .normal
    /// Available memory according to the kernel (0–1); 1 − value roughly matches Activity Monitor's memory pressure curve.
    var availableLevel: Double = 1

    /// "Used" as in Activity Monitor: app memory + wired + compressed.
    var used: Double { app + wired + compressed }
    var usedFraction: Double { total > 0 ? used / total : 0 }
}

final class MemorySensor {
    private let total = Double(Sysctl.int("hw.memsize") ?? 0)
    private let pageSize = Double(vm_kernel_page_size)
    private var previousSwap: (date: Date, ins: UInt64, outs: UInt64)?

    func sample(at date: Date = .now) -> MemoryReading {
        var r = MemoryReading(total: total)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let internalPages = Double(stats.internal_page_count)
            let purgeable = Double(stats.purgeable_count)
            r.app = max(0, internalPages - purgeable) * pageSize
            r.wired = Double(stats.wire_count) * pageSize
            r.compressed = Double(stats.compressor_page_count) * pageSize
            r.cached = (Double(stats.external_page_count) + purgeable) * pageSize
            r.free = Double(stats.free_count) * pageSize
            if let before = previousSwap, date > before.date, stats.swapins >= before.ins, stats.swapouts >= before.outs {
                let dt = date.timeIntervalSince(before.date)
                r.swapIn = Double(stats.swapins - before.ins) * pageSize / dt
                r.swapOut = Double(stats.swapouts - before.outs) * pageSize / dt
            }
            previousSwap = (date, stats.swapins, stats.swapouts)
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsed = Double(swap.xsu_used)
            r.swapTotal = Double(swap.xsu_total)
        }
        if let level = Sysctl.int("kern.memorystatus_vm_pressure_level") {
            r.pressure = MemoryPressure(rawValue: level) ?? .normal
        }
        if let level = Sysctl.int("kern.memorystatus_level") {
            r.availableLevel = Double(level) / 100
        }
        return r
    }
}
