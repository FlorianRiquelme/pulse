import Foundation
import Testing
@testable import PulseCore

private func line(_ stamp: String, _ domain: String, _ message: String) -> String {
    "2026-10-07 \(stamp) +0200 \(domain.padding(toLength: 20, withPad: " ", startingAt: 0))\t\(message)"
}

private func date(_ stamp: String) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return f.date(from: "2026-10-07 \(stamp) +0200")!
}

/// Excerpt from `pmset -g log` (shortened): clamshell sleep, two timers, wake by opening the lid.
private let night = [
    "PM ASL data store: /var/log/powermanagement",
    line("12:20:00", "Assertions", "PID 1(launchd) Created ..."),
    line("12:29:03", "Sleep", "Entering Sleep state due to 'Clamshell Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 597 secs"),
    line("12:29:05", "Wake Requests", "[process=dasd request=SleepService deltaSecs=1071] [*process=powerd request=UserWake deltaSecs=594]"),
    line("12:39:00", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:100%) 7 secs"),
    line("12:39:07", "Sleep", "Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using Batt (Charge:100%) 1028 secs"),
    line("12:39:09", "Wake Requests", "[*process=dasd request=SleepService deltaSecs=1025] [process=mDNSResponder request=Maintenance]"),
    line("12:56:15", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to NUB.SPMI0.SW3 nub-spmi0.0x02 rtc/SleepService Using BATT (Charge:99%) 2 secs"),
    line("12:56:17", "Sleep", "Entering Sleep state due to 'Sleep Service Back to Sleep':TCPKeepAlive=active Using Batt (Charge:99%) 310 secs"),
    line("13:01:27", "Wake", "Wake from Deep Idle [CDNVA] : due to smc.sysState.Wake(0x70070000) lid SMC.OutboxNotEmpty RTP.multi-touch/HID Activity Using BATT (Charge:98%)"),
    line("13:05:00", "Sleep", "Entering Sleep state due to 'Idle Sleep':TCPKeepAlive=active Using Batt (Charge:98%) 100 secs"),
    // Power adapter plugged in: briefly fully awake (notification), keeps sleeping, then really awake.
    line("14:34:49", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) USB-C_plug nub-spmi-a0.0x3F/ Using BATT (Charge:62%) 0 secs"),
    line("14:34:49", "Wake", "DarkWake to FullWake from Deep Idle [CDNVAP] : due to Notification Using AC (Charge:62%) 3 secs"),
    line("14:34:52", "Sleep", "Entering DarkWake state due to 'Notification Wake Back to Sleep':TCPKeepAlive=active Using AC (Charge:62%)"),
    line("14:35:11", "Sleep", "Entering Sleep state due to 'Notification Wake Back to Sleep':TCPKeepAlive=active Using AC (Charge:62%) 596 secs"),
    line("14:45:07", "DarkWake", "DarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake(0x70070000) USB-C_plug nub-spmi-a0.0x25/ Using AC (Charge:62%) 5 secs"),
    line("14:45:12", "Wake", "DarkWake to FullWake from Deep Idle [CDNVA] : due to UserActivity Assertion Using AC (Charge:67%)"),
].joined(separator: "\n")

@Suite struct PowerLogTests {
    @Test func parsesSleepPeriodsWithDarkWakes() {
        let sleeps = PowerLog.sleeps(in: night)
        #expect(sleeps.count == 2)
        let first = sleeps[0]
        #expect(first.start == date("12:29:03"))
        #expect(first.end == date("13:01:27"))
        #expect(first.startPercent == 100)
        #expect(first.endPercent == 98)
        #expect(first.plugged == false)
        #expect(first.darkWakes == 2)
        #expect(first.wakers == ["powerd": 1, "dasd": 1])
    }

    @Test func shortFullWakeStaysInSameSleepAndPlugIsNoted() {
        let second = PowerLog.sleeps(in: night)[1]
        #expect(second.start == date("13:05:00"))
        #expect(second.end == date("14:45:12"))
        // Plugging in briefly wakes it fully (counts once); the last DarkWake turned into the wakeup.
        #expect(second.darkWakes == 1)
        #expect(second.plugged)
        #expect(second.drop == nil)
    }

    @Test func sinceSkipsOlderPeriods() {
        let sleeps = PowerLog.sleeps(in: night, since: date("13:00:00"))
        #expect(sleeps.map(\.start) == [date("13:05:00")])
    }

    @Test func detailsMatchLiveWindow() {
        let d = PowerLog.details(in: night, start: date("12:29:01"), end: date("13:01:28"))
        #expect(d?.darkWakes == 2)
        #expect(PowerLog.details(in: night, start: date("16:00:00"), end: date("17:00:00")) == nil)
    }
}

@Suite struct SleepLogTests {
    private func record(_ startHour: Double, _ hours: Double, _ from: Double, _ to: Double) -> SleepRecord {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        return SleepRecord(start: base.addingTimeInterval(startHour * 3600),
                           end: base.addingTimeInterval((startHour + hours) * 3600),
                           startPercent: from, endPercent: to, plugged: false)
    }

    @Test func ratePerHour() {
        let r = record(0, 8, 82, 80)
        #expect(r.drop == 2)
        #expect(r.percentPerHour == 0.25)
        #expect(record(0, 0.2, 82, 81).percentPerHour == nil) // too short
    }

    @Test func persistsMergesAndUpdates() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sleeps.jsonl")
        let log = SleepLog(url: url)
        #expect(!log.existed)
        log.add(record(0, 2, 90, 89))
        let merged = log.add(record(2.01, 3, 89, 87))           // 36 s awake in between
        #expect(log.records.count == 1)
        #expect(merged.startPercent == 90 && merged.endPercent == 87)
        log.add(record(10, 1, 70, 70))
        var details = merged
        details.darkWakes = 12
        details.wakers = ["dasd": 12]
        log.update(start: merged.start, with: details)

        let reloaded = SleepLog(url: url)
        #expect(reloaded.existed)
        #expect(reloaded.records.count == 2)
        #expect(reloaded.records[0].darkWakes == 12)
        #expect(reloaded.records[0].topWakers.first?.name == "dasd")
    }

    @Test func typicalNeedsThreeSleeps() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = SleepLog(url: dir.appendingPathComponent("s.jsonl"))
        log.replace(with: [record(0, 8, 80, 78), record(24, 8, 80, 76)])
        #expect(log.typicalPercentPerHour == nil)
        log.replace(with: [record(0, 8, 80, 78), record(24, 8, 80, 76), record(48, 4, 80, 79)])
        #expect(log.typicalPercentPerHour == 0.25)
    }
}
