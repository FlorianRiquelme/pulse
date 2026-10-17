import Foundation

/// Records each app's memory footprint every 5 min for a few hours and spots apps that grow steadily.
public struct GrowthTracker<Key: Hashable & Sendable>: Sendable {
    public struct Growth: Equatable, Sendable {
        public var key: Key
        /// How long the footprint has been rising (from the low point until now).
        public var duration: TimeInterval
        /// Growth in bytes per hour (regression line).
        public var perHour: Double
        /// Growth since the low point in bytes, roughly what a restart would free.
        public var gained: Double
    }

    public static var step: TimeInterval { 5 * 60 }
    public static var window: TimeInterval { 6 * 3600 }
    public static var minDuration: TimeInterval { 3600 }
    public static var minPerHour: Double { 50_000_000 }
    public static var minGain: Double { 200_000_000 }

    private var history: [Key: [Point]] = [:]

    public init() {}

    /// Records the current values of all apps; at most one point per app per `step`.
    public mutating func add(_ values: [Key: Double], at date: Date) {
        let cutoff = date.addingTimeInterval(-Self.window)
        for (key, value) in values {
            var points = history[key] ?? []
            if let last = points.last, date.timeIntervalSince(last.t) < Self.step { continue }
            points.append(Point(t: date, v: value))
            if let first = points.firstIndex(where: { $0.t >= cutoff }), first > 0 { points.removeFirst(first) }
            history[key] = points
        }
        // Forget apps that have quit.
        for key in history.keys where values[key] == nil { history[key] = nil }
    }

    /// Apps whose memory footprint has risen steadily for at least an hour, largest growth first.
    public func growing() -> [Growth] {
        history.compactMap { key, points in Self.growth(of: points).map { Growth(key: key, duration: $0.0, perHour: $0.1, gained: $0.2) } }
            .sorted { $0.gained > $1.gained }
    }

    static func growth(of points: [Point]) -> (TimeInterval, Double, Double)? {
        // On a tie, take the latest low point.
        guard let low = points.indices.reversed().min(by: { points[$0].v < points[$1].v }) else { return nil }
        let rise = points[low...]
        guard rise.count >= 4, let first = rise.first, let last = rise.last else { return nil }
        let duration = last.t.timeIntervalSince(first.t)
        let gained = last.v - first.v
        guard duration >= Self.minDuration, gained >= Self.minGain else { return nil }
        // Still growing: the last value is close to the peak.
        let peak = rise.map(\.v).max() ?? last.v
        guard peak - last.v <= 0.1 * gained else { return nil }

        // Regression line; only a steady rise counts, not a single step.
        let xs = rise.map { $0.t.timeIntervalSince(first.t) / 3600 }
        let ys = rise.map(\.v)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in zip(xs, ys) {
            sxy += (x - mx) * (y - my)
            sxx += (x - mx) * (x - mx)
            syy += (y - my) * (y - my)
        }
        guard sxx > 0, syy > 0 else { return nil }
        let slope = sxy / sxx
        let r2 = sxy * sxy / (sxx * syy)
        guard slope >= Self.minPerHour, r2 >= 0.8 else { return nil }
        return (duration, slope, gained)
    }
}
