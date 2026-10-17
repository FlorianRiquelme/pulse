import Foundation

/// One minute of readings (averages), persisted for 24 h charts and battery forecasts.
public struct MinuteSample: Codable, Equatable, Sendable {
    public var t: Date
    /// Battery level in percent (0–100), nil without a battery.
    public var battery: Double?
    /// Power adapter connected.
    public var plugged: Bool
    public var charging: Bool
    /// Battery power in watts: positive = discharging, negative = charging.
    public var batteryW: Double?
    public var systemW: Double?
    /// CPU load 0–1.
    public var cpu: Double
    public var gpu: Double?
    /// Used memory 0–1.
    public var mem: Double
    public var socTemp: Double?
    /// Backfilled from the powerlog: battery values only.
    public var imported: Bool?
    /// Used swap in bytes.
    public var swap: Double?
    /// Swap in and out in bytes/s.
    public var swapIn: Double?
    public var swapOut: Double?

    enum CodingKeys: String, CodingKey {
        case t, battery = "b", plugged = "p", charging = "c", batteryW = "bw", systemW = "sw",
             cpu = "cpu", gpu = "gpu", mem = "mem", socTemp = "tmp", imported = "imp", swap = "swp", swapIn = "si", swapOut = "so"
    }

    public init(t: Date, battery: Double?, plugged: Bool, charging: Bool, batteryW: Double?, systemW: Double?,
                cpu: Double, gpu: Double?, mem: Double, socTemp: Double?,
                swap: Double? = nil, swapIn: Double? = nil, swapOut: Double? = nil, imported: Bool? = nil) {
        self.t = t
        self.battery = battery
        self.plugged = plugged
        self.charging = charging
        self.batteryW = batteryW
        self.systemW = systemW
        self.cpu = cpu
        self.gpu = gpu
        self.mem = mem
        self.socTemp = socTemp
        self.imported = imported
        self.swap = swap
        self.swapIn = swapIn
        self.swapOut = swapOut
    }

    public var isImported: Bool { imported == true }

    /// The minute ran on battery and actually drained it.
    public var isDischarging: Bool { !plugged && (batteryW ?? 0) > 0.2 }
}

/// Averages the individual readings of a minute into one `MinuteSample`.
public struct MinuteAccumulator: Sendable {
    private var minute: Date?
    private var samples: [MinuteSample] = []

    public init() {}

    /// Adds a reading. When a new minute begins, returns the averaged previous one.
    public mutating func add(_ sample: MinuteSample) -> MinuteSample? {
        let m = Self.minuteStart(sample.t)
        var finished: MinuteSample?
        if let minute, minute != m {
            finished = Self.average(samples, at: minute)
            samples.removeAll()
        }
        minute = m
        samples.append(sample)
        return finished
    }

    /// Returns the minute in progress (e.g. on quit).
    public mutating func flush() -> MinuteSample? {
        defer { samples.removeAll(); minute = nil }
        guard let minute else { return nil }
        return Self.average(samples, at: minute)
    }

    public static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
    }

    static func average(_ samples: [MinuteSample], at minute: Date) -> MinuteSample? {
        guard let last = samples.last else { return nil }
        func mean(_ values: [Double?]) -> Double? {
            let v = values.compactMap { $0 }
            return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
        }
        return MinuteSample(
            t: minute,
            battery: last.battery,
            plugged: last.plugged,
            charging: last.charging,
            batteryW: mean(samples.map(\.batteryW)),
            systemW: mean(samples.map(\.systemW)),
            cpu: mean(samples.map(\.cpu)) ?? 0,
            gpu: mean(samples.map(\.gpu)),
            mem: mean(samples.map(\.mem)) ?? 0,
            socTemp: mean(samples.map(\.socTemp)),
            swap: mean(samples.map(\.swap)),
            swapIn: mean(samples.map(\.swapIn)),
            swapOut: mean(samples.map(\.swapOut)))
    }
}

/// Minute log as a JSON Lines file (one line per minute, append-only).
public final class MinuteLog {
    public static let retention: TimeInterval = 8 * 24 * 3600

    public let url: URL
    public private(set) var samples: [MinuteSample] = []
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    public init(url: URL) {
        self.url = url
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date.now.addingTimeInterval(-Self.retention)
        var loaded: [MinuteSample] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if let s = try? decoder.decode(MinuteSample.self, from: Data(line)), s.t >= cutoff {
                loaded.append(s)
            }
        }
        samples = loaded.sorted { $0.t < $1.t }
        rewrite()
    }

    public func append(_ sample: MinuteSample) {
        if let last = samples.last, sample.t <= last.t { return }
        samples.append(sample)
        guard var line = try? encoder.encode(sample) else { return }
        line.append(UInt8(ascii: "\n"))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: url)
        }
        // Trim old entries now and then so the file does not keep growing.
        if let first = samples.first, sample.t.timeIntervalSince(first.t) > Self.retention + 24 * 3600 {
            samples.removeAll { $0.t < sample.t.addingTimeInterval(-Self.retention) }
            rewrite()
        }
    }

    private func rewrite() {
        var data = Data()
        for s in samples {
            if let line = try? encoder.encode(s) {
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Backfills minutes that have no entry yet (e.g. from the powerlog), only before `before`.
    /// Returns the number of new minutes.
    @discardableResult
    public func merge(_ backfill: [MinuteSample], before: Date, now: Date = .now) -> Int {
        let cutoff = now.addingTimeInterval(-Self.retention)
        var known = Set(samples.map { MinuteAccumulator.minuteStart($0.t) })
        var added: [MinuteSample] = []
        for s in backfill where s.t >= cutoff && s.t < before {
            let minute = MinuteAccumulator.minuteStart(s.t)
            guard known.insert(minute).inserted else { continue }
            added.append(s)
        }
        guard !added.isEmpty else { return 0 }
        samples = (samples + added).sorted { $0.t < $1.t }
        rewrite()
        return added.count
    }

    public func since(_ date: Date) -> [MinuteSample] {
        guard let index = samples.firstIndex(where: { $0.t >= date }) else { return [] }
        return Array(samples[index...])
    }
}
