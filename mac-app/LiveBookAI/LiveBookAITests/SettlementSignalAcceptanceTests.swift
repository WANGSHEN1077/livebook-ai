import XCTest
@testable import LiveBookAI

/// R2 acceptance: feed the real 0813 ASR transcript (9399 timestamped
/// segments) through SettlementSignalDetector and check that detected SOLD
/// signals align with the actual sales records (sales_0813_timed.json).
/// Skips when the data files are absent.
final class SettlementSignalAcceptanceTests: XCTestCase {
    private struct SaleEntry: Decodable {
        let no: Int
        let winner: String
        let price: Int
        let tSec: Double
        enum CodingKeys: String, CodingKey {
            case no, winner, price
            case tSec = "t_sec"
        }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: "/tmp/0813_transcript.json"),
              FileManager.default.fileExists(atPath: "/tmp/sales_0813_timed.json") else {
            throw XCTSkip("0813 转写/成交数据不存在，跳过验收测试")
        }
    }

    func testSignalTimesAlignWithSales() async throws {
        let transcriptData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/0813_transcript.json"))
        guard let obj = try JSONSerialization.jsonObject(with: transcriptData) as? [String: Any],
              let segments = obj["segments"] as? [[String: Any]] else {
            return XCTFail("转写 JSON 结构异常")
        }
        let salesData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/sales_0813_timed.json"))
        let sales = try JSONDecoder().decode([SaleEntry].self, from: salesData)

        // Stream the transcript through the detector (segments are the
        // incremental chunks).
        let detector = SettlementSignalDetector()
        var sold: [(t: Double, buyer: String?, price: Int?)] = []
        for seg in segments {
            guard let t = seg["time"] as? Double, let text = seg["text"] as? String else { continue }
            for s in detector.ingest(text: text, timestamp: t) {
                if case .sold(let buyer, let price) = s.kind {
                    sold.append((t, buyer, price))
                }
            }
        }
        print("R2_ACCEPT: total sold signals = \(sold.count)")

        // For each sale: any sold signal within ±60s; buyer match; full match.
        var aligned = 0, buyerMatched = 0, fullMatched = 0
        var missed: [String] = []
        for sale in sales {
            let near = sold.filter { abs($0.t - sale.tSec) <= 60 }
            if !near.isEmpty { aligned += 1 }
            if near.contains(where: { $0.buyer == sale.winner }) {
                buyerMatched += 1
            }
            if near.contains(where: { $0.buyer == sale.winner && $0.price == sale.price }) {
                fullMatched += 1
            } else if near.isEmpty {
                missed.append("no=\(sale.no) \(sale.winner) ¥\(sale.price) @\(sale.tSec)")
            }
        }

        let total = sales.count
        let summary = """
        R2_ACCEPT: total sold signals = \(sold.count)
        R2_ACCEPT: aligned=\(aligned)/\(total) (\(aligned * 100 / total)%)
        R2_ACCEPT: buyerMatched=\(buyerMatched)/\(total)
        R2_ACCEPT: fullMatched=\(fullMatched)/\(total)
        R2_ACCEPT: no-signal sales: \(missed.prefix(12).joined(separator: " | "))
        """
        print(summary)
        try? summary.write(to: URL(fileURLWithPath: "/tmp/r2_accept.txt"),
                           atomically: true, encoding: .utf8)

        // Design R2 acceptance: signal times align with t_sec. Keep a
        // conservative floor — exact rate is reported above for calibration.
        XCTAssertGreaterThanOrEqual(aligned * 100 / total, 60,
                                    "成交信号时刻对齐率过低")
    }
}
