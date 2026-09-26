import XCTest
@testable import LiveBookAI

final class GroundTruthLoaderTests: XCTestCase {
    /// 基准数据只存在于开发机（CSV 与 timed JSON 均不入仓库）。
    /// 仅依赖数据的用例调用它跳过；纯逻辑用例（匹配器等）照常运行。
    private func requireGroundTruthData() throws {
        let csv = GroundTruthLoader.defaultCSVPath
        let timed = GroundTruthLoader.defaultTimedJSONPath
        guard FileManager.default.fileExists(atPath: csv),
              FileManager.default.fileExists(atPath: timed) else {
            throw XCTSkip("本机缺少基准数据（\(csv) / \(timed)），跳过")
        }
    }

    func testLoads51Books() throws {
        try requireGroundTruthData()
        let items = try GroundTruthLoader.load()
        XCTAssertEqual(items.count, 50)  // CSV has 50 rows (timed#43 was removed)
    }

    func testFirstItemMatches() throws {
        try requireGroundTruthData()
        let items = try GroundTruthLoader.load()
        let first = items.first!
        XCTAssertEqual(first.no, 1)
        XCTAssertEqual(first.title, "明清时代庶民文化")
        XCTAssertEqual(first.price, 30)
        // 买家名来自本机 CSV，公开仓库里不校验具体姓名（本机数据缺失时该用例会 skip）。
        XCTAssertFalse(first.buyer.isEmpty)
        XCTAssertEqual(first.tSec, 304, accuracy: 0.1)
    }

    func testNoGapsInSequence() throws {
        try requireGroundTruthData()
        let items = try GroundTruthLoader.load()
        let nos = items.map(\.no)
        XCTAssertEqual(nos, Array(1...50))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try GroundTruthLoader.load(csvPath: "/nonexistent.csv",
                                                        timedJSONPath: "/tmp/sales_0813_timed.json"))
    }

    func testMatcherChineseContainment() {
        XCTAssertTrue(TitleMatcher.matches(ocr: "永乐帝：华夷秩序的完成 檀上寛", expectedTitle: "永乐帝：华夷秩序的完成"))
        XCTAssertTrue(TitleMatcher.matches(ocr: "永乐帝", expectedTitle: "永乐帝：华夷秩序的完成"))
    }

    func testMatcherEnglishContainment() {
        XCTAssertTrue(TitleMatcher.matches(ocr: "SHAKESPEARE, IN FACT Irvin Leigh Matus", expectedTitle: "Shakespeare, In Fact"))
        XCTAssertTrue(TitleMatcher.matches(ocr: "Shakespeare, In Fact", expectedTitle: "Shakespeare, In Fact"))
    }

    func testMatcherNegative() {
        XCTAssertFalse(TitleMatcher.matches(ocr: "Hello World", expectedTitle: "永乐帝：华夷秩序的完成"))
    }
}
