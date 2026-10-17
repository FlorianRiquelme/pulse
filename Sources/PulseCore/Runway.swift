import Foundation

/// Mini battery history for the menu bar: the last hour of charge level and the forecast down to 0 %.
/// Coordinates 0…1 (x: time, y: charge level); the past on the left, the future on the right at the same scale.
public struct Runway: Equatable, Sendable {
    public struct Pt: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// Measured segments; gaps (e.g. sleep) separate them.
    public var segments: [[Pt]] = []
    public var now: Pt
    /// End of the dashed forecast, nil on power adapter.
    public var projectionEnd: Pt?

    /// - Parameters:
    ///   - points: Charge level in percent (0–100), sorted by time.
    ///   - remaining: Remaining runtime; nil on power adapter or without a forecast.
    ///   - buckets: The past is averaged down to this many points.
    public init(points: [Point], now date: Date, percent: Double, remaining: TimeInterval?,
                past: TimeInterval = 3600, future: TimeInterval = 3600, buckets: Int = 30) {
        let start = date.addingTimeInterval(-past)
        let span = past + future
        func x(_ t: Date) -> Double { min(1, max(0, t.timeIntervalSince(start) / span)) }
        func y(_ p: Double) -> Double { min(1, max(0, p / 100)) }

        // Average into equally long time windows
        let width = past / Double(buckets)
        var sums = [(t: Double, v: Double, n: Int)](repeating: (0, 0, 0), count: buckets)
        for p in points {
            let offset = p.t.timeIntervalSince(start)
            guard offset >= 0, offset <= past else { continue }
            let i = min(buckets - 1, Int(offset / width))
            sums[i].t += offset
            sums[i].v += p.v
            sums[i].n += 1
        }

        var segments: [[Pt]] = []
        var lastIndex: Int?
        for (i, s) in sums.enumerated() where s.n > 0 {
            let pt = Pt(x: s.t / Double(s.n) / span, y: y(s.v / Double(s.n)))
            // If more than one window is missing, a new segment begins.
            if let lastIndex, i - lastIndex <= 2 { segments[segments.count - 1].append(pt) } else { segments.append([pt]) }
            lastIndex = i
        }
        self.now = Pt(x: x(date), y: y(percent))
        if let lastIndex, lastIndex >= buckets - 2 { segments[segments.count - 1].append(now) }
        self.segments = segments

        if let remaining, remaining > 0 {
            let shown = min(remaining, future)
            projectionEnd = Pt(x: x(date.addingTimeInterval(shown)), y: y(percent * (1 - shown / remaining)))
        }
    }
}
