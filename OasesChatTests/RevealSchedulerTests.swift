import XCTest
@testable import Oases_Chat

final class RevealSchedulerTests: XCTestCase {
    func testFirstBatchUsesTheInitialPaceAndStartsNow() {
        var s = RevealScheduler()
        let plan = s.schedule(count: 10, now: 100)
        XCTAssertEqual(plan.start, 100, accuracy: 1e-9)
        XCTAssertEqual(plan.interval, 0.03 * 1.25, accuracy: 1e-6)
    }

    func testBatchesQueueBehindEachOtherAndNeverOverlap() {
        var s = RevealScheduler()
        let a = s.schedule(count: 20, now: 100)
        let aEnd = a.start + 20 * a.interval
        let b = s.schedule(count: 20, now: 100.05)
        XCTAssertGreaterThanOrEqual(b.start + 1e-9, aEnd)
    }

    func testABacklogIsReleasedFasterButStaysBounded() {
        var s = RevealScheduler()
        _ = s.schedule(count: 40, now: 100)
        let calm = s.schedule(count: 5, now: 100.2).interval
        // A burst piles on: it must still finish within the lag bound.
        let burst = s.schedule(count: 400, now: 100.25)
        XCTAssertLessThanOrEqual(burst.start + 400 * burst.interval, 100.25 + 2.0 + 1e-6)
        XCTAssertGreaterThanOrEqual(burst.interval, 0.004 - 1e-9)
        XCTAssertLessThan(burst.interval, calm)
    }

    func testAStallDoesNotSlowThePaceDown() {
        var s = RevealScheduler()
        _ = s.schedule(count: 10, now: 100)
        let before = s.schedule(count: 10, now: 100.1).interval
        // Ten seconds of silence, then the same rate again.
        _ = s.schedule(count: 10, now: 110)
        let after = s.schedule(count: 10, now: 110.1).interval
        XCTAssertEqual(after, before, accuracy: 0.02)
    }

    func testSlowRefreshesRaiseTheLagBoundSoRevealSpreadsAcrossTheGap() {
        var s = RevealScheduler()
        var now: CFTimeInterval = 100
        var last = (start: 0.0, interval: 0.0)
        // A long reply that only refreshes every 1.5 s with 60 words each time.
        for _ in 0..<6 {
            last = s.schedule(count: 60, now: now)
            now += 1.5
        }
        let span = 60 * last.interval
        XCTAssertGreaterThan(span, 0.6, "words should be spread over most of the refresh gap, not flashed")
        XCTAssertLessThanOrEqual(last.start + span - (now - 1.5), 2.0 + 1e-6)
    }

    func testResetStartsOver() {
        var s = RevealScheduler()
        _ = s.schedule(count: 100, now: 100)
        s.reset()
        XCTAssertEqual(s.end, 0)
        let plan = s.schedule(count: 1, now: 5)
        XCTAssertEqual(plan.start, 5, accuracy: 1e-9)
    }
}
