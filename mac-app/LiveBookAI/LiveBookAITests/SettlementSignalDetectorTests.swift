import XCTest
@testable import LiveBookAI

/// R2 tests for the streaming settlement signal detector.
/// 所有买家名均为虚构示例（买家甲/乙/丁、buyer_e → BuyerCatalog 规范名）。
final class SettlementSignalDetectorTests: XCTestCase {
    private func makeDetector() -> SettlementSignalDetector {
        SettlementSignalDetector()
    }

    // MARK: - Settle homophone signals

    func testSettleSignalWithPriceAndBuyer() {
        let d = makeDetector()
        let signals = d.ingest(text: "恭喜甲老师三十元结拍", timestamp: 100)
        XCTAssertEqual(signals.count, 1)
        guard case .sold(let buyer, let price)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家甲")
        XCTAssertEqual(price, 30)
    }

    func testAllSettleHomophones() {
        for sig in SettlementSignalDetector.settleSignals {
            let d = makeDetector()
            let signals = d.ingest(text: "五十元恭喜乙老师\(sig)", timestamp: 100)
            XCTAssertEqual(signals.count, 1, "signal \(sig)")
            guard case .sold(let buyer, let price)? = signals.first?.kind else {
                return XCTFail("expected .sold for \(sig)")
            }
            XCTAssertEqual(buyer, "买家乙", "signal \(sig)")
            XCTAssertEqual(price, 50, "signal \(sig)")
        }
    }

    func testCountdownWithGongxi() {
        let d = makeDetector()
        let signals = d.ingest(text: "现在五十元五四三二一恭喜乙老师", timestamp: 100)
        XCTAssertEqual(signals.count, 1)
        guard case .sold(let buyer, let price)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家乙")
        XCTAssertEqual(price, 50)
    }

    func testSpokenPriceForms() {
        let cases: [(String, Int)] = [
            ("一百五结拍", 150),
            ("三百块结拍", 300),
            ("七十五结拍", 75),
            ("两百六结拍", 260),
            ("五十五结拍", 55),
        ]
        for (text, expected) in cases {
            let d = makeDetector()
            let signals = d.ingest(text: text, timestamp: 100)
            guard case .sold(_, let price)? = signals.first?.kind else {
                return XCTFail("no sold for \(text)")
            }
            XCTAssertEqual(price, expected, "text: \(text)")
        }
    }

    func testArabicPrice() {
        let d = makeDetector()
        let signals = d.ingest(text: "恭喜乙老师75结拍", timestamp: 100)
        guard case .sold(let buyer, let price)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家乙")
        XCTAssertEqual(price, 75)
    }

    func testBuyerAliasMapping() {
        let d = makeDetector()
        // 伊老师 is an ASR alias for buyer_e.
        let signals = d.ingest(text: "五四三二一恭喜伊老师", timestamp: 100)
        guard case .sold(let buyer, _)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "buyer_e")
    }

    func testSoldWithoutBuyerStillEmits() {
        let d = makeDetector()
        let signals = d.ingest(text: "五十元结拍", timestamp: 100)
        XCTAssertEqual(signals.count, 1)
        guard case .sold(let buyer, let price)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertNil(buyer)
        XCTAssertEqual(price, 50)
    }

    // MARK: - Passed

    func testPassedKeywords() {
        for kw in SettlementSignalDetector.passedKeywords {
            let d = makeDetector()
            let signals = d.ingest(text: "\(kw)", timestamp: 100)
            XCTAssertEqual(signals.count, 1, "keyword \(kw)")
            guard case .passed = signals.first?.kind else {
                return XCTFail("expected .passed for \(kw)")
            }
        }
    }

    func testStandaloneGongxiSignal() {
        let d = makeDetector()
        let signals = d.ingest(text: "那我们恭喜丁老师", timestamp: 100)
        XCTAssertEqual(signals.count, 1)
        guard case .sold(let buyer, _)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家丁")
    }

    func testGongxiWithPrice() {
        let d = makeDetector()
        let signals = d.ingest(text: "出价是四十好的那我们恭喜丁老师", timestamp: 100)
        guard case .sold(let buyer, let price)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家丁")
        XCTAssertEqual(price, 40)
    }

    func testGongxiWeForm() {
        let d = makeDetector()
        let signals = d.ingest(text: "恭喜我们丁老师感谢老师支持", timestamp: 100)
        guard case .sold(let buyer, _)? = signals.first?.kind else {
            return XCTFail("expected .sold")
        }
        XCTAssertEqual(buyer, "买家丁")
    }

    // MARK: - Streaming

    func testSignalSplitAcrossIngests() {
        let d = makeDetector()
        // A partial 恭喜 may fire early (buyer only, no price yet) — the
        // fuser merges it with the bid ladder.
        d.ingest(text: "恭喜乙老师五", timestamp: 10)
        let signals = d.ingest(text: "十元结拍", timestamp: 11)
        let sold = signals.compactMap { s -> (String?, Int?)? in
            if case .sold(let b, let p) = s.kind { return (b, p) } else { return nil }
        }
        XCTAssertTrue(sold.contains { $0.0 == "买家乙" && $0.1 == 50 },
                      "expected a sold(买家乙, 50) across the split ingests")
    }

    func testDedupByOffsetWithinWindow() {
        let d = makeDetector()
        // Two occurrences of the same signal in one ingest → both detected at
        // different offsets (not merged).
        let signals = d.ingest(text: "五十元结拍然后五十元结拍", timestamp: 100)
        XCTAssertEqual(signals.count, 2)
    }

    // MARK: - Pure helpers

    func testFindPrices() {
        let prices = SettlementSignalDetector.findPrices(in: "一百五元结拍")
        XCTAssertEqual(prices.last?.value, 150)
    }

    func testFindPricesLongestWinsOverlap() {
        // "一百五" contains "一百" — the longer match must win.
        let prices = SettlementSignalDetector.findPrices(in: "一百五")
        XCTAssertEqual(prices.count, 1)
        XCTAssertEqual(prices.last?.value, 150)
    }

    func testFindBuyerSingleCharOnlyInGongxi() {
        // "甲方" contains "甲" — the fallback context must NOT match single-char aliases.
        XCTAssertNil(SettlementSignalDetector.findBuyer(in: "现在出价甲方是", allowSingleChar: false))
        // But 恭喜 context may.
        XCTAssertEqual(SettlementSignalDetector.findBuyer(in: "甲老师三十元", allowSingleChar: true), "买家甲")
    }

    func testDescribe() {
        let sold = SettlementSignal(kind: .sold(buyer: "买家乙", price: 50), timestamp: 0)
        XCTAssertTrue(SettlementSignalDetector.describe(sold).contains("买家乙"))
        let passed = SettlementSignal(kind: .passed, timestamp: 0)
        XCTAssertTrue(SettlementSignalDetector.describe(passed).contains("流拍"))
    }
}
