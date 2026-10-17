import Foundation
import Testing
@testable import PulseCore

private let berlin: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Europe/Berlin")!
    return c
}()

/// Wednesday, October 7, 2026, hh:mm in Berlin.
private func at(_ h: Int, _ m: Int = 0, day: Int = 7) -> Date {
    berlin.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m))!
}

private let rules = WorkRules(weeklyTargetMinutes: 2310) // 7:42 h per day

@Suite struct WorkdayTests {
    @Test func decodesStempeluhrLedger() throws {
        let json = """
        {"blocks":[{"id":"A","start":"2026-10-07T04:05:00Z","end":"2026-10-07T05:58:00Z","endedByPause":false,
                    "manual":true,"typed":false},
                   {"id":"B","start":"2026-10-07T11:01:00Z","endedByPause":false,"manual":false,"typed":false}],
         "days":{"2026-10-06":{"officeDetected":false,"submitted":true,"frozenPlan":{"bookedNet":31020}}},
         "paused":false}
        """
        let ledger = try WorkLedger.decode(Data(json.utf8))
        #expect(ledger.blocks.count == 2)
        #expect(ledger.blocks[1].end == nil)
        #expect(ledger.days["2026-10-06"]?.submitted == true)
        #expect(!ledger.paused)
    }

    @Test func dailyTargetSpreadsWeeklyHours() {
        #expect(rules.dailyTarget == (7 * 60 + 42) * 60)
        #expect(WorkRules(weeklyTargetMinutes: 2400, workdays: [2, 3, 4, 5]).dailyTarget == 10 * 3600)
        #expect(WorkRules.weekdays("2, 3,4,x") == [2, 3, 4])
    }

    @Test func summaryMatchesStempelCore() {
        // 8:00–12:00, 12:10–12:40 (10 min do not count), 13:00–15:00 (20 min count)
        let s = WorkSummary(ranges: [(at(8), at(12)), (at(12, 10), at(12, 40)), (at(13), at(15))], minBreakGap: 15 * 60)
        #expect(s.gross == 6.5 * 3600)
        #expect(s.gaps == 20 * 60)
        #expect(s.net == 6.5 * 3600 - 10 * 60) // 30 min required, 20 already taken
    }

    @Test func runningDayAddsMissingBreak() {
        // Continuously since 8:00: 7:42 net + 30 min break → 16:12
        let ledger = WorkLedger(blocks: [.init(start: at(8))])
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(10), calendar: berlin) == at(16, 12))
        // The time does not depend on when you ask.
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(15), calendar: berlin) == at(16, 12))
    }

    @Test func breakAlreadyTakenIsNotAddedAgain() {
        let ledger = WorkLedger(blocks: [.init(start: at(8), end: at(12)), .init(start: at(12, 45))])
        // A 45 min gap covers the required 30 min: 8:00 + 7:42 + 0:45
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(13), calendar: berlin) == at(16, 27))
    }

    @Test func shortGapsDoNotCountAsBreak() {
        let ledger = WorkLedger(blocks: [.init(start: at(8), end: at(10)), .init(start: at(10, 10))])
        // A 10 min gap is not a break: 7:42 + 30 min required, from 10:10 another 6:12 − 2:00 gross to go
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(11), calendar: berlin) == at(16, 22))
    }

    @Test func gapUntilNowCountsWhenNoBlockIsRunning() {
        // Stempeluhr has no new block yet: work continues from now, the gap is a break.
        let ledger = WorkLedger(blocks: [.init(start: at(8), end: at(12))])
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(13), calendar: berlin) == at(16, 42))
    }

    @Test func longDayNeedsFortyFiveMinutes() {
        let long = WorkRules(weeklyTargetMinutes: 5 * (8 * 60 + 50))
        let ledger = WorkLedger(blocks: [.init(start: at(7))])
        // 8:50 net needs more than 9 h of presence → 45 min break → 16:35
        #expect(Workday.endOfDay(ledger: ledger, rules: long, now: at(9), calendar: berlin) == at(16, 35))
    }

    @Test func kontoDrawShortensTheDay() {
        let ledger = WorkLedger(blocks: [.init(start: at(8))], days: ["2026-10-07": .init(kontoDraw: 102)])
        // 6:00 net: no required break (only above 6 h)
        #expect(Workday.endOfDay(ledger: ledger, rules: rules, now: at(9), calendar: berlin) == at(14))
    }

    @Test func noEndOfDayWhenNothingIsDue() {
        let running = [WorkLedger.Block(start: at(8))]
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: running, paused: true), rules: rules, now: at(10), calendar: berlin) == nil)
        #expect(Workday.endOfDay(ledger: WorkLedger(), rules: rules, now: at(10), calendar: berlin) == nil)
        // Yesterday's blocks do not count
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: [.init(start: at(8, day: 6))]), rules: rules, now: at(10), calendar: berlin) == nil)
        // Saturday
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: [.init(start: at(8, day: 10))]), rules: rules,
                                 now: at(10, day: 10), calendar: berlin) == nil)
        // Target already reached
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: running), rules: rules, now: at(17), calendar: berlin) == nil)
        // Submitted
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: running, days: ["2026-10-07": .init(submitted: true)]),
                                 rules: rules, now: at(10), calendar: berlin) == nil)
        // Would only end after midnight
        #expect(Workday.endOfDay(ledger: WorkLedger(blocks: [.init(start: at(20))]), rules: rules, now: at(21), calendar: berlin) == nil)
    }

    @Test func runwayFits() {
        let r = WorkdayRunway(endOfDay: at(16), remaining: 7 * 3600, typical: 5 * 3600, powerW: 6, chargePowerW: 30, now: at(10))
        #expect(r.fits)
        #expect(r.batteryEnd == at(17))
        #expect(r.typicalEnd == at(15))
        #expect(r.chargeNeeded == nil)
    }

    @Test func runwayShortfallTellsHowLongToCharge() {
        // 2 h missing at 6 W = 12 Wh; charged at 30 W that is 24 min → 25 min
        let r = WorkdayRunway(endOfDay: at(16), remaining: 4 * 3600, typical: nil, powerW: 6, chargePowerW: 30, now: at(10))
        #expect(!r.fits)
        #expect(r.chargeNeeded == 25 * 60.0)
        let unknown = WorkdayRunway(endOfDay: at(16), remaining: 4 * 3600, typical: nil, powerW: 6, chargePowerW: nil, now: at(10))
        #expect(unknown.chargeNeeded == nil)
    }

    @Test func typicalChargePowerIgnoresDischarge() {
        let t = Date(timeIntervalSinceReferenceDate: 0)
        let log = [-30.0, -20, -40, 6].enumerated().map { i, w in
            MinuteSample(t: t.addingTimeInterval(Double(i) * 60), battery: 50, plugged: w < 0, charging: w < 0,
                         batteryW: w, systemW: nil, cpu: 0, gpu: nil, mem: 0, socTemp: nil)
        }
        #expect(BatteryEstimator.typicalChargePower(log: log) == 30)
        #expect(BatteryEstimator.typicalChargePower(log: []) == nil)
    }
}
