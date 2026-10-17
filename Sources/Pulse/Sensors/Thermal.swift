import Foundation
import IOKit

struct TemperatureReading {
    struct Sensor: Identifiable {
        var name: String
        var celsius: Double
        var id: String { name }
    }

    /// Average and maximum of the chip sensors (PMU tdie).
    var socAverage: Double?
    var socMax: Double?
    var battery: Double?
    var ssd: Double?
    var all: [Sensor] = []
}

/// Temperature sensors via the HID event system (this is also how Stats and iStat read them on Apple Silicon).
/// The functions are private, hence dlsym; if they are missing, the list stays empty.
final class ThermalSensor {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloat = @convention(c) (AnyObject, Int32) -> Double

    private static let temperatureEvent: Int64 = 15

    private var client: AnyObject?
    private var services: [(name: String, service: AnyObject)] = []
    private var copyEvent: CopyEvent?
    private var getFloat: GetFloat?

    init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW),
              let create = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let setMatching = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let copyServices = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let copyProperty = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let copyEvent = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let getFloat = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return }
        self.copyEvent = unsafeBitCast(copyEvent, to: CopyEvent.self)
        self.getFloat = unsafeBitCast(getFloat, to: GetFloat.self)

        guard let client = unsafeBitCast(create, to: ClientCreate.self)(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        self.client = client
        // Apple's own page 0xff00, usage 5 = temperature sensor
        _ = unsafeBitCast(setMatching, to: SetMatching.self)(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        guard let list = unsafeBitCast(copyServices, to: CopyServices.self)(client)?.takeRetainedValue() as? [AnyObject] else { return }
        let property = unsafeBitCast(copyProperty, to: CopyProperty.self)
        services = list.compactMap { service in
            guard let name = property(service, "Product" as CFString)?.takeRetainedValue() as? String else { return nil }
            return (name, service)
        }
    }

    var available: Bool { !services.isEmpty }

    func sample() -> TemperatureReading {
        var r = TemperatureReading()
        guard let copyEvent, let getFloat else { return r }
        var byName: [String: [Double]] = [:]
        for (name, service) in services {
            guard let event = copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            let value = getFloat(event, Int32(Self.temperatureEvent << 16))
            guard value > 0, value < 130 else { continue }
            byName[name, default: []].append(value)
        }
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }

        let die = byName.filter { $0.key.contains("tdie") }.flatMap(\.value)
        r.socAverage = mean(die)
        r.socMax = die.max()
        r.battery = mean(byName.filter { $0.key.localizedCaseInsensitiveContains("battery") }.flatMap(\.value))
        r.ssd = mean(byName.filter { $0.key.contains("NAND") }.flatMap(\.value))
        r.all = byName
            .filter { !$0.key.contains("tcal") }
            .map { TemperatureReading.Sensor(name: Self.label($0.key), celsius: mean($0.value) ?? 0) }
            .sorted { $0.celsius > $1.celsius }
        return r
    }

    private static func label(_ raw: String) -> String {
        if raw.hasPrefix("gas gauge battery") { return "Battery" }
        if raw.hasPrefix("NAND") { return "SSD" }
        if raw.hasPrefix("PMU2 tdie") { return "Chip 2 · Core " + raw.dropFirst("PMU2 tdie".count) }
        if raw.hasPrefix("PMU tdie") { return "Chip · Core " + raw.dropFirst("PMU tdie".count) }
        if raw.hasPrefix("PMU2 tdev") { return "Board 2 · " + raw.dropFirst("PMU2 tdev".count) }
        if raw.hasPrefix("PMU tdev") { return "Board · " + raw.dropFirst("PMU tdev".count) }
        return raw
    }
}
