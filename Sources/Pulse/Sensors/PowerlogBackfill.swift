import Foundation
import PulseCore

/// Battery history for minutes when Pulse was not running: from the macOS powerlog, otherwise from `pmset -g log`.
enum PowerlogBackfill {
    /// - Parameter archives: Also read the compressed daily archives (only at launch; after waking up
    ///   the live database is enough, the archives do not change).
    static func load(since: Date, archives: Bool) -> [MinuteSample] {
        guard let current = Powerlog.batteryRows(at: Powerlog.current, since: since) else {
            // Powerlog not readable: pmset costs about 1 s of CPU, so only at launch.
            return archives ? pmsetSamples(since: since) : []
        }
        var rows = current
        // Always take display events from all sources: a state holds until the next event.
        var backlight = Powerlog.backlightEvents(at: Powerlog.current) ?? []
        if archives {
            let dayBefore = since.addingTimeInterval(-24 * 3600)
            for url in Powerlog.archives where archiveDate(url).map({ $0 >= dayBefore }) ?? true {
                let archive = unpacked(url)
                rows += archive?.rows ?? []
                backlight += archive?.backlight ?? []
            }
        }
        return Powerlog.samples(from: rows.filter { $0.t >= since }, backlight: backlight)
    }

    /// `powerlog_2026-10-02_628A5FE9.PLSQL.gz` → 2026-10-02
    private static func archiveDate(_ url: URL) -> Date? {
        let parts = url.lastPathComponent.split(separator: "_")
        guard parts.count >= 2 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(parts[1]))
    }

    /// Unpacks an archive into a temporary file and reads it as immutable (`immutable=1`).
    private static func unpacked(_ url: URL) -> (rows: [Powerlog.Row], backlight: [(t: Date, on: Bool)])? {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("pulse-\(UUID().uuidString).PLSQL")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: tmp) else { return nil }
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-dc", url.path]
        gzip.standardOutput = out
        gzip.standardError = FileHandle.nullDevice
        do { try gzip.run() } catch { return nil }
        gzip.waitUntilExit()
        try? out.close()
        guard gzip.terminationStatus == 0 else { return nil }
        guard let rows = Powerlog.batteryRows(at: tmp, immutable: true) else { return nil }
        return (rows, Powerlog.backlightEvents(at: tmp, immutable: true) ?? [])
    }

    private static func pmsetSamples(since: Date) -> [MinuteSample] {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["-g", "log"]
        let pipe = Pipe()
        pmset.standardOutput = pipe
        pmset.standardError = FileHandle.nullDevice
        do { try pmset.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        pmset.waitUntilExit()
        return Powerlog.samples(fromPmsetLog: String(decoding: data, as: UTF8.self)).filter { $0.t >= since }
    }
}
