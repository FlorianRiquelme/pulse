import Foundation

/// Remaining runtime forecasts from different angles.
public struct BatteryEstimate: Equatable, Sendable {
    /// From the power measured right now (smoothed).
    public var now: TimeInterval?
    public var nowPowerW: Double?
    /// From the average power of the last minutes on battery (your current usage).
    public var recent: TimeInterval?
    public var recentPowerW: Double?
    /// How many minutes went into `recent`.
    public var recentMinutes: Int = 0
    /// From the median of recent days on battery (your typical usage).
    public var typical: TimeInterval?
    public var typicalPowerW: Double?
    /// How long a full battery lasts at typical usage.
    public var fullChargeRuntime: TimeInterval?

    public init() {}

    /// The best available forecast: current usage, otherwise the instantaneous value.
    public var best: TimeInterval? { recent ?? now }
}

/// One continuous stretch on battery.
public struct DischargeSession: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var startPercent: Double
    public var endPercent: Double
    /// Minutes the Mac was awake (sleep does not count).
    public var activeMinutes: Int
    public var averagePowerW: Double?
    public var ongoing: Bool

    public var used: Double { max(0, startPercent - endPercent) }
    /// Usage in percentage points per active hour.
    public var percentPerHour: Double? {
        activeMinutes >= 10 ? used / (Double(activeMinutes) / 60) : nil
    }
}

public enum BatteryEstimator {
    /// Time window for "your current usage".
    public static let recentWindow: TimeInterval = 30 * 60
    /// Time window for "typical usage".
    public static let typicalWindow: TimeInterval = 7 * 24 * 3600

    /// - Parameters:
    ///   - remainingWh: Remaining energy in the battery.
    ///   - fullWh: Energy at full charge (current capacity, not design).
    ///   - nowPowerW: Smoothed discharge power in watts (positive = discharging).
    ///   - log: Minute log.
    public static func estimate(remainingWh: Double, fullWh: Double, nowPowerW: Double?,
                                log: [MinuteSample], now: Date = .now) -> BatteryEstimate {
        var e = BatteryEstimate()

        if let p = nowPowerW, p > 0.3 {
            e.nowPowerW = p
            e.now = remainingWh / p * 3600
        }

        let recent = log.filter { $0.t >= now.addingTimeInterval(-recentWindow) && $0.isDischarging }
        if recent.count >= 3 {
            let p = recent.compactMap(\.batteryW).reduce(0, +) / Double(recent.count)
            e.recentPowerW = p
            e.recentMinutes = recent.count
            e.recent = remainingWh / p * 3600
        }

        let typical = log.filter { $0.t >= now.addingTimeInterval(-typicalWindow) && $0.isDischarging }
            .compactMap(\.batteryW)
        if typical.count >= 60, let p = median(typical) {
            e.typicalPowerW = p
            e.typical = remainingWh / p * 3600
            e.fullChargeRuntime = fullWh / p * 3600
        }
        return e
    }

    /// Time to full from the charging power (rough; the last percent charge more slowly).
    public static func timeToFull(remainingWh: Double, fullWh: Double, chargePowerW: Double) -> TimeInterval? {
        guard chargePowerW > 0.5, fullWh > remainingWh else { return nil }
        return (fullWh - remainingWh) / chargePowerW * 3600
    }

    /// How much longer the battery would last if an app (with `appPowerW`) were not running:
    /// remaining energy / (system power − app) − remaining energy / system power.
    /// Only a lower bound: macOS attributes display, radios and memory to no app.
    public static func whatIf(remainingWh: Double, systemPowerW: Double, appPowerW: Double) -> TimeInterval? {
        guard remainingWh > 0, systemPowerW > 0.3, appPowerW > 0, appPowerW < systemPowerW else { return nil }
        return remainingWh / (systemPowerW - appPowerW) * 3600 - remainingWh / systemPowerW * 3600
    }

    /// The latest battery stretch from the minute log (still ongoing if the power adapter is not plugged in right now).
    public static func lastSession(in log: [MinuteSample], pluggedNow: Bool) -> DischargeSession? {
        guard let endIndex = log.lastIndex(where: { !$0.plugged && $0.battery != nil }) else { return nil }
        var startIndex = endIndex
        while startIndex > 0, !log[startIndex - 1].plugged, log[startIndex - 1].battery != nil {
            startIndex -= 1
        }
        let slice = log[startIndex...endIndex]
        guard let first = slice.first, let last = slice.last,
              let startPercent = first.battery, let endPercent = last.battery else { return nil }
        let powers = slice.filter(\.isDischarging).compactMap(\.batteryW)
        return DischargeSession(
            start: first.t,
            end: last.t,
            startPercent: startPercent,
            endPercent: endPercent,
            activeMinutes: slice.count,
            averagePowerW: powers.isEmpty ? nil : powers.reduce(0, +) / Double(powers.count),
            ongoing: !pluggedNow && endIndex == log.count - 1)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }
}

/// Quartiles of the discharge power in watts.
public struct PowerQuartiles: Equatable, Sendable {
    public var low: Double
    public var median: Double
    public var high: Double
    public var count: Int

    public init(low: Double, median: Double, high: Double, count: Int) {
        self.low = low
        self.median = median
        self.high = high
        self.count = count
    }
}

/// Your battery usage by time of day (hour, weekday/weekend), with a flat median as fallback.
public struct DischargeProfile: Equatable, Sendable {
    /// Key: hour 0–23, plus 24 on weekends.
    public var buckets: [Int: PowerQuartiles] = [:]
    /// By hour only, without weekday.
    public var hourly: [Int: PowerQuartiles] = [:]
    public var flat: PowerQuartiles?

    public init() {}

    /// The quartiles for a point in time; `byHour == false` means flat fallback.
    func quartiles(at date: Date, calendar: Calendar) -> (PowerQuartiles, byHour: Bool)? {
        let hour = calendar.component(.hour, from: date)
        let weekend = calendar.isDateInWeekend(date)
        if let q = buckets[hour + (weekend ? 24 : 0)], q.count >= BatteryEstimator.minBucketMinutes { return (q, true) }
        if let q = hourly[hour], q.count >= BatteryEstimator.minBucketMinutes { return (q, true) }
        return flat.map { ($0, false) }
    }
}

/// One forecast point in the charge chart (percent).
public struct BandPoint: Identifiable, Equatable, Sendable {
    public var t: Date
    /// At heavy usage (upper quartile).
    public var low: Double
    public var median: Double
    /// At light usage (lower quartile).
    public var high: Double
    public var id: Date { t }
}

/// Forecast by time of day with an uncertainty band.
public struct RhythmForecast: Equatable, Sendable {
    /// Empty at heavy / typical / light usage (from now); nil = not within the horizon.
    public var early: TimeInterval?
    public var median: TimeInterval?
    public var late: TimeInterval?
    /// 20 % reached (typical usage).
    public var low: TimeInterval?
    public var curve: [BandPoint]
    /// false: too little data per hour, flat median.
    public var byHour: Bool
}

extension BatteryEstimator {
    /// From this many battery minutes on, an hour counts on its own.
    public static let minBucketMinutes = 30
    /// The forecast looks at most this far ahead.
    public static let rhythmHorizon: TimeInterval = 48 * 3600

    /// Usage profile from the battery minutes of the last 7 days.
    public static func profile(log: [MinuteSample], now: Date = .now, calendar: Calendar = .current) -> DischargeProfile {
        var buckets: [Int: [Double]] = [:]
        var hourly: [Int: [Double]] = [:]
        var all: [Double] = []
        let start = now.addingTimeInterval(-typicalWindow)
        for s in log where s.t >= start && s.isDischarging {
            guard let w = s.batteryW else { continue }
            let hour = calendar.component(.hour, from: s.t)
            buckets[hour + (calendar.isDateInWeekend(s.t) ? 24 : 0), default: []].append(w)
            hourly[hour, default: []].append(w)
            all.append(w)
        }
        var p = DischargeProfile()
        p.buckets = buckets.compactMapValues(quartiles)
        p.hourly = hourly.compactMapValues(quartiles)
        p.flat = all.count >= 60 ? quartiles(all) : nil
        return p
    }

    /// Steps the remaining energy minute by minute through the hours of the profile until the battery is empty.
    /// In the first hour the usage of the last 30 min weighs more (fully at first, not at all after 1 h).
    public static func rhythmForecast(remainingWh: Double, fullWh: Double, percent: Double, recentPowerW: Double?,
                                      profile: DischargeProfile, now: Date = .now,
                                      calendar: Calendar = .current) -> RhythmForecast? {
        guard remainingWh > 0, fullWh > 0, profile.flat != nil else { return nil }
        let lowWh = fullWh * 0.2
        var wh = (high: remainingWh, median: remainingWh, low: remainingWh) // usage: heavy, typical, light
        var result = RhythmForecast(curve: [BandPoint(t: now, low: percent, median: percent, high: percent)], byHour: false)
        let scale = percent / remainingWh
        let steps = Int(rhythmHorizon / 60)

        for step in 0..<steps {
            let t = now.addingTimeInterval(Double(step) * 60)
            guard let (q, byHour) = profile.quartiles(at: t.addingTimeInterval(30), calendar: calendar) else { return nil }
            if byHour { result.byHour = true }
            let w = recentPowerW.map { _ in max(0, 1 - Double(step) / 60) } ?? 0
            let recent = recentPowerW ?? 0
            let power = (high: w * recent + (1 - w) * q.high,
                         median: w * recent + (1 - w) * q.median,
                         low: w * recent + (1 - w) * q.low)

            // Point within the minute at which a threshold is crossed.
            func crossing(_ before: Double, _ p: Double, _ threshold: Double) -> TimeInterval? {
                let after = before - p / 60
                guard before > threshold, after <= threshold, p > 0 else { return nil }
                return Double(step) * 60 + (before - threshold) / p * 3600
            }
            if result.early == nil { result.early = crossing(wh.high, power.high, 0) }
            if result.median == nil { result.median = crossing(wh.median, power.median, 0) }
            if result.late == nil { result.late = crossing(wh.low, power.low, 0) }
            if result.low == nil { result.low = crossing(wh.median, power.median, lowWh) }
            wh = (max(0, wh.high - power.high / 60), max(0, wh.median - power.median / 60), max(0, wh.low - power.low / 60))

            if (step + 1) % 5 == 0 || result.late != nil {
                result.curve.append(BandPoint(t: t.addingTimeInterval(60), low: wh.high * scale,
                                              median: wh.median * scale, high: wh.low * scale))
            }
            if result.late != nil { break }
        }
        return result
    }

    static func quartiles(_ values: [Double]) -> PowerQuartiles? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        func quantile(_ q: Double) -> Double {
            let x = q * Double(s.count - 1)
            let i = Int(x)
            return i + 1 < s.count ? s[i] + (s[i + 1] - s[i]) * (x - Double(i)) : s[i]
        }
        return PowerQuartiles(low: quantile(0.25), median: quantile(0.5), high: quantile(0.75), count: s.count)
    }
}
