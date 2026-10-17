import Foundation
import IOKit

/// GPU utilization from the graphics driver's performance statistics.
enum GPUSensor {
    static func utilization() -> Double? {
        var result: Double?
        IOReg.forEach("IOAccelerator") { service in
            guard result == nil,
                  let stats = IOReg.properties(service)?.dict("PerformanceStatistics"),
                  let util = stats.int("Device Utilization %") else { return }
            result = Double(util) / 100
        }
        return result
    }
}
