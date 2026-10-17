import Foundation

/// One data point of a time series.
public struct Point: Identifiable, Equatable, Sendable {
    public var t: Date
    public var v: Double
    public var id: Date { t }

    public init(t: Date, v: Double) {
        self.t = t
        self.v = v
    }
}

/// Fixed-length time series for the live charts (oldest points drop out).
public struct Series: Sendable {
    public let capacity: Int
    public private(set) var points: [Point] = []

    public init(capacity: Int) {
        self.capacity = capacity
    }

    public mutating func append(_ value: Double, at date: Date = .now) {
        points.append(Point(t: date, v: value))
        if points.count > capacity { points.removeFirst(points.count - capacity) }
    }

    public mutating func removeAll() { points.removeAll() }

    public var last: Double? { points.last?.v }
    public var max: Double? { points.map(\.v).max() }
    public var min: Double? { points.map(\.v).min() }
    public var average: Double? {
        points.isEmpty ? nil : points.reduce(0) { $0 + $1.v } / Double(points.count)
    }
    /// The last `count` values, e.g. for the mini graphs in the menu bar.
    public func tail(_ count: Int) -> [Double] { points.suffix(count).map(\.v) }
}

/// Exponentially smoothed average with a time constant, independent of the sampling interval.
public struct Smoothed: Sendable {
    public var tau: TimeInterval
    public private(set) var value: Double?
    private var lastDate: Date?

    public init(tau: TimeInterval) {
        self.tau = tau
    }

    public mutating func add(_ x: Double, at date: Date = .now) {
        guard let value, let lastDate else {
            self.value = x
            self.lastDate = date
            return
        }
        let dt = max(0, date.timeIntervalSince(lastDate))
        let alpha = 1 - exp(-dt / tau)
        self.value = value + alpha * (x - value)
        self.lastDate = date
    }

    public mutating func reset() {
        value = nil
        lastDate = nil
    }
}
