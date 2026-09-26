import XCTest
@testable import LiveBookAI

final class ModelTests: XCTestCase {
    func testOCRResultCarriesTimestampAndConfidence() {
        let obs = OCRObservation(id: UUID(), text: "日本美术全集", confidence: 0.92,
                                 boundingBox: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.1),
                                 isISBN: false)
        let result = OCRResult(id: UUID(), timestamp: 321.1, text: "日本美术全集",
                               confidence: 0.92, observations: [obs], isbn: nil, latency: 0.05)
        XCTAssertEqual(result.timestamp, 321.1)
        XCTAssertEqual(result.confidence, 0.92)
        XCTAssertEqual(result.text, "日本美术全集")
    }

    func testOCRResultCodableRoundTrip() throws {
        let obs = OCRObservation(id: UUID(), text: "ISBN 9787108025302", confidence: 0.8,
                                 boundingBox: CGRect(x: 0, y: 0, width: 0.3, height: 0.05),
                                 isISBN: true)
        let original = OCRResult(id: UUID(), timestamp: 12.5, text: "ISBN 9787108025302",
                                 confidence: 0.8,
                                 observations: [obs],
                                 isbn: ISBN(digits: "9787108025302", kind: .isbn13, isValid: true, display: "978-7-108-02530-2"),
                                 latency: 0.1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(OCRResult.self, from: data)
        XCTAssertEqual(decoded.timestamp, original.timestamp)
        XCTAssertEqual(decoded.isbn?.digits, "9787108025302")
        XCTAssertEqual(decoded.observations.first?.isISBN, true)
    }

    func testScoredFrameScoreComputed() {
        var frame = ScoredFrame(id: UUID(), timestamp: 0,
                                pixelSize: CGSize(width: 912, height: 1920),
                                sharpness: 0.8, ocrConfidence: 0.9, hasISBN: true,
                                textArea: 0.3, score: 0, isValid: true)
        frame.score = BestFrameSelector.computeScore(frame)
        XCTAssertEqual(frame.score, 0.8 * 0.45 + 0.9 * 0.35 + 1.0 * 0.15 + 0.3 * 0.05, accuracy: 0.001)
    }

    func testGroundTruthItemIdentifiable() {
        let item = GroundTruthItem(no: 1, title: "明清时代庶民文化", t0: 202.4, tSec: 304, buyer: "买家甲", price: 30)
        XCTAssertEqual(item.id, 1)
    }
}
