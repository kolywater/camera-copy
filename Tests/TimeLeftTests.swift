import XCTest

final class TimeLeftTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    func testEstimatingDuringWarmup() {
        var e = TimeLeftEstimator()
        XCTAssertNil(e.sample(done: 0, total: 1000, at: t0))
        for s in 1...4 { XCTAssertNil(e.sample(done: Int64(s * 10), total: 1000, at: t0 + Double(s))) }
        XCTAssertNotNil(e.sample(done: 50, total: 1000, at: t0 + 5))
    }

    func testSteadyRateIsAccurate() {
        var e = TimeLeftEstimator()
        var left: TimeInterval?
        for s in 0...60 { left = e.sample(done: Int64(s) * 10_000_000, total: 6_000_000_000, at: t0 + Double(s)) }
        // 10 MB/s, 5.4 GB to go: 540 s.
        XCTAssertEqual(left!, 540, accuracy: 5)
    }

    func testNoisyRateDoesNotJumpAround() {
        var e = TimeLeftEstimator()
        var done: Int64 = 0
        var shown: [TimeInterval] = []
        for s in 0...600 {
            done += s % 2 == 0 ? 5_000_000 : 15_000_000          // alternates 5 and 15 MB/s, 10 MB/s average
            if let l = e.sample(done: done, total: 12_000_000_000, at: t0 + Double(s)) { shown.append(l) }
        }
        let steps = zip(shown, shown.dropFirst()).map { $1 - $0 }
        XCTAssertLessThan(steps.map(abs).max()!, 10, "the shown time moves at most a few seconds per second")
        XCTAssertLessThan(steps.filter { $0 > 0 }.count, steps.count / 20, "it almost never goes up")
    }

    func testFollowsARealSlowdown() {
        var e = TimeLeftEstimator()
        var done: Int64 = 0, last: TimeInterval = 0
        for s in 0...600 {
            done += s < 300 ? 20_000_000 : 5_000_000              // the card gets 4× slower halfway
            if let l = e.sample(done: done, total: 12_000_000_000, at: t0 + Double(s)) { last = l }
        }
        // Left after 600 s: 12 GB - 7.5 GB = 4.5 GB at 5 MB/s = 900 s.
        XCTAssertEqual(last, 900, accuracy: 150)
    }

    func testSameTimestampAndStalledProgress() {
        var e = TimeLeftEstimator()
        _ = e.sample(done: 0, total: 100, at: t0)
        XCTAssertNil(e.sample(done: 0, total: 100, at: t0), "no time passed")
        XCTAssertNil(e.sample(done: 0, total: 100, at: t0 + 10), "no progress, no estimate")
    }

    func testText() {
        XCTAssertEqual(TimeLeftEstimator.text(10), "Less than a minute left")
        XCTAssertEqual(TimeLeftEstimator.text(55), "About 1 min left")
        XCTAssertEqual(TimeLeftEstimator.text(4 * 60 + 10), "About 4 min left")
        XCTAssertEqual(TimeLeftEstimator.text(59 * 60), "About 59 min left")
        XCTAssertEqual(TimeLeftEstimator.text(3600 + 25 * 60), "About 1 h 25 min left")
        XCTAssertEqual(TimeLeftEstimator.text(2 * 3600 + 60), "About 2 h left")
    }
}
