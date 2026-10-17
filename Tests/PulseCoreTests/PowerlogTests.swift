import Foundation
import SQLite3
import Testing
@testable import PulseCore

private let t0 = Date(timeIntervalSince1970: 1_791_300_000) // 2026-10-06 17:20 CEST

/// Builds a small database with the same table as the powerlog (columns as on macOS 27).
private func makeFixture(rows: [(t: Double, level: Double?, amps: Int, mV: Int, ext: Int, chg: Int)], wal: Bool) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("Fixture Powerlog.PLSQL") // space: the URI must be encoded
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    var sql = wal ? "PRAGMA journal_mode=WAL;" : ""
    sql += """
        CREATE TABLE 'PLBatteryAgent_EventBackward_Battery' ('ID' INTEGER PRIMARY KEY AUTOINCREMENT, 'timestamp' REAL,
          'Level' REAL, 'Voltage' INTEGER, 'InstantAmperage' INTEGER, 'IsCharging' INTEGER, 'ExternalConnected' INTEGER,
          'Temperature' REAL, 'CellVoltage0' INTEGER);
        CREATE TABLE 'PLDisplayAgent_EventPoint_Display' ('ID' INTEGER PRIMARY KEY AUTOINCREMENT, 'timestamp' REAL,
          'Block' TEXT, 'Active' INTEGER);
        INSERT INTO PLDisplayAgent_EventPoint_Display (timestamp, Block, Active) VALUES (\(t0.timeIntervalSince1970 + 90), 'Backlight', 0);
        """
    for r in rows {
        sql += "INSERT INTO PLBatteryAgent_EventBackward_Battery (timestamp, Level, Voltage, InstantAmperage, IsCharging, ExternalConnected) "
        sql += "VALUES (\(t0.timeIntervalSince1970 + r.t), \(r.level.map { "\($0)" } ?? "NULL"), \(r.mV), \(r.amps), \(r.chg), \(r.ext));"
    }
    #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    return url
}

@Suite struct PowerlogTests {
    @Test func readsBatteryRowsReadOnly() throws {
        let url = try makeFixture(rows: [
            (0, 89, -465, 12676, 0, 0),
            (60, 88, -500, 12600, 0, 0),
            (120, nil, -500, 12600, 0, 0), // no level: skipped
            (180, 88, 1200, 12900, 1, 1),
        ], wal: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let rows = try #require(Powerlog.batteryRows(at: url))
        #expect(rows.count == 3)
        #expect(rows[0].level == 89)
        #expect(abs(rows[0].batteryW - 5.894) < 0.001)
        #expect(rows[2].external && rows[2].charging)
        #expect(rows[2].batteryW < 0)

        let since = Powerlog.batteryRows(at: url, since: t0.addingTimeInterval(30))
        #expect(since?.count == 2)

        let backlight = try #require(Powerlog.backlightEvents(at: url))
        #expect(backlight.count == 1)
        #expect(backlight.first?.on == false)
    }

    @Test func readsCopiedArchiveImmutable() throws {
        let url = try makeFixture(rows: [(0, 50, -800, 12000, 0, 0)], wal: false)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let copy = url.deletingLastPathComponent().appendingPathComponent("archive.PLSQL")
        try FileManager.default.copyItem(at: url, to: copy)
        #expect(Powerlog.batteryRows(at: copy, immutable: true)?.count == 1)
    }

    @Test func failsSoftWithoutTableOrFile() throws {
        #expect(Powerlog.batteryRows(at: URL(fileURLWithPath: "/nonexistent/x.PLSQL")) == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("empty.PLSQL")
        try Data("not sqlite".utf8).write(to: url)
        #expect(Powerlog.batteryRows(at: url) == nil)
    }

    @Test func groupsRowsIntoMinutes() {
        let base = MinuteAccumulator.minuteStart(t0)
        let rows = [
            Powerlog.Row(t: base.addingTimeInterval(5), level: 80, amperage: -400, voltage: 12500, external: false, charging: false),
            Powerlog.Row(t: base.addingTimeInterval(40), level: 79, amperage: -800, voltage: 12500, external: false, charging: false),
            Powerlog.Row(t: base.addingTimeInterval(70), level: 79, amperage: -400, voltage: 12500, external: false, charging: false),
        ]
        let samples = Powerlog.samples(from: rows)
        #expect(samples.count == 2)
        #expect(samples[0].t == base)
        #expect(samples[0].battery == 79)
        #expect(abs((samples[0].batteryW ?? 0) - 7.5) < 0.0001)
        #expect(samples[0].isImported)
        #expect(samples[0].isDischarging)
    }

    @Test func screenOffMinutesKeepLevelButNoPower() {
        let base = MinuteAccumulator.minuteStart(t0)
        let rows = (0..<4).map {
            Powerlog.Row(t: base.addingTimeInterval(Double($0) * 60 + 10), level: 70, amperage: -300, voltage: 12000,
                         external: false, charging: false)
        }
        // Display off after minute 1, back on in minute 3
        let samples = Powerlog.samples(from: rows, backlight: [(base.addingTimeInterval(65), false),
                                                               (base.addingTimeInterval(185), true)])
        #expect(samples.map { $0.batteryW != nil } == [true, false, false, true])
        #expect(samples.allSatisfy { $0.battery == 70 })
        #expect(!samples[1].isDischarging)
    }

    @Test func parsesPmsetLog() {
        let text = """
            2026-10-05 05:56:12 +0200 Assertions          \tSummary- [System: PrevIdle DeclUser kDisp] Using Batt(Charge: 12)
            2026-10-05 05:56:40 +0200 Assertions          \tSummary- [System: DeclUser] Using Batt(Charge: 11)
            2026-10-07 18:53:16 +0200 Sleep               \tEntering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using AC (Charge:100%) 734 secs
            2026-10-07 18:54:00 +0200 Kernel Client Acks  \t| Delays to Sleep notifications: [com.apple.x]
            """
        let samples = Powerlog.samples(fromPmsetLog: text)
        #expect(samples.count == 2)
        #expect(samples[0].battery == 11) // last value of the minute
        #expect(samples[0].plugged == false)
        #expect(samples[0].batteryW == nil)
        #expect(samples[1].battery == 100)
        #expect(samples[1].plugged)
        #expect(samples[1].t == Date(timeIntervalSince1970: 1_791_391_980)) // 16:53 UTC, seconds truncated
    }

    @Test func mergeFillsOnlyMissingMinutes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.jsonl")
        let now = MinuteAccumulator.minuteStart(.now)
        func sample(_ minutesAgo: Int, imported: Bool) -> MinuteSample {
            MinuteSample(t: now.addingTimeInterval(Double(-minutesAgo) * 60), battery: imported ? 1 : 50, plugged: false,
                         charging: false, batteryW: 5, systemW: nil, cpu: 0.2, gpu: nil, mem: 0.5, socTemp: nil,
                         imported: imported ? true : nil)
        }
        let log = MinuteLog(url: url)
        log.append(sample(10, imported: false))
        log.append(sample(5, imported: false))

        let backfill = [sample(12, imported: true), sample(10, imported: true), sample(7, imported: true),
                        sample(1, imported: true), // latest minute: recorded live, do not backfill
                        sample(Int(MinuteLog.retention / 60) + 10, imported: true)] // too old
        #expect(log.merge(backfill, before: now.addingTimeInterval(-60)) == 2)
        #expect(log.samples.map(\.t) == [12, 10, 7, 5].map { now.addingTimeInterval(Double(-$0) * 60) })
        #expect(log.samples[1].battery == 50) // own entry stays
        #expect(log.merge(backfill, before: now.addingTimeInterval(-60)) == 0)

        let reloaded = MinuteLog(url: url)
        #expect(reloaded.samples.count == 4)
        #expect(reloaded.samples.first?.isImported == true)
        #expect(reloaded.samples.last?.isImported == false)
    }
}
