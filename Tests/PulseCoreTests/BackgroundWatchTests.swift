import Foundation
import Testing
@testable import PulseCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// Plays back `minutes` minutes at a 15 s interval and returns the last list.
private func run(_ watch: inout BackgroundWatch, from start: TimeInterval = 0, minutes: Double,
                 _ input: (Date) -> [BackgroundWatch.Input]) -> [BackgroundWatch.Entry] {
    var entries: [BackgroundWatch.Entry] = []
    var t = start
    while t <= start + minutes * 60 {
        let date = t0.addingTimeInterval(t)
        entries = watch.update(input(date), at: date)
        t += 15
    }
    return entries
}

@Suite struct BackgroundWatchTests {
    @Test func flagsSteadyBackgroundLoadAfterTenMinutes() {
        var watch = BackgroundWatch()
        let early = run(&watch, minutes: 9) { _ in [.init(id: 1, cpu: 0.15)] }
        #expect(early.isEmpty)
        let late = run(&watch, from: 9 * 60 + 15, minutes: 2) { _ in [.init(id: 1, cpu: 0.15)] }
        #expect(late.map(\.id) == [1])
        #expect(late.first.map { abs($0.cpu - 0.15) < 1e-9 } == true)
        #expect(late.first?.since == t0)
    }

    @Test func ignoresShortBurstsAndLightLoad() {
        var watch = BackgroundWatch()
        let entries = run(&watch, minutes: 30) { date in
            let burst = date.timeIntervalSince(t0) < 120
            return [.init(id: 1, cpu: burst ? 1.0 : 0.01), .init(id: 2, cpu: 0.03)]
        }
        #expect(entries.isEmpty)
    }

    @Test func hidesFrontmostApp() {
        var watch = BackgroundWatch()
        let entries = run(&watch, minutes: 20) { _ in [.init(id: 1, cpu: 0.5, frontmost: true)] }
        #expect(entries.isEmpty)
    }

    @Test func seedsFromLifetimeAverage() {
        var watch = BackgroundWatch()
        let started = t0.addingTimeInterval(-17 * 3600)
        // 1 h 25 min of CPU time in 15 h awake ≈ 9.4 %
        let input = BackgroundWatch.Input(id: 7, cpu: 0.15, cpuTime: 85 * 60, awake: 15 * 3600, started: started)
        let entries = watch.update([input], at: t0)
        #expect(entries.map(\.id) == [7])
        #expect(entries.first?.since == started)
    }

    @Test func ignoresStartupBurstOfYoungApps() {
        var watch = BackgroundWatch()
        // 4 min of CPU time in the first 14 min, mostly at launch
        let input = BackgroundWatch.Input(id: 8, cpu: 0.02, cpuTime: 4 * 60, awake: 14 * 60)
        #expect(watch.update([input], at: t0).isEmpty)
    }

    @Test func flagsFrequentWakeups() {
        var watch = BackgroundWatch()
        let entries = run(&watch, minutes: 11) { _ in [.init(id: 3, cpu: 0.001, wakeups: 287)] }
        #expect(entries.map(\.id) == [3])
    }

    @Test func calmingDownResetsSince() {
        var watch = BackgroundWatch()
        _ = run(&watch, minutes: 15) { _ in [.init(id: 1, cpu: 0.2)] }
        let quiet = run(&watch, from: 15 * 60 + 15, minutes: 30) { _ in [.init(id: 1, cpu: 0)] }
        #expect(quiet.isEmpty)
        let again = run(&watch, from: 45 * 60 + 15, minutes: 5) { _ in [.init(id: 1, cpu: 0.5)] }
        #expect(again.isEmpty) // only again after 10 min
    }

    @Test func skipsGapsFromSleep() {
        var watch = BackgroundWatch()
        _ = run(&watch, minutes: 15) { _ in [.init(id: 1, cpu: 0.2)] }
        // After 8 h of sleep the first reading is almost zero; it must not count.
        let wake = t0.addingTimeInterval(8 * 3600)
        let entries = watch.update([.init(id: 1, cpu: 0.001)], at: wake)
        #expect(entries.map(\.id) == [1])
    }

    @Test func forgetsQuitApps() {
        var watch = BackgroundWatch()
        _ = run(&watch, minutes: 15) { _ in [.init(id: 1, cpu: 0.2)] }
        watch.forget(1)
        let entries = watch.update([.init(id: 1, cpu: 0.2)], at: t0.addingTimeInterval(15 * 60 + 15))
        #expect(entries.isEmpty)
    }

    @Test func sinceFormat() {
        #expect(Fmt.since(12 * 60) == "12 min")
        #expect(Fmt.since(17.5 * 3600) == "17 h")
        #expect(Fmt.since(3 * 86400) == "3 days")
    }
}
