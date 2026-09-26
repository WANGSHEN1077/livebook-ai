import XCTest
@testable import LiveBookAI

/// R1 tests for the real-time danmaku bid parser.
/// 所有买家名均为虚构示例（买家甲/乙/丙/丁/戊/己 → BuyerCatalog 规范名）。
final class DanmakuBidParserTests: XCTestCase {
    private func makeParser() -> DanmakuBidParser {
        DanmakuBidParser()
    }

    /// Feed one line and return its events.
    @discardableResult
    private func feed(_ parser: DanmakuBidParser, _ line: String, at t: Double) -> [DanmakuBidParserEvent] {
        parser.ingest(text: line, timestamp: t)
    }

    private func currentBids(_ parser: DanmakuBidParser) -> [DanmakuBid] {
        parser.snapshot().current?.bids ?? []
    }

    // MARK: - Bid ladder

    func testBasicBidLadder() {
        let p = makeParser()
        feed(p, "买家乙 5", at: 10)
        feed(p, "买家乙 10", at: 11)
        feed(p, "买家丁 15", at: 12)
        let bids = currentBids(p)
        XCTAssertEqual(bids.count, 3)
        XCTAssertEqual(bids.map(\.price), [5, 10, 15])
        XCTAssertEqual(bids.last?.sender, "买家丁")
        XCTAssertEqual(p.snapshot().current?.price, 15)
        XCTAssertEqual(p.snapshot().current?.buyer, "买家丁")
    }

    func testColonAndYuanFormats() {
        let p = makeParser()
        feed(p, "买家乙:5元", at: 10)
        feed(p, "买家丙 10块", at: 11)
        let bids = currentBids(p)
        XCTAssertEqual(bids.map(\.price), [5, 10])
        XCTAssertEqual(bids[0].sender, "买家乙")
    }

    func testBareNumberAttributedToLastSpeaker() {
        let p = makeParser()
        feed(p, "买家乙 5", at: 10)
        feed(p, "10", at: 11)
        let bids = currentBids(p)
        XCTAssertEqual(bids.count, 2)
        XCTAssertEqual(bids.last?.sender, "买家乙")
        XCTAssertEqual(bids.last?.price, 10)
    }

    func testBareNumberWithoutSpeakerIgnored() {
        let p = makeParser()
        feed(p, "5", at: 10)
        XCTAssertTrue(currentBids(p).isEmpty)
    }

    // MARK: - Separator / window settlement

    func testSeparatorSettlesWindow() {
        let p = makeParser()
        feed(p, "买家乙 5", at: 10)
        feed(p, "买家丁 10", at: 12)
        let events = feed(p, "----------------", at: 15)
        XCTAssertTrue(events.contains { if case .windowSettled = $0 { return true } else { return false } })
        let snap = p.snapshot()
        XCTAssertEqual(snap.settled.count, 1)
        XCTAssertEqual(snap.settled[0].buyer, "买家丁")
        XCTAssertEqual(snap.settled[0].price, 10)
        XCTAssertEqual(snap.settled[0].endTime, 15)
        XCTAssertNil(snap.current?.bids.isEmpty == false ? nil : snap.current?.bids.first) // new window
    }

    func testNewWindowAfterSeparator() {
        let p = makeParser()
        feed(p, "买家乙 5", at: 10)
        feed(p, "-----", at: 12)
        feed(p, "买家丙 3", at: 13)
        let bids = currentBids(p)
        XCTAssertEqual(bids.count, 1)
        XCTAssertEqual(bids.first?.sender, "买家丙")
        XCTAssertEqual(bids.first?.price, 3)
    }

    // MARK: - Validation rules

    func testMonotonicRejectsLowerPrice() {
        let p = makeParser()
        feed(p, "买家乙 10", at: 10)
        feed(p, "买家丁 5", at: 11)
        XCTAssertEqual(currentBids(p).count, 1)
    }

    func testDedupSameSenderPrice() {
        let p = makeParser()
        feed(p, "买家乙 5", at: 10)
        feed(p, "买家乙 5", at: 11)
        XCTAssertEqual(currentBids(p).count, 1)
    }

    func testSystemLinesIgnored() {
        let p = makeParser()
        feed(p, "买家乙 送出礼物", at: 10)
        feed(p, "买家己 进入直播间", at: 11)
        feed(p, "这本书真好", at: 12)
        XCTAssertTrue(currentBids(p).isEmpty)
    }

    func testHostLinesIgnored() {
        let p = makeParser()
        feed(p, "示例书屋 作者 5", at: 10)
        feed(p, "作者 ------------", at: 11)
        XCTAssertTrue(currentBids(p).isEmpty)
    }

    // MARK: - Buyer catalog

    func testCanonicalBuyerMapping() {
        let p = makeParser()
        feed(p, "甲老师 5", at: 10)
        XCTAssertEqual(currentBids(p).first?.sender, "买家甲")
    }

    func testUnknownSenderKeptRaw() {
        let p = makeParser()
        feed(p, "神秘买家 8", at: 10)
        XCTAssertEqual(currentBids(p).first?.sender, "神秘买家")
    }

    // MARK: - Prices

    func testCJKPrices() {
        let p = makeParser()
        feed(p, "买家乙 十五", at: 10)
        feed(p, "买家丁 一百五", at: 11)
        feed(p, "买家丙 两百六", at: 12)
        feed(p, "买家戊 一千", at: 13)
        XCTAssertEqual(currentBids(p).map(\.price), [15, 150, 260, 1000])
    }

    func testArabicPriceRange() {
        let p = makeParser()
        feed(p, "买家乙 99999", at: 10)   // beyond maxPrice → ignored
        feed(p, "买家乙 30", at: 11)
        XCTAssertEqual(currentBids(p).map(\.price), [30])
    }

    // MARK: - Pure helpers

    func testIsSeparator() {
        XCTAssertTrue(DanmakuBidParser.isSeparator("----------------"))
        XCTAssertTrue(DanmakuBidParser.isSeparator("===="))
        XCTAssertTrue(DanmakuBidParser.isSeparator("----"))
        XCTAssertFalse(DanmakuBidParser.isSeparator("买家乙 5"))
        XCTAssertFalse(DanmakuBidParser.isSeparator("--买家乙--"))
    }

    func testCJKNumberConverter() {
        XCTAssertEqual(DanmakuBidParser.cjkNumber("十五"), 15)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("二十"), 20)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("一百五"), 150)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("两百六"), 260)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("三百"), 300)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("五百"), 500)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("一千"), 1000)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("两千"), 2000)
        XCTAssertEqual(DanmakuBidParser.cjkNumber("一"), 1)
        XCTAssertNil(DanmakuBidParser.cjkNumber("abc"))
    }

    // MARK: - Region

    func testDanmakuRegionRightColumn() {
        // Observation centered at x=0.9 → in the danmaku region.
        let obs = OCRObservation(id: UUID(), text: "买家乙 5", confidence: 0.9,
                                 boundingBox: CGRect(x: 0.85, y: 0.5, width: 0.1, height: 0.05),
                                 isISBN: false)
        XCTAssertTrue(DanmakuRegion.contains(obs))
        // Center of the video → not danmaku.
        let center = OCRObservation(id: UUID(), text: "明清时代", confidence: 0.9,
                                    boundingBox: CGRect(x: 0.3, y: 0.6, width: 0.2, height: 0.1),
                                    isISBN: false)
        XCTAssertFalse(DanmakuRegion.contains(center))
    }
}
