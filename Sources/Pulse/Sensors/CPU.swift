import Darwin
import Foundation

struct CPUReading {
    /// Total load per core 0–1, in the order of the logical cores.
    var perCore: [Double] = []
    var user: Double = 0
    var system: Double = 0
    var total: Double { user + system }
    var loadAverage: (Double, Double, Double) = (0, 0, 0)
}

/// CPU load from the cores' tick counters (difference to the last reading).
final class CPUSensor {
    struct Ticks { var user, system, idle, nice: UInt32 }

    let coreCount: Int
    /// Number of efficiency cores; on Apple Silicon these are the first logical cores.
    let efficiencyCores: Int
    let performanceName: String
    let chipName: String
    private var previous: [Ticks] = []

    init() {
        coreCount = Sysctl.int("hw.logicalcpu") ?? ProcessInfo.processInfo.activeProcessorCount
        if Sysctl.string("hw.perflevel1.name") == "Efficiency" {
            efficiencyCores = Sysctl.int("hw.perflevel1.logicalcpu") ?? 0
        } else {
            efficiencyCores = 0
        }
        performanceName = Sysctl.string("hw.perflevel0.name") ?? "Performance"
        chipName = Sysctl.string("machdep.cpu.brand_string") ?? "Mac"
        previous = Self.readTicks()
    }

    func sample() -> CPUReading {
        let now = Self.readTicks()
        defer { previous = now }
        var reading = CPUReading()
        guard now.count == previous.count, !now.isEmpty else { return reading }

        var sumUser = 0.0, sumSystem = 0.0, sumAll = 0.0
        for (a, b) in zip(previous, now) {
            let user = Double(b.user &- a.user) + Double(b.nice &- a.nice)
            let system = Double(b.system &- a.system)
            let idle = Double(b.idle &- a.idle)
            let all = user + system + idle
            reading.perCore.append(all > 0 ? (user + system) / all : 0)
            sumUser += user
            sumSystem += system
            sumAll += all
        }
        if sumAll > 0 {
            reading.user = sumUser / sumAll
            reading.system = sumSystem / sumAll
        }
        var loads = [Double](repeating: 0, count: 3)
        if getloadavg(&loads, 3) == 3 { reading.loadAverage = (loads[0], loads[1], loads[2]) }
        return reading
    }

    private static func readTicks() -> [Ticks] {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        return (0..<Int(count)).map { core in
            let base = core * stride
            return Ticks(
                user: UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
    }
}
