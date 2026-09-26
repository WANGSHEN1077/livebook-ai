import XCTest
import CoreGraphics
@testable import LiveBookAI

/// Tests for OCRResult.bookAreaText: the "当前商品" text must exclude the
/// danmaku column, keep reading order top-to-bottom, and join lines with "\n".
final class BookAreaTextTests: XCTestCase {
    private func obs(_ text: String, x: Double, y: Double, w: Double = 0.1, h: Double = 0.05) -> OCRObservation {
        OCRObservation(id: UUID(),
                       text: text,
                       confidence: 0.9,
                       boundingBox: CGRect(x: x, y: y, width: w, height: h),
                       isISBN: false)
    }

    func testExcludesDanmakuColumn() {
        let result = OCRResult(id: UUID(), timestamp: 0,
                               text: "dummy", confidence: 0.9,
                               observations: [
                                obs("明清时代", x: 0.2, y: 0.6),       // book area
                                obs("主播好棒", x: 0.9, y: 0.7)        // danmaku column (maxX 1.0)
                               ],
                               isbn: nil, latency: 0)
        let text = result.bookAreaText()
        XCTAssertTrue(text.contains("明清时代"))
        XCTAssertFalse(text.contains("主播好棒"), "弹幕栏文本不应出现在当前商品中")
    }

    func testTopToBottomOrder() {
        let result = OCRResult(id: UUID(), timestamp: 0,
                               text: "dummy", confidence: 0.9,
                               observations: [
                                obs("下面一行", x: 0.3, y: 0.3),
                                obs("上面一行", x: 0.3, y: 0.8)
                               ],
                               isbn: nil, latency: 0)
        XCTAssertEqual(result.bookAreaText(), "上面一行\n下面一行")
    }

    func testJoinedWithNewlines() {
        let result = OCRResult(id: UUID(), timestamp: 0,
                               text: "dummy", confidence: 0.9,
                               observations: [
                                obs("A", x: 0.2, y: 0.7),
                                obs("B", x: 0.2, y: 0.6),
                                obs("C", x: 0.2, y: 0.5)
                               ],
                               isbn: nil, latency: 0)
        XCTAssertEqual(result.bookAreaText(), "A\nB\nC")
    }

    func testEmptyObservations() {
        let result = OCRResult(id: UUID(), timestamp: 0,
                               text: "", confidence: 0,
                               observations: [],
                               isbn: nil, latency: 0)
        XCTAssertEqual(result.bookAreaText(), "")
    }

    func testCustomDanmakuThreshold() {
        let result = OCRResult(id: UUID(), timestamp: 0,
                               text: "dummy", confidence: 0.9,
                               observations: [
                                obs("书", x: 0.5, y: 0.5),     // maxX 0.6 < 0.65 → kept
                                obs("弹幕", x: 0.6, y: 0.5)    // maxX 0.7 > 0.65 → dropped
                               ],
                               isbn: nil, latency: 0)
        XCTAssertEqual(result.bookAreaText(danmakuMinX: 0.65), "书")
    }
}
