import Foundation

extension String {
    /// All ranges where the given regex matches.
    func ranges(ofPattern pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: ns).compactMap {
            Range($0.range, in: self)
        }
    }
}

/// One settled auction from the live stream, reconstructed from spoken audio
/// + OCR cover text.
struct AuctionRecord: Identifiable, Codable, Sendable {
    let id: UUID
    /// Book title (best OCR cover text at settlement; may be partial).
    var bookTitle: String
    /// Buyer name extracted from "恭喜X老师" style phrases.
    var buyer: String?
    /// Final price (yuan).
    var price: Int?
    /// Stream timestamp when settled.
    let timestamp: Double
    /// Confidence-ish flag: whether a price AND buyer were both found.
    var complete: Bool { buyer != nil && price != nil }
}

/// Parses the live spoken transcript into auction records using a small state
/// machine tuned to the host's auction patter:
///   "五元起拍" -> start;  "X元/X元起拍" -> bids;  "恭喜X老师" -> settle.
/// Cover OCR text is fed separately and used as the current book title.
final class LiveAuctionParser: @unchecked Sendable {
    private let lock = NSLock()

    // ——— Published (read under lock via snapshots) ———
    private var records: [AuctionRecord] = []
    /// Offsets of already-settled "恭喜X老师" markers (dedupe).
    private var settledOffsets: [Int] = []
    private var currentTitle: String = ""
    private var lastSpoken: String = ""

    // ——— OCR book-title candidates (cover region, deduped) ———
    private var coverCandidates: [String] = []
    // ——— Danmaku lines (bottom region, deduped by normalized text) ———
    private var danmakuLines: [String] = []

    // MARK: - Audio (spoken transcript) ingestion

    /// Feed the latest accumulated transcript. Returns newly settled records.
    @discardableResult
    func ingestSpoken(_ text: String, at time: Double) -> [AuctionRecord] {
        let newRecords: [AuctionRecord]
        lock.lock()
        newRecords = parse(text, at: time)
        lastSpoken = text
        lock.unlock()
        return newRecords
    }

    // MARK: - OCR (cover + danmaku) ingestion

    func ingestOCR(_ observations: [OCRObservation], at time: Double, coverRect: CGRect) {
        lock.lock()
        // Cover region (Vision normalized coords, origin bottom-left).
        for obs in observations {
            let midX = obs.boundingBox.midX
            let midY = obs.boundingBox.midY
            if coverRect.contains(CGPoint(x: midX, y: midY)) {
                let trimmed = TitleMatcher.normalize(obs.text)
                if trimmed.count >= 2, !coverCandidates.contains(trimmed) {
                    coverCandidates.append(trimmed)
                }
            } else if obs.boundingBox.maxX > 0.72 {
                // Right-hand region (视频号/douyin style) → danmaku column.
                let n = TitleMatcher.normalize(obs.text)
                if n.count >= 2, !danmakuLines.contains(n) {
                    danmakuLines.append(n)
                    if danmakuLines.count > 200 { danmakuLines.removeFirst(100) }
                }
            }
        }
        // Keep only recent cover candidates.
        if coverCandidates.count > 200 { coverCandidates.removeFirst(100) }
        lock.unlock()
    }

    func snapshot() -> (records: [AuctionRecord], covers: [String], danmaku: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (records, coverCandidates, danmakuLines)
    }

    func clear() {
        lock.lock()
        records = []
        settledOffsets = []
        coverCandidates = []
        danmakuLines = []
        currentTitle = ""
        lastSpoken = ""
        lock.unlock()
    }

    // MARK: - State machine

    private func parse(_ text: String, at time: Double) -> [AuctionRecord] {
        guard !text.isEmpty else { return [] }
        var settled: [AuctionRecord] = []
        let nsText = text as NSString

        // 2) Settle: "恭喜我们?X老师" where X is 1..10 CJK, bounded by 老师.
        let congrats = "恭喜(?:我们)?([\\u4E00-\\u9FA5]{1,10}?)(老师|大使|使)"
        for match in text.ranges(ofPattern: congrats) {
            let absStart = match.lowerBound.utf16Offset(in: text)
            guard !settledOffsets.contains(absStart) else { continue }
            settledOffsets.append(absStart)
            if settledOffsets.count > 500 { settledOffsets.removeFirst(250) }

            var raw = String(text[match])
            raw = raw.replacingOccurrences(of: "恭喜", with: "")
            raw = raw.replacingOccurrences(of: "我们", with: "")
            raw = raw.replacingOccurrences(of: "老师", with: "")
            raw = raw.replacingOccurrences(of: "大使", with: "")
            raw = raw.replacingOccurrences(of: "使", with: "")
            let buyer = raw
            if buyer.isEmpty || buyer.contains("恭喜") || buyer == "谢谢" { continue }

            // Price: nearest explicit current-bid signal before this 恭喜.
            let price = Self.nearestPrice(in: nsText, before: absStart)
            let record = AuctionRecord(id: UUID(),
                                       bookTitle: currentTitle.isEmpty ? "（待识别）" : currentTitle,
                                       buyer: buyer,
                                       price: price,
                                       timestamp: time)
            settled.append(record)
            if !records.contains(where: { $0.id == record.id }) {
                records.append(record)
            }
            if records.count > 200 { records.removeFirst(100) }
        }
        return settled
    }

    /// Scan a window before `offset` for the nearest price signal, in priority
    /// order: X老师N节拍 > 现在出价是N > (在/下/赛)出价是N > N元.
    private static func nearestPrice(in text: NSString, before offset: Int) -> Int? {
        let window = max(0, offset - 220)
        let zone = text.substring(with: NSRange(location: window, length: offset - window))
        let patterns = [
            "老师([0-9一二三四五六七八九十百千万]{1,5}?)(?:元)?节拍",
            "现在出价是([0-9一二三四五六七八九十百千万]+)",
            "(?:在出价是|下次出价是|赛出价是|出价是)([0-9一二三四五六七八九十百千万]+)",
            "([0-9一二三四五六七八九十百千万]+)\\s*元"
        ]
        var best: (Int, Int)? // (endOffset, value)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: zone, range: NSRange(location: 0, length: (zone as NSString).length))
            for m in matches {
                guard m.numberOfRanges >= 2 else { continue }
                let num = (zone as NSString).substring(with: m.range(at: 1))
                if let v = toInt(num) {
                    let end = window + m.range.location + m.range.length
                    if best == nil || end > best!.0 {
                        best = (end, v)
                    }
                }
            }
        }
        return best?.1
    }

    /// Extract book title candidates from the host's spoken description.
    /// Heuristic: a run of Chinese characters between auction cues.
    func inferTitle(from text: String) -> String? {
        let n = TitleMatcher.normalize(text)
        guard n.count >= 2 else { return nil }
        // Candidate: substring of >=3 chars not containing common cue words.
        let cues = ["起拍", "棋拍", "老师", "这本书", "看一下", "有没有", "可以出价"]
        for cue in cues where n.contains(cue) { return nil }
        return n
    }

    private static func toInt(_ s: String) -> Int? {
        if let v = Int(s) { return v }
        let map: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3, "四": 4,
                                    "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        let chs = Array(s)
        if chs.allSatisfy({ map[$0] != nil }) {
            var val = 0
            for ch in chs { val = val * 10 + (map[ch] ?? 0) }
            return val
        }
        // Handle 十/百 forms minimally.
        if let shi = s.firstIndex(of: "十") {
            let before = String(s[..<shi])
            let after = String(s[s.index(after: shi)...])
            let b = before.isEmpty ? 1 : toInt(before) ?? 1
            let a = after.isEmpty ? 0 : toInt(after) ?? 0
            return b * 10 + a
        }
        return nil
    }
}