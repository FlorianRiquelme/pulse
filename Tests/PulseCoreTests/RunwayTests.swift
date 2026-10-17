import Foundation
import Testing
@testable import PulseCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// One hour of minute values falling evenly from `from` to `to` percent.
private func hour(from: Double, to: Double, skipping skip: Range<Int> = 0..<0) -> [Point] {
    (0..<60).filter { !skip.contains($0) }.map { i in
        Point(t: now.addingTimeInterval(Double(i - 60) * 60), v: from + (to - from) * Double(i) / 60)
    }
}

@Suite struct RunwayTests {
    @Test func averagesIntoBucketsAndEndsAtNow() {
        let r = Runway(points: hour(from: 60, to: 50), now: now, percent: 50, remaining: nil)
        #expect(r.segments.count == 1)
        #expect(r.segments[0].count == 31) // 30 windows + now
        #expect(r.segments[0].last == r.now)
        #expect(r.now == Runway.Pt(x: 0.5, y: 0.5))
        #expect(r.projectionEnd == nil)
        #expect(abs(r.segments[0][0].y - (60 + 60 - 10.0 / 60) / 200) < 1e-9) // average of the first two minutes
    }

    @Test func gapSplitsSegments() {
        let r = Runway(points: hour(from: 80, to: 70, skipping: 20..<40), now: now, percent: 70, remaining: 4 * 3600)
        #expect(r.segments.count == 2)
    }

    @Test func staleHistoryDoesNotConnectToNow() {
        let old = hour(from: 80, to: 70).filter { $0.t < now.addingTimeInterval(-30 * 60) }
        let r = Runway(points: old, now: now, percent: 70, remaining: nil)
        #expect(r.segments.count == 1)
        #expect(r.segments[0].last != r.now)
    }

    @Test func projectionReachesZeroWithinTheHour() {
        let r = Runway(points: [], now: now, percent: 20, remaining: 30 * 60)
        #expect(r.segments.isEmpty)
        #expect(r.projectionEnd == Runway.Pt(x: 0.75, y: 0))
    }

    @Test func longProjectionIsClampedToFrame() {
        let r = Runway(points: [], now: now, percent: 80, remaining: 4 * 3600)
        #expect(r.projectionEnd == Runway.Pt(x: 1, y: 0.6))
    }
}
