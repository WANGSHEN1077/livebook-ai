import XCTest
@testable import LiveBookAI

final class ChangeDetectorTests: XCTestCase {
    func testIdenticalFramesZeroDifference() {
        let a = [UInt8](repeating: 128, count: 100)
        XCTAssertEqual(ChangeDetector.difference(a, a), 0, accuracy: 0.001)
    }

    func testCompletelyDifferentFramesHighDifference() {
        let a = [UInt8](repeating: 0, count: 100)
        let b = [UInt8](repeating: 255, count: 100)
        XCTAssertEqual(ChangeDetector.difference(a, b), 1.0, accuracy: 0.001)
    }

    func testPartialDifferenceScales() {
        let a = [UInt8](repeating: 0, count: 100)
        var b = [UInt8](repeating: 0, count: 100)
        for i in 0..<50 { b[i] = 255 }
        // Half the pixels fully changed → ~0.5.
        XCTAssertEqual(ChangeDetector.difference(a, b), 0.5, accuracy: 0.001)
    }

    func testEmptyArrays() {
        XCTAssertEqual(ChangeDetector.difference([], []), 0)
        XCTAssertEqual(ChangeDetector.difference([1], [1, 2]), 0)  // mismatched sizes
    }
}
