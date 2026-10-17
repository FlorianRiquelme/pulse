import Foundation
import Testing
@testable import PulseCore

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private let mb = 1_000_000.0

@Suite struct GrowthTrackerTests {
    /// Feeds values every 15 s, like the process sampler.
    private func track(minutes: Int, _ value: (Double) -> [Int: Double]) -> GrowthTracker<Int> {
        var tracker = GrowthTracker<Int>()
        for i in stride(from: 0, through: minutes * 60, by: 15) {
            tracker.add(value(Double(i) / 3600), at: t0.addingTimeInterval(Double(i)))
        }
        return tracker
    }

    @Test func detectsSteadyGrowth() throws {
        // App 1 grows by 200 MB/h for 3 h, app 2 stays the same.
        let tracker = track(minutes: 180) { h in [1: 1000 * mb + 200 * mb * h, 2: 3000 * mb] }
        let growing = tracker.growing()
        #expect(growing.count == 1)
        let g = try #require(growing.first)
        #expect(g.key == 1)
        #expect(abs(g.perHour - 200 * mb) < 1 * mb)
        #expect(abs(g.duration - 3 * 3600) < 600)
        #expect(abs(g.gained - 600 * mb) < 20 * mb)
    }

    @Test func ignoresShortOrSmallGrowth() {
        // Fast for 40 min, or only 30 MB/h for 3 h: neither warrants a hint.
        #expect(track(minutes: 40) { h in [1: 1000 * mb + 600 * mb * h] }.growing().isEmpty)
        #expect(track(minutes: 180) { h in [1: 1000 * mb + 30 * mb * h] }.growing().isEmpty)
    }

    @Test func ignoresSingleStep() {
        // 800 MB more once (e.g. a large document opened), flat afterwards.
        let tracker = track(minutes: 240) { h in [1: h < 2 ? 1000 * mb : 1800 * mb] }
        #expect(tracker.growing().isEmpty)
    }

    @Test func ignoresGrowthThatShrankAgain() {
        // 2 h of growth, then dropped clearly again.
        let tracker = track(minutes: 180) { h in [1: h < 2 ? 1000 * mb + 400 * mb * h : 1300 * mb] }
        #expect(tracker.growing().isEmpty)
    }

    @Test func forgetsEndedApps() {
        var tracker = track(minutes: 180) { h in [1: 1000 * mb + 200 * mb * h] }
        tracker.add([2: 100 * mb], at: t0.addingTimeInterval(181 * 60))
        #expect(tracker.growing().isEmpty)
    }
}

@Suite struct SwapMinuteTests {
    private func sample(_ s: Int, swap: Double?, swapIn: Double?) -> MinuteSample {
        MinuteSample(t: t0.addingTimeInterval(Double(s)), battery: nil, plugged: true, charging: false, batteryW: nil,
                     systemW: nil, cpu: 0.1, gpu: nil, mem: 0.5, socTemp: nil, swap: swap, swapIn: swapIn, swapOut: 0)
    }

    @Test func averagesSwapPerMinute() throws {
        var acc = MinuteAccumulator()
        let start = MinuteAccumulator.minuteStart(t0)
        let offset = Int(t0.timeIntervalSince(start))
        _ = acc.add(sample(-offset, swap: 4e9, swapIn: nil)) // first reading without a rate
        _ = acc.add(sample(-offset + 20, swap: 5e9, swapIn: 2e6))
        let finished = acc.add(sample(-offset + 60, swap: 5e9, swapIn: 0))
        let minute = try #require(finished)
        #expect(minute.swap == 4.5e9)
        #expect(minute.swapIn == 2e6)
        #expect(minute.swapOut == 0)
    }

    @Test func oldLinesWithoutSwapStillDecode() throws {
        let line = #"{"t":1790000000,"p":true,"c":false,"cpu":0.2,"mem":0.6}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let s = try decoder.decode(MinuteSample.self, from: Data(line.utf8))
        #expect(s.swap == nil && s.swapIn == nil && s.mem == 0.6)
    }
}
