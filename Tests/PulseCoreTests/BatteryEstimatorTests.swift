import Foundation
import Testing
@testable import PulseCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func minute(_ i: Int, battery: Double = 80, plugged: Bool = false, watts: Double? = 6) -> MinuteSample {
    MinuteSample(t: t0.addingTimeInterval(Double(i) * 60), battery: battery, plugged: plugged, charging: false,
                 batteryW: watts, systemW: nil, cpu: 0.1, gpu: nil, mem: 0.5, socTemp: 40)
}

private func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }

@Suite struct BatteryEstimatorTests {
    @Test func nowEstimateUsesInstantPower() {
        let e = BatteryEstimator.estimate(remainingWh: 30, fullWh: 50, nowPowerW: 10, log: [], now: t0)
        #expect(close(e.now, 3 * 3600))
        #expect(e.recent == nil)
        #expect(close(e.best, 3 * 3600))
    }

    @Test func ignoresTinyPower() {
        let e = BatteryEstimator.estimate(remainingWh: 30, fullWh: 50, nowPowerW: 0.1, log: [], now: t0)
        #expect(e.now == nil)
    }

    @Test func recentAveragesOnlyDischargingMinutesInWindow() {
        var log = (0..<20).map { minute($0, plugged: true, watts: -20) }         // charging, does not count
        log += (20..<30).map { minute($0, watts: $0 % 2 == 0 ? 4 : 8) }           // avg 6 W
        let now = t0.addingTimeInterval(30 * 60)
        let e = BatteryEstimator.estimate(remainingWh: 30, fullWh: 50, nowPowerW: 12, log: log, now: now)
        #expect(e.recentMinutes == 10)
        #expect(e.recentPowerW == 6)
        #expect(close(e.recent, 5 * 3600))
        #expect(e.best == e.recent) // usage beats the instantaneous value
    }

    @Test func recentNeedsThreeMinutes() {
        let log = [minute(0), minute(1)]
        let e = BatteryEstimator.estimate(remainingWh: 30, fullWh: 50, nowPowerW: nil, log: log, now: t0.addingTimeInterval(120))
        #expect(e.recent == nil)
    }

    @Test func typicalUsesMedianOverDays() {
        var log = (0..<100).map { minute($0, watts: 5) }
        log += (100..<110).map { minute($0, watts: 40) } // outliers do not shift the median
        let e = BatteryEstimator.estimate(remainingWh: 25, fullWh: 50, nowPowerW: nil, log: log, now: t0.addingTimeInterval(110 * 60))
        #expect(e.typicalPowerW == 5)
        #expect(close(e.typical, 5 * 3600))
        #expect(close(e.fullChargeRuntime, 10 * 3600))
    }

    @Test func timeToFull() {
        #expect(BatteryEstimator.timeToFull(remainingWh: 20, fullWh: 50, chargePowerW: 30) == 3600)
        #expect(BatteryEstimator.timeToFull(remainingWh: 50, fullWh: 50, chargePowerW: 30) == nil)
    }

    @Test func lastSessionFindsMostRecentUnpluggedStretch() {
        var log = (0..<10).map { minute($0, battery: 100 - Double($0), watts: 6) }  // old stretch
        log += (10..<20).map { minute($0, battery: 95, plugged: true, watts: -10) }
        log += (20..<80).map { minute($0, battery: 100 - Double($0 - 20) * 0.2, watts: 6) }
        let s = BatteryEstimator.lastSession(in: log, pluggedNow: false)
        #expect(s?.start == t0.addingTimeInterval(20 * 60))
        #expect(s?.activeMinutes == 60)
        #expect(s?.ongoing == true)
        #expect(abs((s?.used ?? 0) - 11.8) < 0.001)
        #expect(abs((s?.percentPerHour ?? 0) - 11.8) < 0.001)
    }

    @Test func lastSessionEndsWhenPlugged() {
        var log = (0..<30).map { minute($0, battery: 90, watts: 6) }
        log += (30..<40).map { minute($0, plugged: true, watts: -10) }
        let s = BatteryEstimator.lastSession(in: log, pluggedNow: true)
        #expect(s?.ongoing == false)
        #expect(s?.activeMinutes == 30)
    }
}

@Suite struct RhythmForecastTests {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Monday, 2026-10-05, 00:00 UTC.
    private static let monday = Date(timeIntervalSince1970: 1_791_158_400)

    /// One week of battery minutes at the same time of day; `watts` per minute of the hour.
    private func week(hours: Range<Int>, days: Int = 7, watts: (Int, Int) -> Double) -> [MinuteSample] {
        var log: [MinuteSample] = []
        for day in 0..<days {
            for hour in hours {
                for m in 0..<60 {
                    let t = Self.monday.addingTimeInterval(Double(day * 86_400 + hour * 3600 + m * 60))
                    log.append(MinuteSample(t: t, battery: 50, plugged: false, charging: false, batteryW: watts(hour, m),
                                            systemW: nil, cpu: 0.1, gpu: nil, mem: 0.5, socTemp: nil))
                }
            }
        }
        return log
    }

    @Test func followsHourlyProfile() throws {
        // 10 W in the morning, 4 W in the afternoon
        let log = week(hours: 9..<18) { hour, _ in hour < 13 ? 10 : 4 }
        let now = Self.monday.addingTimeInterval(7 * 86_400 + 9 * 3600) // the following Monday, 9:00
        let profile = BatteryEstimator.profile(log: log, now: now, calendar: Self.utc)
        #expect(profile.buckets[9]?.median == 10)
        #expect(profile.buckets[15]?.median == 4)
        #expect(profile.buckets[9]?.count == 5 * 60)
        #expect(profile.buckets[9 + 24]?.count == 2 * 60) // weekend kept separate

        // 48 Wh: 40 Wh until 13:00, then 8 Wh at 4 W = 2 h → empty at 15:00
        let f = try #require(BatteryEstimator.rhythmForecast(remainingWh: 48, fullWh: 60, percent: 80, recentPowerW: nil,
                                                             profile: profile, now: now, calendar: Self.utc))
        #expect(f.byHour)
        #expect(abs((f.median ?? 0) - 6 * 3600) < 1)
        #expect(f.early == f.median && f.late == f.median) // no spread → no band
        // 20 % = 12 Wh: after 13:00, 8 Wh left above 12 → after 3.6 h
        #expect(abs((f.low ?? 0) - 3.6 * 3600) < 1)
        #expect(f.curve.first?.median == 80)
        #expect(f.curve.last?.median == 0)
    }

    @Test func bandFromQuartiles() throws {
        let log = week(hours: 0..<24) { _, m in Double(4 + m % 5) } // 4…8 W, median 6 W
        let now = Self.monday.addingTimeInterval(8 * 86_400)
        let profile = BatteryEstimator.profile(log: log, now: now, calendar: Self.utc)
        let f = try #require(BatteryEstimator.rhythmForecast(remainingWh: 30, fullWh: 60, percent: 50, recentPowerW: nil,
                                                             profile: profile, now: now, calendar: Self.utc))
        let early = try #require(f.early), median = try #require(f.median), late = try #require(f.late)
        #expect(early < median && median < late)
        #expect(abs(median - 5 * 3600) < 1)
        #expect(abs(early - 30 / 7 * 3600) < 1)
        #expect(abs(late - 30 / 5 * 3600) < 1)
        for p in f.curve { #expect(p.low <= p.median && p.median <= p.high) }
    }

    @Test func flatMedianWhenHoursAreThin() throws {
        // Only 20 minutes per hour on a single day: no hour reaches 30 minutes
        var log = week(hours: 8..<20, days: 1) { _, _ in 5 }.filter { MinuteAccumulator.minuteStart($0.t).timeIntervalSince1970.truncatingRemainder(dividingBy: 3600) < 1200 }
        log.sort { $0.t < $1.t }
        let now = Self.monday.addingTimeInterval(86_400)
        let profile = BatteryEstimator.profile(log: log, now: now, calendar: Self.utc)
        #expect(profile.flat?.median == 5)
        let f = try #require(BatteryEstimator.rhythmForecast(remainingWh: 20, fullWh: 60, percent: 33, recentPowerW: nil,
                                                             profile: profile, now: now, calendar: Self.utc))
        #expect(!f.byHour)
        #expect(abs((f.median ?? 0) - 4 * 3600) < 1)
    }

    @Test func noForecastWithoutData() {
        let profile = BatteryEstimator.profile(log: [], calendar: Self.utc)
        #expect(BatteryEstimator.rhythmForecast(remainingWh: 20, fullWh: 60, percent: 33, recentPowerW: 8,
                                                profile: profile, calendar: Self.utc) == nil)
    }

    @Test func recentUsageCountsInFirstHour() throws {
        let log = week(hours: 0..<24) { _, _ in 5 }
        let now = Self.monday.addingTimeInterval(8 * 86_400)
        let profile = BatteryEstimator.profile(log: log, now: now, calendar: Self.utc)
        func median(_ recent: Double?) throws -> TimeInterval {
            try #require(BatteryEstimator.rhythmForecast(remainingWh: 40, fullWh: 60, percent: 66, recentPowerW: recent,
                                                         profile: profile, now: now, calendar: Self.utc)?.median)
        }
        // First hour: on average (15 + 5) / 2 = 10 W → 10 Wh, then 30 Wh at 5 W = 6 h
        #expect(abs(try median(15) - 7 * 3600) < 60)
        #expect(abs(try median(nil) - 8 * 3600) < 1)
    }

    @Test func horizonLimitsForecast() throws {
        let log = week(hours: 0..<24) { _, _ in 0.5 }
        let now = Self.monday.addingTimeInterval(8 * 86_400)
        let profile = BatteryEstimator.profile(log: log, now: now, calendar: Self.utc)
        let f = try #require(BatteryEstimator.rhythmForecast(remainingWh: 50, fullWh: 60, percent: 83, recentPowerW: nil,
                                                             profile: profile, now: now, calendar: Self.utc))
        #expect(f.median == nil) // 100 h, beyond 48 h
        #expect(f.late == nil)
    }
}

@Suite struct MinuteLogTests {
    @Test func accumulatorAveragesPerMinute() {
        var acc = MinuteAccumulator()
        let base = MinuteAccumulator.minuteStart(t0)
        #expect(acc.add(minute(0, watts: 4).with(t: base.addingTimeInterval(5))) == nil)
        #expect(acc.add(minute(0, watts: 8).with(t: base.addingTimeInterval(35))) == nil)
        let done = acc.add(minute(0, watts: 1).with(t: base.addingTimeInterval(65)))
        #expect(done?.t == base)
        #expect(done?.batteryW == 6)
        #expect(acc.flush()?.batteryW == 1)
    }

    @Test func logPersistsAndReloads() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.jsonl")
        let now = Date.now
        let log = MinuteLog(url: url)
        log.append(minute(0).with(t: now.addingTimeInterval(-120)))
        log.append(minute(0).with(t: now.addingTimeInterval(-60)))
        log.append(minute(0).with(t: now.addingTimeInterval(-90))) // older than the last one: ignored
        #expect(log.samples.count == 2)

        let reloaded = MinuteLog(url: url)
        #expect(reloaded.samples.count == 2)
        #expect(reloaded.since(now.addingTimeInterval(-70)).count == 1)
    }

    @Test func logDropsOldEntriesOnLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("m.jsonl")
        let log = MinuteLog(url: url)
        log.append(minute(0).with(t: Date.now.addingTimeInterval(-MinuteLog.retention - 3600)))
        log.append(minute(0).with(t: Date.now.addingTimeInterval(-60)))
        #expect(MinuteLog(url: url).samples.count == 1)
    }
}

@Suite struct FormatTests {
    @Test func durations() {
        #expect(Fmt.duration(42 * 60) == "42 min")
        #expect(Fmt.duration(5 * 3600 + 9 * 60) == "5h 9m")
        #expect(Fmt.durationCompact(5 * 3600 + 9 * 60) == "5:09")
        #expect(Fmt.durationCompact(7 * 60) == "7m")
    }

    @Test func rates() {
        #expect(Fmt.rateCompact(500) == "0K")
        #expect(Fmt.rateCompact(340_000) == "340K")
        #expect(Fmt.rateCompact(1_200_000) == "1.2M")
    }

    @Test func englishNumbers() {
        #expect(Fmt.percent(0.42) == "42%")
        #expect(Fmt.watts(4.26) == "4.3 W")
        #expect(Fmt.bytes(12_930_000_000) == "12.04 GB")
        #expect(Fmt.rate(1_200_000) == "1.2 MB/s")
        #expect(Fmt.rate(0) == "0 bytes/s")
    }

    @Test func smoothedFollowsInput() {
        var s = Smoothed(tau: 10)
        s.add(0, at: t0)
        s.add(10, at: t0.addingTimeInterval(10))
        #expect(abs((s.value ?? 0) - 10 * (1 - exp(-1))) < 0.0001)
    }
}

private extension MinuteSample {
    func with(t: Date) -> MinuteSample {
        var copy = self
        copy.t = t
        return copy
    }
}
