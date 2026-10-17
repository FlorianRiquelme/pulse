import Foundation
import IOKit

struct BatteryReading {
    var percent: Double = 0
    var plugged = false
    var charging = false
    var fullyCharged = false
    /// Charging paused even though the power adapter is connected (e.g. optimized charging or a charge limit).
    var chargingPaused = false
    var cycleCount = 0
    var designCycles = 1000
    /// mAh
    var remainingCapacity: Double = 0
    var fullCapacity: Double = 0
    var designCapacity: Double = 0
    /// Volts
    var voltage: Double = 0
    /// mA, negative while discharging.
    var amperage: Double = 0
    var temperature: Double?
    var adapterWatts: Int?
    var adapterName: String?
    /// Power of the whole system according to the battery controller (W).
    var systemLoadW: Double?
    /// Power from the power adapter (W).
    var adapterInputW: Double?
    /// macOS's own forecasts (minutes), nil = unknown.
    var macTimeToEmpty: TimeInterval?
    var macTimeToFull: TimeInterval?

    /// Battery power: positive = discharging, negative = charging.
    var batteryPowerW: Double { -voltage * amperage / 1000 }
    var remainingWh: Double { remainingCapacity * voltage / 1000 }
    var fullWh: Double { fullCapacity * voltage / 1000 }
    /// Health: current full-charge capacity relative to the design capacity.
    var health: Double? { designCapacity > 0 ? fullCapacity / designCapacity : nil }
}

final class BatterySensor {
    private let service: io_service_t

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if service != 0 { IOObjectRelease(service) }
    }

    var available: Bool { service != 0 && (IOReg.properties(service)?.bool("BatteryInstalled") ?? false) }

    func sample() -> BatteryReading? {
        guard service != 0, let p = IOReg.properties(service), p.bool("BatteryInstalled") ?? true else { return nil }
        var r = BatteryReading()
        let data = p.dict("BatteryData") ?? [:]

        let current = Double(p.int("CurrentCapacity") ?? 0)
        let max = Double(p.int("MaxCapacity") ?? 100)
        r.percent = max > 0 ? current / max * 100 : current
        r.plugged = p.bool("ExternalConnected") ?? false
        r.charging = p.bool("IsCharging") ?? false
        r.fullyCharged = p.bool("FullyCharged") ?? false
        r.cycleCount = p.int("CycleCount") ?? 0
        r.designCycles = p.int("DesignCycleCount9C") ?? 1000
        r.remainingCapacity = Double(data.int("RemainingCapacity") ?? p.int("AppleRawCurrentCapacity") ?? 0)
        r.fullCapacity = Double(data.int("FullChargeCapacity") ?? p.int("AppleRawMaxCapacity") ?? 0)
        r.designCapacity = Double(data.int("DesignCapacity") ?? p.int("DesignCapacity") ?? 0)
        r.voltage = Double(p.int("Voltage") ?? 0) / 1000
        r.amperage = Double(p.int("Amperage") ?? 0)
        if let t = p.int("Temperature"), t > 0 { r.temperature = Double(t) / 100 }

        if let adapter = p.dict("AdapterDetails") {
            r.adapterWatts = adapter.int("Watts")
            r.adapterName = (adapter["Name"] as? String) ?? (adapter["Description"] as? String)
        }
        let notChargingReason = p.dict("ChargerData")?.int("NotChargingReason") ?? 0
        r.chargingPaused = r.plugged && !r.charging && !r.fullyCharged && notChargingReason != 0 && r.percent < 99.5

        if let telemetry = p.dict("PowerTelemetryData") {
            if let load = telemetry.int("SystemLoad"), load > 0 { r.systemLoadW = Double(load) / 1000 }
            if let input = telemetry.int("SystemPowerIn"), input > 0 { r.adapterInputW = Double(input) / 1000 }
        }
        if let m = p.int("AvgTimeToEmpty"), m > 0, m < 65535 { r.macTimeToEmpty = Double(m) * 60 }
        if let m = p.int("AvgTimeToFull"), m > 0, m < 65535 { r.macTimeToFull = Double(m) * 60 }
        return r
    }
}
