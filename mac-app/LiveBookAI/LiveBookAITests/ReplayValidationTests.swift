import XCTest
@testable import LiveBookAI

/// Integration test: runs OCR against the actual 0813 replay file.
/// Opt-in via env `LIVEBOOK_VALIDATION=1` to avoid long runtime in normal CI.
final class ReplayValidationTests: XCTestCase {
    /// Replay video locations, checked in order: env override (`LIVEBOOK_REPLAY`),
    /// then the workspace copy, then the ~/Downloads copy (which may have been
    /// cleaned up to free disk space). Paths are built from the current user's
    /// home directory — no hardcoded personal paths.
    static var replayCandidates: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["LIVEBOOK_REPLAY"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates.append(URL(fileURLWithPath: home + "/Documents/livebook-ai/mac-app/LiveBookAI/media/直播回放-08月13日.mp4"))
        candidates.append(URL(fileURLWithPath: home + "/Downloads/直播回放-08月13日.mp4"))
        return candidates
    }

    static func firstExistingReplay() -> URL? {
        replayCandidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard Self.firstExistingReplay() != nil else {
            throw XCTSkip("回放文件不存在，跳过基准校验")
        }
    }

    func testValidationAgainst0813Replay() async throws {
        guard let videoURL = Self.firstExistingReplay() else {
            throw XCTSkip("回放文件不存在")
        }
        let items = try GroundTruthLoader.load()
        let runner = ValidationRunner()
        let summary = try await runner.run(items: items, videoURL: videoURL)

        // Log each result.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(summary) {
            print("VALIDATION_SUMMARY_START")
            print(String(data: data, encoding: .utf8) ?? "")
            print("VALIDATION_SUMMARY_END")
        }

        print("MATCH_RATE: \(summary.matched)/\(summary.total) (\(String(format: "%.1f%%", Double(summary.matched) / Double(summary.total) * 100)))")
        for result in summary.results where !result.matched {
            print("MISSED: no=\(result.no) expected=\(result.expectedTitle) sampleCount=\(result.sampleCount) ocr=\(String(result.bestOCR.prefix(120))) transcript=\(String((result.transcriptText ?? "").prefix(120)))")
        }
        for result in summary.results where result.transcriptMatched {
            print("TRANSCRIPT_HIT: no=\(result.no) expected=\(result.expectedTitle)")
        }

        var lines: [String] = []
        lines.append("MATCH_RATE: \(summary.matched)/\(summary.total) (\(String(format: "%.1f%%", Double(summary.matched) / Double(summary.total) * 100)))")
        for result in summary.results where !result.matched {
            let s = result.transcriptText ?? ""
                lines.append("MISSED: no=\(result.no) expected=\(result.expectedTitle) sampleCount=\(result.sampleCount) ocr=\(String(result.bestOCR.prefix(120))) transcript=\(String(s.prefix(120)))")
        }
        for result in summary.results where result.transcriptMatched {
            lines.append("TRANSCRIPT_HIT: no=\(result.no) expected=\(result.expectedTitle)")
        }
        let out = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        try? out.write(to: URL(fileURLWithPath: "/tmp/sherpa_report.txt"))

        // Assert a reasonable floor so regressions get caught (not 100% — OCR is imperfect).
        XCTAssertGreaterThanOrEqual(summary.matched, summary.total / 2,
                                     "基准校验命中率过低")
    }
}
