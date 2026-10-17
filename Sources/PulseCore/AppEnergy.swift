import Foundation

/// One row of powerlog's energy table: what an app (coalition) used during an interval.
public struct CoalitionInterval: Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// App key, see `AppEnergyLedger.key`.
    public var key: String
    /// Energy in joules (CPU, GPU and ANE).
    public var joules: Double

    public init(start: Date, end: Date, key: String, joules: Double) {
        self.start = start
        self.end = end
        self.key = key
        self.joules = joules
    }

    var mid: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

/// Power adapter state at a point in time (from powerlog's battery table).
public struct PowerState: Equatable, Sendable {
    public var t: Date
    public var plugged: Bool

    public init(t: Date, plugged: Bool) {
        self.t = t
        self.plugged = plugged
    }
}

/// Energy per app on one day.
public struct DayEnergy: Equatable, Sendable {
    /// Start of the day (local).
    public var day: Date
    /// Wh per app, overall.
    public var total: [String: Double] = [:]
    /// Wh per app, on battery only.
    public var battery: [String: Double] = [:]

    public init(day: Date, total: [String: Double] = [:], battery: [String: Double] = [:]) {
        self.day = day
        self.total = total
        self.battery = battery
    }

    public func apps(batteryOnly: Bool) -> [String: Double] { batteryOnly ? battery : total }
}

public enum AppEnergyLedger {
    /// One key per app. Helper processes run in the app's coalition; its launchd name
    /// ("application.com.microsoft.Outlook.586141.586147") reveals the actual app.
    public static func key(bundleId: String?, launchdName: String?) -> String? {
        if let name = launchdName, name.hasPrefix("application.") {
            var parts = name.dropFirst("application.".count).split(separator: ".")
            while let last = parts.last, parts.count > 1, last.allSatisfy(\.isNumber) { parts.removeLast() }
            if !parts.isEmpty { return parts.joined(separator: ".") }
        }
        if let id = bundleId, !id.isEmpty { return id }
        guard let name = launchdName, !name.isEmpty else { return nil }
        // "com.apple.mdworker.shared.07000000-…": the UUID only separates instances.
        var parts = name.split(separator: ".")
        if let last = parts.last, parts.count > 1, last.count == 36, last.contains("-") { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// Groups intervals by day and app (the midpoint of the interval decides).
    /// `states` must be sorted by time; without a known state an interval does not count as battery.
    public static func days(_ intervals: [CoalitionInterval], states: [PowerState],
                            calendar: Calendar = .current) -> [DayEnergy] {
        var byDay: [Date: DayEnergy] = [:]
        for interval in intervals where interval.joules > 0 {
            let mid = interval.mid
            let day = calendar.startOfDay(for: mid)
            let wh = interval.joules / 3600
            var entry = byDay[day] ?? DayEnergy(day: day)
            entry.total[interval.key, default: 0] += wh
            if plugged(at: mid, states: states) == false { entry.battery[interval.key, default: 0] += wh }
            byDay[day] = entry
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// Power adapter state at a point in time: last known state before it, otherwise the first one after.
    static func plugged(at t: Date, states: [PowerState]) -> Bool? {
        guard let first = states.first else { return nil }
        var lo = 0, hi = states.count
        while lo < hi {
            let m = (lo + hi) / 2
            if states[m].t <= t { lo = m + 1 } else { hi = m }
        }
        return lo == 0 ? first.plugged : states[lo - 1].plugged
    }

    /// Average power per app in watts over the window before the latest interval end
    /// (powerlog writes with a delay, so not "until now"). Intervals count proportionally.
    public static func recentPower(_ intervals: [CoalitionInterval], window: TimeInterval = 3600) -> [String: Double] {
        guard let latest = intervals.map(\.end).max() else { return [:] }
        let from = latest.addingTimeInterval(-window)
        guard let earliest = intervals.filter({ $0.end > from }).map(\.start).min() else { return [:] }
        let covered = latest.timeIntervalSince(max(from, earliest))
        guard covered >= 300 else { return [:] }
        var joules: [String: Double] = [:]
        for i in intervals where i.end > from && i.end > i.start {
            let overlap = i.end.timeIntervalSince(max(i.start, from))
            joules[i.key, default: 0] += i.joules * overlap / i.end.timeIntervalSince(i.start)
        }
        return joules.mapValues { $0 / covered }
    }

    /// Sum over several days, sorted descending.
    public static func ranking(_ days: [DayEnergy], batteryOnly: Bool) -> [(key: String, wh: Double)] {
        var sum: [String: Double] = [:]
        for day in days {
            for (key, wh) in day.apps(batteryOnly: batteryOnly) { sum[key, default: 0] += wh }
        }
        return sum.map { (key: $0.key, wh: $0.value) }.sorted { $0.wh > $1.wh || ($0.wh == $1.wh && $0.key < $1.key) }
    }
}
