import Foundation
import PulseCore
import SQLite3

/// Energy per app from the macOS powerlog database (readable by everyone, system processes included).
/// Only queried when the panel opens (about 10 ms); older days are stored compressed in `Archives`.
final class PowerlogReader: @unchecked Sendable {
    struct Result: Sendable {
        var days: [DayEnergy]
        /// Watts per app in the last hour, for "Quitting saves …".
        var recentW: [String: Double]
    }

    private static let folder = URL(fileURLWithPath: "/private/var/db/powerlog/Library/BatteryLife")
    /// Archives no longer change; remember them once parsed (name → day of the archive).
    private var archived: [String: DayEnergy] = [:]
    private let queue = DispatchQueue(label: "pulse.powerlog", qos: .utility)

    func load(days count: Int = 7, completion: @escaping @Sendable (Result?) -> Void) {
        queue.async { [self] in completion(read(days: count)) }
    }

    private func read(days count: Int) -> Result? {
        let calendar = Calendar.current
        let since = calendar.date(byAdding: .day, value: -(count - 1), to: calendar.startOfDay(for: .now))!
        let current = Self.folder.appendingPathComponent("CurrentPowerlog.PLSQL")
        guard let rows = Self.query(url: current, readOnly: true, since: since) else { return nil }
        var days = AppEnergyLedger.days(rows.intervals, states: rows.states)

        // An archive "powerlog_2026-10-05_…" contains the full day; it takes precedence over the live database,
        // which only knows its last minutes.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let archives = (try? FileManager.default.contentsOfDirectory(at: Self.folder.appendingPathComponent("Archives"),
                                                                     includingPropertiesForKeys: nil)) ?? []
        for url in archives where url.lastPathComponent.hasSuffix(".PLSQL.gz") {
            let name = url.lastPathComponent
            guard let date = formatter.date(from: String(name.dropFirst("powerlog_".count).prefix(10))),
                  date >= since else { continue }
            let day = archived[name] ?? Self.readArchive(url, day: date, calendar: calendar)
            guard let day else { continue }
            archived[name] = day
            days.removeAll { $0.day == day.day }
            days.append(day)
        }
        days.sort { $0.day < $1.day }
        return Result(days: days.filter { $0.day >= since }, recentW: AppEnergyLedger.recentPower(rows.intervals))
    }

    private static func readArchive(_ url: URL, day: Date, calendar: Calendar) -> DayEnergy? {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-\(UUID().uuidString).PLSQL")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard FileManager.default.createFile(atPath: temp.path, contents: nil),
              let output = try? FileHandle(forWritingTo: temp) else { return nil }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-dc", url.path]
        gzip.standardOutput = output
        gzip.standardError = FileHandle.nullDevice
        do { try gzip.run() } catch { return nil }
        gzip.waitUntilExit()
        try? output.close()
        guard gzip.terminationStatus == 0,
              let rows = query(url: temp, readOnly: false, since: day) else { return nil }
        return AppEnergyLedger.days(rows.intervals, states: rows.states, calendar: calendar)
            .first { $0.day == calendar.startOfDay(for: day) } ?? DayEnergy(day: calendar.startOfDay(for: day))
    }

    private static func query(url: URL, readOnly: Bool, since: Date) -> (intervals: [CoalitionInterval], states: [PowerState])? {
        var db: OpaquePointer?
        // The live database belongs to root (WAL); open it read-only, the archive is our own copy.
        let uri = "file:\(url.path)?\(readOnly ? "mode=ro" : "immutable=1")"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 200)

        var intervals: [CoalitionInterval] = []
        let ok = each(db, """
            SELECT timestamp, timestampEnd, BundleId, LaunchdName, energy FROM PLCoalitionAgent_EventInterval_CoalitionInterval
            WHERE timestampEnd >= ? AND energy > 0
            """, since: since) { s in
            guard let key = AppEnergyLedger.key(bundleId: text(s, 2), launchdName: text(s, 3)) else { return }
            intervals.append(CoalitionInterval(
                start: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                end: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                key: key, joules: sqlite3_column_double(s, 4) / 1e9))
        }
        guard ok else { return nil }

        // One state before the range is enough as a starting point.
        var states: [PowerState] = []
        _ = each(db, """
            SELECT timestamp, ExternalConnected FROM PLBatteryAgent_EventBackward_Battery
            WHERE timestamp >= ? ORDER BY timestamp
            """, since: since.addingTimeInterval(-3600)) { s in
            states.append(PowerState(t: Date(timeIntervalSince1970: sqlite3_column_double(s, 0)),
                                     plugged: sqlite3_column_int(s, 1) != 0))
        }
        return (intervals, states)
    }

    private static func each(_ db: OpaquePointer?, _ sql: String, since: Date, row: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private static func text(_ s: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(s, column).map { String(cString: $0) }
    }
}
