import Foundation
import SQLite3

/// Battery history from the macOS powerlog: one row per minute, about 5 days back.
/// The database is private and undocumented; everything here fails silently (nil or empty).
public enum Powerlog {
    public static let directory = URL(fileURLWithPath: "/var/db/powerlog/Library/BatteryLife", isDirectory: true)
    public static var current: URL { directory.appendingPathComponent("CurrentPowerlog.PLSQL") }
    /// Daily archives (`powerlog_2026-10-02_….PLSQL.gz`).
    public static var archives: [URL] {
        let dir = directory.appendingPathComponent("Archives", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".PLSQL.gz") }.sorted().map { dir.appendingPathComponent($0) }
    }

    public struct Row: Equatable, Sendable {
        public var t: Date
        /// Charge level 0–100.
        public var level: Double
        /// mA, negative while discharging.
        public var amperage: Double
        /// mV
        public var voltage: Double
        public var external: Bool
        public var charging: Bool

        public init(t: Date, level: Double, amperage: Double, voltage: Double, external: Bool, charging: Bool) {
            self.t = t
            self.level = level
            self.amperage = amperage
            self.voltage = voltage
            self.external = external
            self.charging = charging
        }

        /// Battery power as in Pulse: positive = discharging.
        public var batteryW: Double { -amperage * voltage / 1_000_000 }
    }

    /// Reads the battery rows from `since` on. `immutable` for unpacked archives (without WAL);
    /// the live database is opened read-only. nil if the file or table is missing.
    public static func batteryRows(at url: URL, since: Date = .distantPast, immutable: Bool = false) -> [Row]? {
        query(url, immutable: immutable, """
            SELECT timestamp, Level, InstantAmperage, Voltage, ExternalConnected, IsCharging
            FROM PLBatteryAgent_EventBackward_Battery WHERE timestamp >= \(since.timeIntervalSince1970) ORDER BY timestamp
            """) { column in
            guard let t = column(0), let level = column(1), (0...100).contains(level),
                  let voltage = column(3), voltage > 0 else { return nil }
            return Row(t: Date(timeIntervalSince1970: t), level: level, amperage: column(2) ?? 0, voltage: voltage,
                       external: (column(4) ?? 0) != 0, charging: (column(5) ?? 0) != 0)
        }
    }

    /// Runs a query; `row` gets columns as Double (nil = NULL) and skips rows that return nil.
    private static func query<T>(_ url: URL, immutable: Bool, _ sql: String,
                                 row: ((Int32) -> Double?) -> T?) -> [T]? {
        var components = URLComponents()
        components.scheme = "file"
        components.path = url.path
        components.queryItems = [immutable ? URLQueryItem(name: "immutable", value: "1") : URLQueryItem(name: "mode", value: "ro")]
        guard let uri = components.string else { return nil }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else { return nil }
        sqlite3_busy_timeout(db, 200)
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }

        func column(_ i: Int32) -> Double? {
            sqlite3_column_type(statement, i) == SQLITE_NULL ? nil : sqlite3_column_double(statement, i)
        }
        var result: [T] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return result.isEmpty ? nil : result }
            if let value = row(column) { result.append(value) }
        }
        return result
    }

    /// When the display turned on or off (`true` = on). nil if the table is missing.
    public static func backlightEvents(at url: URL, immutable: Bool = false) -> [(t: Date, on: Bool)]? {
        query(url, immutable: immutable, """
            SELECT timestamp, Active FROM PLDisplayAgent_EventPoint_Display WHERE Block = 'Backlight' ORDER BY timestamp
            """) { column in
            guard let t = column(0), let active = column(1) else { return nil }
            return (Date(timeIntervalSince1970: t), active != 0)
        }
    }

    /// Groups the rows into minutes (like Pulse's minute log).
    /// Rows with the display off do not count toward power: the Mac was awake but
    /// not in use (e.g. kept awake all night), which would skew the typical usage.
    public static func samples(from rows: [Row], backlight: [(t: Date, on: Bool)] = []) -> [MinuteSample] {
        let events = backlight.sorted { $0.t < $1.t }
        var next = 0
        var screenOn = true
        var result: [MinuteSample] = []
        var watts: [Double] = []
        for row in rows.sorted(by: { $0.t < $1.t }) {
            while next < events.count, events[next].t <= row.t {
                screenOn = events[next].on
                next += 1
            }
            let minute = MinuteAccumulator.minuteStart(row.t)
            if result.last?.t != minute {
                watts.removeAll()
                result.append(imported(t: minute, battery: row.level, plugged: row.external, charging: row.charging, batteryW: nil))
            }
            if screenOn { watts.append(row.batteryW) }
            result[result.count - 1].battery = row.level
            result[result.count - 1].plugged = row.external
            result[result.count - 1].charging = row.charging
            result[result.count - 1].batteryW = watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count)
        }
        return result
    }

    /// Fallback if the powerlog is not readable: the lines "Using Batt(Charge: 87)" or
    /// "Using AC (Charge:100%)" from `pmset -g log`. Charge level only, no power.
    public static func samples(fromPmsetLog text: String) -> [MinuteSample] {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var result: [MinuteSample] = []
        for line in text.split(separator: "\n") {
            guard line.count > 25, let using = line.range(of: "Using ", options: .backwards),
                  let date = parser.date(from: String(line.prefix(25))) else { continue }
            let rest = line[using.upperBound...]
            let plugged: Bool
            if rest.hasPrefix("AC") { plugged = true } else if rest.hasPrefix("Batt") { plugged = false } else { continue }
            guard let charge = rest.range(of: "Charge:") else { continue }
            let digits = rest[charge.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
            guard let level = Double(digits), (0...100).contains(level) else { continue }
            let minute = MinuteAccumulator.minuteStart(date)
            let sample = imported(t: minute, battery: level, plugged: plugged, charging: false, batteryW: nil)
            if result.last?.t == minute { result[result.count - 1] = sample } else { result.append(sample) }
        }
        return result.sorted { $0.t < $1.t }
    }

    private static func imported(t: Date, battery: Double, plugged: Bool, charging: Bool, batteryW: Double?) -> MinuteSample {
        MinuteSample(t: t, battery: battery, plugged: plugged, charging: charging, batteryW: batteryW, systemW: nil,
                     cpu: 0, gpu: nil, mem: 0, socTemp: nil, imported: true)
    }
}
