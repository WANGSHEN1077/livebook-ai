import Foundation

/// One expected book from the 0813 ground-truth dataset.
struct GroundTruthItem: Codable, Identifiable, Sendable {
    var id: Int { no }
    /// Book number in the CSV (1-based, already mapped from timed_no).
    let no: Int
    /// Expected book title.
    let title: String
    /// Timestamp (s) when the book was shown / auction started.
    let t0: Double
    /// Timestamp (s) of the settlement event.
    let tSec: Double
    /// Buyer from the sales record (informational).
    let buyer: String
    /// Final price.
    let price: Int
}

/// Result of validating OCR against one ground-truth item.
struct ValidationResult: Codable, Sendable {
    let no: Int
    let expectedTitle: String
    var matched: Bool
    var bestOCR: String
    var bestConfidence: Float
    var sampleCount: Int
    var isbnFound: String?
    /// Spoken-transcript text recovered for OCR-missed books (best effort).
    var transcriptText: String?
    /// Whether the transcript channel matched the expected title.
    var transcriptMatched: Bool
    var elapsedSeconds: Double
    var error: String?
}

/// Per-book validation outcome summary (for UI).
struct ValidationSummary: Codable, Sendable {
    let total: Int
    let matched: Int
    let failed: Int
    let startedAt: Date
    let duration: TimeInterval
    var results: [ValidationResult]
}

enum GroundTruthError: Error, LocalizedError {
    case fileNotFound(String)
    case parseFailed(String)
    case noItems

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let p): return "文件不存在: \(p)"
        case .parseFailed(let d): return "解析失败: \(d)"
        case .noItems: return "基准数据为空"
        }
    }
}

/// Loads the 0813 ground truth from CSV (title) + timed JSON (no/t_sec/t0/buyer/price).
///
/// Mapping rule (verified against buyer/price): timed_no == csv row number for no <= 42,
/// and timed_no == csv row number + 1 for no >= 43 (the old timed#43 was removed from the CSV).
enum GroundTruthLoader {
    /// 基准 CSV 路径：优先取环境变量 `LIVEBOOK_DANMU_CSV`，否则回落到当前
    /// 用户主目录下的本地数据目录（避免硬编码个人绝对路径）。
    static var defaultCSVPath: String {
        if let override = ProcessInfo.processInfo.environment["LIVEBOOK_DANMU_CSV"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Documents/danmu/0813.csv"
    }

    static let defaultTimedJSONPath = "/tmp/sales_0813_timed.json"

    static func load(csvPath: String = defaultCSVPath,
                     timedJSONPath: String = defaultTimedJSONPath) throws -> [GroundTruthItem] {
        guard FileManager.default.fileExists(atPath: csvPath) else {
            throw GroundTruthError.fileNotFound(csvPath)
        }
        guard FileManager.default.fileExists(atPath: timedJSONPath) else {
            throw GroundTruthError.fileNotFound(timedJSONPath)
        }

        let titles = try parseTitles(csvPath: csvPath)
        let timed = try parseTimed(jsonPath: timedJSONPath)
        let t0s = try parseT0s(timed: timed)

        var items: [GroundTruthItem] = []
        for (index, title) in titles.enumerated() {
            let csvNo = index + 1
            // Map CSV row back to timed_no.
            let timedNo = csvNo <= 42 ? csvNo : csvNo + 1
            guard let timedEntry = timed[timedNo],
                  let t0 = t0s[timedNo] else { continue }
            items.append(GroundTruthItem(no: csvNo,
                                         title: title,
                                         t0: t0,
                                         tSec: timedEntry.tSec,
                                         buyer: timedEntry.buyer,
                                         price: timedEntry.price))
        }
        guard !items.isEmpty else { throw GroundTruthError.noItems }
        return items
    }

    // MARK: - Private

    private struct TimedEntry {
        let tSec: Double
        let buyer: String
        let price: Int
    }

    private static func parseTitles(csvPath: String) throws -> [String] {
        let raw = try String(contentsOfFile: csvPath, encoding: .utf8)
        let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.count > 1 else { throw GroundTruthError.parseFailed("CSV 无数据行") }
        // Header: 书名,买家,成交价
        var titles: [String] = []
        for line in lines.dropFirst() {
            // Use a lightweight CSV split that respects quoted fields.
            let fields = splitCSV(line)
            guard let title = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { continue }
            titles.append(title)
        }
        return titles
    }

    private static func parseTimed(jsonPath: String) throws -> [Int: TimedEntry] {
        let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
        let decoded = try JSONDecoder().decode([TimedJSONEntry].self, from: data)
        var result: [Int: TimedEntry] = [:]
        for entry in decoded {
            result[entry.no] = TimedEntry(tSec: entry.tSec, buyer: entry.winner, price: entry.price)
        }
        return result
    }

    private struct TimedJSONEntry: Decodable {
        let no: Int
        let tSec: Double
        let winner: String
        let price: Int

        enum CodingKeys: String, CodingKey {
            case no, winner, price
            case tSec = "t_sec"
        }
    }

    private static func parseT0s(timed: [Int: TimedEntry]) throws -> [Int: Double] {
        // t0 is carried in books_0813b.json; if unavailable, fall back to tSec - 40.
        let path = "/tmp/books_0813b.json"
        guard FileManager.default.fileExists(atPath: path) else {
            return Dictionary(uniqueKeysWithValues: timed.map { ($0.key, $0.value.tSec - 40) })
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoded = try JSONDecoder().decode([BooksEntry].self, from: data)
        var result: [Int: Double] = [:]
        for entry in decoded {
            result[entry.no] = entry.t0
        }
        return result
    }

    private struct BooksEntry: Decodable {
        let no: Int
        let t0: Double
    }

    /// Splits a single CSV line into fields, honoring double-quoted values.
    private static func splitCSV(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        for ch in line {
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == ",", !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        fields.append(current)
        return fields
    }
}
