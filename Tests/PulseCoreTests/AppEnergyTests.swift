import Foundation
import Testing
@testable import PulseCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func interval(_ startMin: Double, _ endMin: Double, _ key: String, wh: Double) -> CoalitionInterval {
    CoalitionInterval(start: t0.addingTimeInterval(startMin * 60), end: t0.addingTimeInterval(endMin * 60), key: key, joules: wh * 3600)
}

private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

@Suite struct AppEnergyTests {
    @Test func keyPrefersAppFromLaunchdName() {
        #expect(AppEnergyLedger.key(bundleId: "com.microsoft.fresno",
                                    launchdName: "application.com.microsoft.Outlook.586141.586147") == "com.microsoft.Outlook")
        #expect(AppEnergyLedger.key(bundleId: "com.raycast.macos", launchdName: "com.raycast.agent") == "com.raycast.macos")
        #expect(AppEnergyLedger.key(bundleId: "", launchdName: "com.apple.WindowServer") == "com.apple.WindowServer")
        #expect(AppEnergyLedger.key(bundleId: nil,
                                    launchdName: "com.apple.mdworker.shared.07000000-0200-0000-0000-000000000000") == "com.apple.mdworker.shared")
        #expect(AppEnergyLedger.key(bundleId: nil, launchdName: "") == nil)
    }

    @Test func daysSplitTotalAndBattery() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let states = [PowerState(t: t0, plugged: true), PowerState(t: t0.addingTimeInterval(600), plugged: false)]
        let rows = [
            interval(0, 5, "teams", wh: 1),     // on power adapter
            interval(10, 15, "teams", wh: 2),   // on battery
            interval(10, 15, "zen", wh: 0.5),
            interval(24 * 60, 24 * 60 + 5, "zen", wh: 1), // next day
        ]
        let days = AppEnergyLedger.days(rows, states: states, calendar: calendar)
        #expect(days.count == 2)
        #expect(close(days[0].total["teams"], 3))
        #expect(close(days[0].battery["teams"], 2))
        #expect(close(days[1].battery["zen"], 1))
        #expect(days[0].day < days[1].day)
    }

    @Test func withoutStatesNothingCountsAsBattery() {
        let days = AppEnergyLedger.days([interval(0, 5, "a", wh: 1)], states: [])
        #expect(days.first?.battery.isEmpty == true)
        #expect(close(days.first?.total["a"], 1))
    }

    @Test func pluggedUsesStateBeforeOrFirst() {
        let states = [PowerState(t: t0.addingTimeInterval(60), plugged: false), PowerState(t: t0.addingTimeInterval(120), plugged: true)]
        #expect(AppEnergyLedger.plugged(at: t0, states: states) == false)
        #expect(AppEnergyLedger.plugged(at: t0.addingTimeInterval(90), states: states) == false)
        #expect(AppEnergyLedger.plugged(at: t0.addingTimeInterval(500), states: states) == true)
    }

    @Test func recentPowerCountsOverlapProportionally() {
        let rows = [
            interval(0, 30, "a", wh: 1),   // half inside the window (30–90)
            interval(30, 90, "a", wh: 1),
            interval(60, 90, "b", wh: 0.5),
        ]
        let w = AppEnergyLedger.recentPower(rows, window: 3600)
        #expect(close(w["a"], 1))    // 1 Wh in 60 min
        #expect(close(w["b"], 0.5))
    }

    @Test func recentPowerNeedsData() {
        #expect(AppEnergyLedger.recentPower([]).isEmpty)
        #expect(AppEnergyLedger.recentPower([interval(0, 2, "a", wh: 1)]).isEmpty)
    }

    @Test func rankingSumsDays() {
        let days = [DayEnergy(day: t0, total: ["a": 1, "b": 3]), DayEnergy(day: t0.addingTimeInterval(86400), total: ["a": 4])]
        let r = AppEnergyLedger.ranking(days, batteryOnly: false)
        #expect(r.map(\.key) == ["a", "b"])
        #expect(r.first?.wh == 5)
        #expect(AppEnergyLedger.ranking(days, batteryOnly: true).isEmpty)
    }

    @Test func whatIfGain() {
        // 30 Wh at 6 W = 5 h; without a 1 W app 30/5 = 6 h → +1 h
        #expect(close(BatteryEstimator.whatIf(remainingWh: 30, systemPowerW: 6, appPowerW: 1), 3600))
        #expect(BatteryEstimator.whatIf(remainingWh: 30, systemPowerW: 6, appPowerW: 0) == nil)
        #expect(BatteryEstimator.whatIf(remainingWh: 30, systemPowerW: 6, appPowerW: 6) == nil)
        #expect(BatteryEstimator.whatIf(remainingWh: 30, systemPowerW: 0.2, appPowerW: 0.1) == nil)
    }
}
