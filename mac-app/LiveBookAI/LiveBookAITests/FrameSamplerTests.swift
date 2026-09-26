import XCTest
@testable import LiveBookAI

final class FrameSamplerTests: XCTestCase {
    func testDefaultIntervalSamplesAbout2FPS() {
        var sampler = AdaptiveFrameSampler()
        // Static scene → static interval (2s).
        let frames = stride(from: 0.0, through: 10.0, by: 0.1)
        var count = 0
        var lastOCR = -1.0
        for t in frames {
            if sampler.considerFrame(at: t, change: 0.0) {
                count += 1
                lastOCR = t
            }
        }
        // Static: interval 2s over [0, 10] → samples at 0,2,4,6,8,10 = 6.
        XCTAssertEqual(count, 6)
        XCTAssertEqual(lastOCR, 10.0)
    }

    func testActiveChangeRaisesTo5FPS() {
        var sampler = AdaptiveFrameSampler(changeThreshold: 0.15)
        // Continuous strong change → active interval 0.2s.
        let frames = stride(from: 0.0, through: 2.0, by: 0.05)
        var count = 0
        var lastOCR = -1.0
        for t in frames {
            if sampler.considerFrame(at: t, change: 0.9) {
                count += 1
                lastOCR = t
            }
        }
        // Active: interval 0.2s over [0,2] → samples at 0,0.2,...,2.0 = 11.
        XCTAssertEqual(count, 11)
        XCTAssertEqual(lastOCR, 2.0)
    }

    func testStaticThenChangeRaisesRate() {
        var sampler = AdaptiveFrameSampler()
        // Static for a while.
        for t in stride(from: 0.0, to: 6.0, by: 0.1) {
            _ = sampler.considerFrame(at: t, change: 0.01)
        }
        XCTAssertEqual(sampler.currentInterval, 2.0)  // static rate reached
        // Now strong change.
        _ = sampler.considerFrame(at: 6.1, change: 0.8)
        XCTAssertEqual(sampler.currentInterval, 0.2)  // active rate
    }

    func testReset() {
        var sampler = AdaptiveFrameSampler()
        for t in stride(from: 0.0, through: 10.0, by: 0.1) {
            _ = sampler.considerFrame(at: t, change: 0.0)
        }
        sampler.reset()
        XCTAssertEqual(sampler.lastChange, 0)
        XCTAssertEqual(sampler.staticFrames, 0)
        XCTAssertTrue(sampler.considerFrame(at: 0.0, change: 1.0))
    }
}
