import Foundation

/// One sleep: from falling asleep until fully waking up.
public struct SleepRecord: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    /// Charge level in percent (0–100) when falling asleep and waking up.
    public var startPercent: Double?
    public var endPercent: Double?
    /// On power adapter at some point during sleep: usage is not meaningful.
    public var plugged: Bool
    /// Brief wakeups in the dark (DarkWake), nil = not read from `pmset -g log` yet.
    public var darkWakes: Int?
    /// Who caused the wakeup: process (for timers), otherwise "Hardware" or "Notification".
    public var wakers: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case start = "s", end = "e", startPercent = "sp", endPercent = "ep", plugged = "p", darkWakes = "dw", wakers = "w"
    }

    public init(start: Date, end: Date, startPercent: Double?, endPercent: Double?, plugged: Bool,
                darkWakes: Int? = nil, wakers: [String: Int]? = nil) {
        self.start = start
        self.end = end
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.plugged = plugged
        self.darkWakes = darkWakes
        self.wakers = wakers
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    /// Drop in percentage points (battery only).
    public var drop: Double? {
        guard !plugged, let s = startPercent, let e = endPercent else { return nil }
        return max(0, s - e)
    }

    /// Drop per hour; only meaningful from 30 min of sleep on.
    public var percentPerHour: Double? {
        guard let drop, duration >= 30 * 60 else { return nil }
        return drop / (duration / 3600)
    }

    /// The most frequent wakers, descending.
    public var topWakers: [(name: String, count: Int)] {
        (wakers ?? [:]).sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (name: $0.key, count: $0.value) }
    }

    /// Takes the wakeup count and missing charge levels from the power log.
    public mutating func apply(_ details: SleepRecord) {
        darkWakes = details.darkWakes
        wakers = details.wakers
        plugged = plugged || details.plugged
        if startPercent == nil { startPercent = details.startPercent }
        if endPercent == nil { endPercent = details.endPercent }
    }
}

/// The most recent sleeps as a JSON Lines file (small, rewritten on change).
public final class SleepLog {
    public static let limit = 30
    /// Shorter awake phases in between (e.g. notifications) still count as the same sleep.
    public static let mergeGap: TimeInterval = 120

    public let url: URL
    public private(set) var records: [SleepRecord] = []
    /// Whether the file already existed (otherwise backfilling from `pmset -g log` is worth it).
    public private(set) var existed = false

    public init(url: URL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        existed = true
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        records = data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? decoder.decode(SleepRecord.self, from: Data($0)) }
            .sorted { $0.start < $1.start }
    }

    /// Adds a sleep; if it closely follows the previous one, both are merged.
    @discardableResult
    public func add(_ record: SleepRecord) -> SleepRecord {
        var merged = record
        if let last = records.last, record.start.timeIntervalSince(last.end) < Self.mergeGap, record.start >= last.start {
            merged.start = last.start
            merged.startPercent = last.startPercent ?? record.startPercent
            merged.plugged = last.plugged || record.plugged
            merged.darkWakes = nil
            merged.wakers = nil
            records.removeLast()
        }
        records.append(merged)
        save()
        return merged
    }

    /// Adds details to the sleep that began at `start`.
    public func update(start: Date, with details: SleepRecord) {
        guard let i = records.lastIndex(where: { $0.start == start }) else { return }
        records[i].apply(details)
        save()
    }

    /// Replaces everything (backfill from the power log on first launch).
    public func replace(with records: [SleepRecord]) {
        self.records = records
        save()
    }

    /// Typical drop per hour on battery (median).
    public var typicalPercentPerHour: Double? {
        let rates = records.compactMap(\.percentPerHour).sorted()
        guard rates.count >= 3 else { return nil }
        let mid = rates.count / 2
        return rates.count % 2 == 0 ? (rates[mid - 1] + rates[mid]) / 2 : rates[mid]
    }

    public func overlapping(_ start: Date, _ end: Date = .distantFuture) -> [SleepRecord] {
        records.filter { $0.end > start && $0.start < end }
    }

    private func save() {
        records = Array(records.suffix(Self.limit))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for r in records {
            if let line = try? encoder.encode(r) {
                data.append(line)
                data.append(UInt8(ascii: "\n"))
            }
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        existed = true
    }
}

/// Reads sleeps from the output of `pmset -g log`.
public enum PowerLog {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return f
    }()

    /// All sleeps that began after `since`. Only scans the end of the log.
    public static func sleeps(in text: String, since: Date = .distantPast) -> [SleepRecord] {
        let lines = text.utf8.split(separator: 10).compactMap { Substring($0) }
        // Walk back from the end to the start time; timestamps are local and sort lexicographically.
        var first = 0
        if since > .distantPast {
            let key = String(formatter.string(from: since).prefix(19))
            first = lines.count
            while first > 0 {
                if let stamp = timestampPrefix(lines[first - 1]), stamp < key { break }
                first -= 1
            }
        }

        var result: [SleepRecord] = []
        var current: SleepRecord?
        var lastDarkWake: (date: Date, waker: String)?
        var requester: String?
        for line in lines[first...] {
            guard let (date, domain, message) = parse(line) else { continue }
            let charge = chargePercent(message)
            let onAC = message.contains("Using AC")
            switch domain {
            case "Sleep" where message.hasPrefix("Entering Sleep state") || message.hasPrefix("Entering DarkWake state"):
                guard current == nil, date >= since else { continue }
                if var last = result.last, date.timeIntervalSince(last.end) < SleepLog.mergeGap {
                    // Briefly fully awake (e.g. a notification) and right back to sleep: the same sleep.
                    result.removeLast()
                    last.darkWakes = (last.darkWakes ?? 0) + 1
                    last.plugged = last.plugged || onAC
                    current = last
                } else {
                    current = SleepRecord(start: date, end: date, startPercent: charge, endPercent: nil,
                                          plugged: onAC, darkWakes: 0, wakers: [:])
                }
            case "Wake Requests":
                guard current != nil else { continue }
                requester = starredProcess(message)
            case "DarkWake":
                guard var record = current else { continue }
                let who = message.contains("rtc/") ? (requester ?? "Timer")
                    : message.contains("Notification") ? "Notification" : "Hardware"
                record.darkWakes = (record.darkWakes ?? 0) + 1
                record.wakers?[who, default: 0] += 1
                record.plugged = record.plugged || onAC
                current = record
                lastDarkWake = (date, who)
                requester = nil
            case "Wake":
                guard var record = current else { continue }
                // A DarkWake that turns straight into a full wake was not a brief wakeup.
                if message.hasPrefix("DarkWake to FullWake"), let lastDarkWake, date.timeIntervalSince(lastDarkWake.date) < 60,
                   let n = record.darkWakes, n > 0 {
                    record.darkWakes = n - 1
                    let left = (record.wakers?[lastDarkWake.waker] ?? 1) - 1
                    record.wakers?[lastDarkWake.waker] = left > 0 ? left : nil
                }
                record.end = date
                record.endPercent = charge
                record.plugged = record.plugged || onAC
                result.append(record)
                current = nil
                requester = nil
                lastDarkWake = nil
            default:
                continue
            }
        }
        return result
    }

    /// Details of the sleep that best matches `start`…`end` (from the output of `pmset -g log`).
    public static func details(in text: String, start: Date, end: Date) -> SleepRecord? {
        let candidates = sleeps(in: text, since: start.addingTimeInterval(-5 * 60))
        return candidates.max { overlap($0, start, end) < overlap($1, start, end) }
            .flatMap { overlap($0, start, end) > 0 ? $0 : nil }
    }

    private static func overlap(_ r: SleepRecord, _ start: Date, _ end: Date) -> TimeInterval {
        min(r.end, end).timeIntervalSince(max(r.start, start))
    }

    private static func timestampPrefix(_ line: Substring) -> String? {
        guard line.utf8.count > 25, line.utf8.first.map({ $0 >= 48 && $0 <= 57 }) == true else { return nil }
        return String(line.prefix(19))
    }

    private static let domains: Set<String> = ["Sleep", "Wake", "DarkWake", "Wake Requests"]

    private static func parse(_ line: Substring) -> (Date, String, Substring)? {
        let bytes = Array(line.utf8.prefix(48))
        guard bytes.count > 27, bytes[0] >= 48, bytes[0] <= 57,
              let tab = bytes.firstIndex(of: 9), tab > 26 else { return nil }
        // Check the domain first: only parse dates for the few relevant lines.
        let domain = String(decoding: bytes[26..<tab], as: UTF8.self).trimmingCharacters(in: .whitespaces)
        guard domains.contains(domain), let date = date(bytes) else { return nil }
        let message = line.utf8.index(line.utf8.startIndex, offsetBy: tab + 1)
        return (date, domain, line[message...])
    }

    /// "2026-10-07 12:39:00 +0200" without DateFormatter (which would be noticeably slow for thousands of lines).
    static func date(_ b: [UInt8]) -> Date? {
        func num(_ from: Int, _ count: Int) -> Int? {
            var v = 0
            for i in from..<from + count {
                guard b[i] >= 48, b[i] <= 57 else { return nil }
                v = v * 10 + Int(b[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), let mo = num(5, 2), let d = num(8, 2), let h = num(11, 2), let mi = num(14, 2),
              let s = num(17, 2), let oh = num(21, 2), let om = num(23, 2) else { return nil }
        // Days since 1970 (Howard Hinnant, days_from_civil)
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146_097 + doe - 719_468
        let offset = (oh * 3600 + om * 60) * (b[20] == 45 ? -1 : 1)
        return Date(timeIntervalSince1970: TimeInterval(days * 86400 + h * 3600 + mi * 60 + s - offset))
    }

    private static func chargePercent(_ message: Substring) -> Double? {
        guard let r = message.range(of: "(Charge:") else { return nil }
        let digits = message[r.upperBound...].prefix { $0.isNumber }
        return Double(digits)
    }

    /// The process whose timer is due next (marked with *).
    private static func starredProcess(_ message: Substring) -> String? {
        guard let r = message.range(of: "[*process=") else { return nil }
        let name = message[r.upperBound...].prefix { $0 != " " && $0 != "]" }
        return name.isEmpty ? nil : String(name)
    }
}
