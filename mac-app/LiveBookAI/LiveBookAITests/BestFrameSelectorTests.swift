import XCTest
@testable import LiveBookAI

final class BestFrameSelectorTests: XCTestCase {
    private func makeFrame(sharpness: Double = 0.5,
                           conf: Float = 0.5,
                           hasISBN: Bool = false,
                           area: Double = 0.2) -> ScoredFrame {
        ScoredFrame(id: UUID(),
                    timestamp: 0,
                    pixelSize: .init(width: 912, height: 1920),
                    sharpness: sharpness,
                    ocrConfidence: conf,
                    hasISBN: hasISBN,
                    textArea: area,
                    score: 0,
                    isValid: true)
    }

    func testSharpFrameBeatsBlurry() {
        let sharp = makeFrame(sharpness: 0.9, conf: 0.5)
        let blurry = makeFrame(sharpness: 0.2, conf: 0.5)
        XCTAssertGreaterThan(BestFrameSelector.computeScore(sharp),
                             BestFrameSelector.computeScore(blurry))
    }

    func testISBNBonus() {
        let noISBN = makeFrame(sharpness: 0.5, conf: 0.5, hasISBN: false)
        let withISBN = makeFrame(sharpness: 0.5, conf: 0.5, hasISBN: true)
        XCTAssertGreaterThan(BestFrameSelector.computeScore(withISBN),
                             BestFrameSelector.computeScore(noISBN))
    }

    func testHigherConfidenceScoresHigher() {
        let low = makeFrame(sharpness: 0.5, conf: 0.3)
        let high = makeFrame(sharpness: 0.5, conf: 0.9)
        XCTAssertGreaterThan(BestFrameSelector.computeScore(high),
                             BestFrameSelector.computeScore(low))
    }

    func testSelectorKeepsBest() {
        var selector = BestFrameSelector()
        let good = makeFrame(sharpness: 0.9, conf: 0.9)
        let bad = makeFrame(sharpness: 0.1, conf: 0.1)
        _ = selector.register(bad, kind: .coverBest, image: nil)
        let improved = selector.register(good, kind: .coverBest, image: nil)
        XCTAssertTrue(improved)
        XCTAssertEqual(selector.best(for: .coverBest)?.scoredFrame.sharpness ?? -1, 0.9, accuracy: 0.001)
        // Registering worse frame doesn't replace.
        let worse = makeFrame(sharpness: 0.05, conf: 0.05)
        let replaced = selector.register(worse, kind: .coverBest, image: nil)
        XCTAssertFalse(replaced)
    }
}
