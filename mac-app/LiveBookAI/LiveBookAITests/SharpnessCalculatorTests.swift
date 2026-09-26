import XCTest
@testable import LiveBookAI

final class SharpnessCalculatorTests: XCTestCase {
    func testUniformImageZeroSharpness() {
        let bytes = [UInt8](repeating: 128, count: 64 * 64)
        let variance = SharpnessCalculator.laplacianVariance(bytes, width: 64)
        XCTAssertEqual(variance, 0, accuracy: 0.001)
    }

    func testCheckerboardHigherThanUniform() {
        let uniform = [UInt8](repeating: 128, count: 64 * 64)
        var checker = [UInt8](repeating: 0, count: 64 * 64)
        for y in 0..<64 {
            for x in 0..<64 {
                checker[y * 64 + x] = ((x + y) % 2 == 0) ? 0 : 255
            }
        }
        let vUniform = SharpnessCalculator.laplacianVariance(uniform, width: 64)
        let vChecker = SharpnessCalculator.laplacianVariance(checker, width: 64)
        XCTAssertGreaterThan(vChecker, vUniform)
    }

    func testSmallImageReturnsZero() {
        let bytes = [UInt8](repeating: 0, count: 9)
        XCTAssertEqual(SharpnessCalculator.laplacianVariance(bytes, width: 3), 0)
    }

    func testNormalizedSharpnessInRange() {
        let bytes = [UInt8](repeating: 100, count: 64 * 64)
        let s = SharpnessCalculator.sharpness(bytes)
        XCTAssertGreaterThanOrEqual(s, 0)
        XCTAssertLessThanOrEqual(s, 1)
    }
}
