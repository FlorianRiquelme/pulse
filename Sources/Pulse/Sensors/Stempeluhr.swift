import Foundation
import PulseCore

/// Reads Stempeluhr's time tracking (read-only) and reports changes without polling:
/// Stempeluhr saves atomically, so the folder is watched, not the file.
@MainActor
final class StempeluhrSource {
    private static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Stempeluhr", isDirectory: true)
    private static let ledgerURL = folder.appendingPathComponent("ledger.json")

    private(set) var ledger: WorkLedger?
    private(set) var rules = WorkRules()
    var onChange: (() -> Void)?

    private var source: DispatchSourceFileSystemObject?

    /// Reload and watch the folder in case Stempeluhr has been installed in the meantime.
    func reload() {
        let data = try? Data(contentsOf: Self.ledgerURL)
        let ledger = data.flatMap { try? WorkLedger.decode($0) }
        let rules = Self.readRules()
        if ledger != self.ledger || rules != self.rules {
            self.ledger = ledger
            self.rules = rules
            onChange?()
        }
        if source == nil { watch() }
    }

    private func watch() {
        let fd = open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Folder deleted or moved: register again on the next reload.
                if let event = self.source?.data, !event.isDisjoint(with: [.delete, .rename]) {
                    self.source?.cancel()
                    self.source = nil
                }
                self.reload()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    private static func readRules() -> WorkRules {
        guard let defaults = UserDefaults(suiteName: "de.riquelme.stempeluhr") else { return WorkRules() }
        func int(_ key: String) -> Int? { (defaults.object(forKey: key) as? NSNumber)?.intValue }
        // Defaults as in Stempeluhr (registered there, not saved).
        let weekly = int("weeklyTargetMinutes") ?? (int("targetMinutes") ?? 480) * 5
        let days = defaults.string(forKey: "bookingDays").map(WorkRules.weekdays) ?? [2, 3, 4, 5, 6]
        let gap = int("minBreakGapMinutes") ?? 15
        return WorkRules(weeklyTargetMinutes: weekly, workdays: days, minBreakGap: TimeInterval(gap * 60))
    }
}
