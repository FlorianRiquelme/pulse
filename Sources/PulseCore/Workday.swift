import Foundation

/// The bare minimum from Stempeluhr's `ledger.json` (read-only, other fields are ignored).
public struct WorkLedger: Decodable, Equatable, Sendable {
    public struct Block: Decodable, Equatable, Sendable {
        public var start: Date
        /// `nil` while the block is running.
        public var end: Date?

        public init(start: Date, end: Date? = nil) {
            self.start = start
            self.end = end
        }
    }

    public struct Day: Decodable, Equatable, Sendable {
        public var submitted: Bool?
        /// Minutes taken from the time account on this day.
        public var kontoDraw: Int?

        public init(submitted: Bool? = nil, kontoDraw: Int? = nil) {
            self.submitted = submitted
            self.kontoDraw = kontoDraw
        }
    }

    public var blocks: [Block]
    public var days: [String: Day]
    public var paused: Bool

    public init(blocks: [Block] = [], days: [String: Day] = [:], paused: Bool = false) {
        self.blocks = blocks
        self.days = days
        self.paused = paused
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? []
        days = try c.decodeIfPresent([String: Day].self, forKey: .days) ?? [:]
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
    }

    private enum CodingKeys: String, CodingKey { case blocks, days, paused }

    public static func decode(_ data: Data) throws -> WorkLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkLedger.self, from: data)
    }
}

/// Stempeluhr's settings, as far as they matter for the end of the workday.
public struct WorkRules: Equatable, Sendable {
    public var weeklyTargetMinutes: Int
    /// `Calendar` weekdays with a target (1 = Sunday, 2 = Monday …).
    public var workdays: Set<Int>
    /// Gaps of at least this length count as a break.
    public var minBreakGap: TimeInterval

    public init(weeklyTargetMinutes: Int = 2400, workdays: Set<Int> = [2, 3, 4, 5, 6], minBreakGap: TimeInterval = 15 * 60) {
        self.weeklyTargetMinutes = weeklyTargetMinutes
        self.workdays = workdays
        self.minBreakGap = minBreakGap
    }

    /// Daily target: weekly hours spread evenly across the workdays (38:30 h / 5 = 7:42 h), as in Stempeluhr.
    public var dailyTarget: TimeInterval {
        (Double(weeklyTargetMinutes) / Double(max(1, workdays.count))).rounded() * 60
    }

    /// "2,3,4,5,6" → [2, 3, 4, 5, 6]
    public static func weekdays(_ string: String) -> Set<Int> {
        Set(string.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }
}

/// Net working time of a day as in StempelCore (`DaySummary`).
public struct WorkSummary: Equatable, Sendable {
    public var gross: TimeInterval
    /// Gaps between blocks that count as a break.
    public var gaps: TimeInterval
    public var net: TimeInterval { gross - max(0, Self.requiredBreak(gross: gross) - gaps) }

    public init(ranges: [(start: Date, end: Date)], minBreakGap: TimeInterval) {
        // Merge overlapping blocks so nothing counts twice.
        var merged: [(start: Date, end: Date)] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, range.start <= last.end {
                merged[merged.count - 1].end = max(last.end, range.end)
            } else {
                merged.append(range)
            }
        }
        gross = merged.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }
        gaps = zip(merged, merged.dropFirst())
            .map { $0.1.start.timeIntervalSince($0.0.end) }
            .filter { $0 >= minBreakGap }
            .reduce(0, +)
    }

    /// German Working Hours Act (ArbZG) §4: 30 min over 6 h, 45 min over 9 h.
    public static func requiredBreak(gross: TimeInterval) -> TimeInterval {
        gross > 9 * 3600 ? 45 * 60 : gross > 6 * 3600 ? 30 * 60 : 0
    }
}

public enum Workday {
    /// Expected end of today's workday: now + missing net time + statutory break still owed.
    /// `nil` if nothing is due today (paused, not a workday, nothing tracked, target reached, submitted).
    public static func endOfDay(ledger: WorkLedger, rules: WorkRules, now: Date,
                                calendar: Calendar = .current) -> Date? {
        guard !ledger.paused, rules.workdays.contains(calendar.component(.weekday, from: now)) else { return nil }
        let today = ledger.blocks.filter { calendar.isDate($0.start, inSameDayAs: now) && $0.start <= now }
        guard !today.isEmpty else { return nil }
        let day = ledger.days[key(now, calendar: calendar)]
        guard day?.submitted != true else { return nil }
        let target = rules.dailyTarget - TimeInterval(day?.kontoDraw ?? 0) * 60
        guard target > 0 else { return nil }

        // Without a running block, work continues from now; the gap until now then counts as a break.
        var ranges = today.map { (start: $0.start, end: min($0.end ?? now, now)) }
        if !today.contains(where: { $0.end == nil }) { ranges.append((now, now)) }
        let summary = WorkSummary(ranges: ranges, minBreakGap: rules.minBreakGap)

        // Presence needed until the net target is reached (the mandatory break itself depends on it).
        var gross = target
        for _ in 0..<3 {
            gross = target + max(0, WorkSummary.requiredBreak(gross: gross) - summary.gaps)
        }
        let remaining = gross - summary.gross
        guard remaining > 0 else { return nil }
        let end = now.addingTimeInterval(remaining)
        return calendar.isDate(end, inSameDayAs: now) ? end : nil
    }

    static func key(_ day: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Does the battery last until the end of the workday?
public struct WorkdayRunway: Equatable, Sendable {
    public var endOfDay: Date
    /// When the battery runs out at current usage.
    public var batteryEnd: Date
    /// When it runs out at typical usage.
    public var typicalEnd: Date?
    /// How long you would need to charge for it to last (`nil`: it lasts, or charging power is unknown).
    public var chargeNeeded: TimeInterval?

    public var fits: Bool { batteryEnd >= endOfDay }

    /// - Parameters:
    ///   - remaining: Remaining runtime at current usage (`BatteryEstimate.best`).
    ///   - powerW: The matching discharge power.
    ///   - chargePowerW: Usual charging power.
    public init(endOfDay: Date, remaining: TimeInterval, typical: TimeInterval?, powerW: Double?,
                chargePowerW: Double?, now: Date) {
        self.endOfDay = endOfDay
        batteryEnd = now.addingTimeInterval(remaining)
        typicalEnd = typical.map { now.addingTimeInterval($0) }
        let missing = endOfDay.timeIntervalSince(batteryEnd)
        if missing > 0, let powerW, powerW > 0, let chargePowerW, chargePowerW > 0.5 {
            // Missing energy divided by the charging power, rounded up to 5 min.
            let seconds = powerW * missing / chargePowerW
            chargeNeeded = max(5, (seconds / 300).rounded(.up) * 5) * 60
        }
    }
}

public extension BatteryEstimator {
    /// Median charging power from the minute log (positive, in watts).
    static func typicalChargePower(log: [MinuteSample]) -> Double? {
        median(log.filter { $0.plugged && $0.charging }.compactMap(\.batteryW).filter { $0 < -0.5 }.map { -$0 })
    }
}
