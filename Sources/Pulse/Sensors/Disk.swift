import Foundation
import IOKit

struct DiskReading {
    var total: Double = 0
    var available: Double = 0
    var readRate: Double = 0
    var writeRate: Double = 0
    var used: Double { max(0, total - available) }
    var usedFraction: Double { total > 0 ? used / total : 0 }
}

final class DiskSensor {
    private var previous: (date: Date, read: Double, write: Double)?
    private var capacityCheckedAt: Date?
    private var capacity: (total: Double, available: Double) = (0, 0)

    func sample(at date: Date = .now) -> DiskReading {
        var r = DiskReading()
        // Free space changes slowly; "available" (including purgeable data) costs a little, so only every 30 s.
        if capacityCheckedAt.map({ date.timeIntervalSince($0) > 30 }) ?? true {
            let values = try? URL(fileURLWithPath: "/").resourceValues(
                forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            capacity = (Double(values?.volumeTotalCapacity ?? 0), Double(values?.volumeAvailableCapacityForImportantUsage ?? 0))
            capacityCheckedAt = date
        }
        r.total = capacity.total
        r.available = capacity.available

        var read = 0.0, write = 0.0
        IOReg.forEach("IOBlockStorageDriver") { service in
            guard let stats = IOReg.properties(service)?.dict("Statistics") else { return }
            read += Double(stats.int("Bytes (Read)") ?? 0)
            write += Double(stats.int("Bytes (Write)") ?? 0)
        }
        if let previous {
            let dt = date.timeIntervalSince(previous.date)
            if dt > 0 {
                r.readRate = max(0, read - previous.read) / dt
                r.writeRate = max(0, write - previous.write) / dt
            }
        }
        previous = (date, read, write)
        return r
    }
}
