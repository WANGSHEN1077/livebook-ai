import Foundation

/// Real-time danmaku bid parser (R1): turns OCR lines from the danmaku column
/// into bid ladders.
///
/// Rules (design §3.2):
/// - separator lines (`------`, `====`, …) close the current auction window;
/// - bid lines: `<sender> <number>` / `<sender>:<number>元` / pure numbers
///   (attributed to the most recent speaker);
/// - host (主播/作者) and system/gift lines never become bids;
/// - prices must be monotonic within a window; identical (sender, price) is
///   deduplicated.
///
/// Thread-safe (NSLock); feed from the OCR queue, read snapshots on main.
final class DanmakuBidParser: @unchecked Sendable {
    /// Maximum age (s) of the last speaker for attributing bare-number bids.
    private let speakerWindow: Double
    /// Maximum accepted price.
    private let maxPrice: Int
    /// Cap on retained settled windows.
    private let maxSettled: Int

    private let lock = NSLock()
    private var currentWindow: DanmakuWindow?
    private var settled: [DanmakuWindow] = []
    private var lastSpeaker: String?
    private var lastSpeakerTime: Double = -.infinity

    init(speakerWindow: Double = 30, maxPrice: Int = 10000, maxSettled: Int = 500) {
        self.speakerWindow = speakerWindow
        self.maxPrice = maxPrice
        self.maxSettled = maxSettled
    }

    // MARK: - Ingestion

    /// Ingests one OCR line from the danmaku column. Returns the events the
    /// line produced (a bid and/or a settled window).
    @discardableResult
    func ingest(text: String, timestamp: Double) -> [DanmakuBidParserEvent] {
        lock.lock()
        defer { lock.unlock() }
        var events: [DanmakuBidParserEvent] = []

        // 1. Separator → close current window, open a new one.
        if Self.isSeparator(text) {
            if let win = currentWindow {
                var w = win
                w.endTime = timestamp
                settled.append(w)
                events.append(.windowSettled(w))
                if settled.count > maxSettled { settled.removeFirst(maxSettled / 2) }
            }
            currentWindow = DanmakuWindow(id: UUID(), startTime: timestamp, endTime: nil, bids: [])
            return events
        }

        // 2. System/gift lines → ignore.
        if BuyerCatalog.isSystemLine(text) { return events }

        // 3. Parse the bid.
        guard let (senderRaw, price) = Self.parseBid(text) else { return events }
        guard price >= 1, price <= maxPrice else { return events }

        // 4. Resolve sender.
        let sender: String
        if let raw = senderRaw {
            if BuyerCatalog.isHost(raw) { return events }
            sender = BuyerCatalog.canonicalBuyer(for: raw) ?? raw
            lastSpeaker = sender
            lastSpeakerTime = timestamp
        } else {
            // Bare number → attribute to the most recent speaker.
            guard let ls = lastSpeaker, timestamp - lastSpeakerTime <= speakerWindow else { return events }
            sender = ls
        }

        // 5. Monotonic raise + dedup within the window.
        if currentWindow == nil {
            // Lazily open the first window on the first bid (no separator yet).
            currentWindow = DanmakuWindow(id: UUID(), startTime: timestamp, endTime: nil, bids: [])
        }
        guard var win = currentWindow else { return events }
        if let last = win.bids.last, price <= last.price { return events }
        if win.bids.contains(where: { $0.sender == sender && $0.price == price }) { return events }

        let bid = DanmakuBid(id: UUID(), sender: sender, price: price, timestamp: timestamp)
        win.bids.append(bid)
        currentWindow = win
        events.append(.bidAdded(bid))
        return events
    }

    // MARK: - Snapshot

    /// Current in-flight window (bids so far) and settled windows, newest first.
    func snapshot() -> (current: DanmakuWindow?, settled: [DanmakuWindow]) {
        lock.lock()
        defer { lock.unlock() }
        return (currentWindow, settled.reversed())
    }

    func reset() {
        lock.lock()
        currentWindow = nil
        settled = []
        lastSpeaker = nil
        lastSpeakerTime = -.infinity
        lock.unlock()
    }

    // MARK: - Parsing helpers (pure, testable)

    /// Separator line: ≥4 consecutive dash/equal-like characters and no
    /// meaningful text (checks the raw text before normalization).
    static func isSeparator(_ raw: String) -> Bool {
        let dashLike = CharacterSet(charactersIn: "-=－—＿~")
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 4 else { return false }
        let dashCount = t.unicodeScalars.filter { dashLike.contains($0) }.count
        let otherCount = t.unicodeScalars.filter { !dashLike.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }.count
        return dashCount >= 4 && otherCount == 0
    }

    /// Parses a bid line. Returns `(sender, price)`; `sender == nil` means a
    /// bare number that should be attributed to the last speaker.
    static func parseBid(_ text: String) -> (sender: String?, price: Int)? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // Locate the LAST numeric token: Arabic digits, else CJK numerals.
        // `\d+` keeps full digit runs; oversized prices are rejected later by
        // the maxPrice guard in ingest.
        let digitRanges = t.ranges(ofPattern: "\\d+")
        let cjkRanges = t.ranges(ofPattern: "[零一二两三四五六七八九十百千]+")
        let candidates: [(Range<String.Index>, Int)] = digitRanges.compactMap { r in
            guard let v = Int(t[r]) else { return nil }
            return (r, v)
        } + cjkRanges.compactMap { r in
            guard let v = cjkNumber(String(t[r])) else { return nil }
            return (r, v)
        }
        guard let (numRange, price) = candidates.max(by: { $0.0.lowerBound < $1.0.lowerBound }) else {
            return nil
        }

        // Sender = text before the number, stripped of bid verbs/punctuation.
        var prefix = String(t[..<numRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        prefix = prefix.replacingOccurrences(of: "出价", with: "")
            .replacingOccurrences(of: "报价", with: "")
            .replacingOccurrences(of: "元", with: "")
            .replacingOccurrences(of: "块", with: "")

        let normalizedPrefix = TitleMatcher.normalize(prefix)
        // Bare number (nothing but bid verbs before it).
        if normalizedPrefix.isEmpty { return (nil, price) }
        // Name-ish sender: contains CJK or Latin letters.
        let hasName = normalizedPrefix.unicodeScalars.contains { c in
            (0x4E00...0x9FFF).contains(c.value) || CharacterSet.letters.contains(c)
        }
        guard hasName else { return (nil, price) }
        // Sanity: sender names on the danmaku column are short.
        guard normalizedPrefix.count <= 16 else { return nil }
        return (normalizedPrefix, price)
    }

    /// CJK numeral → Int (supports 十/百/千 and 口语 forms like 一百五 = 150).
    static func cjkNumber(_ s: String) -> Int? {
        let digits: [Character: Int] = ["零": 0, "一": 1, "二": 2, "两": 2, "三": 3,
                                        "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
        var total = 0
        var current = 0
        var pendingHundred = false
        var hasDigit = false
        var hasAny = false
        for ch in s {
            if let d = digits[ch] {
                current = d
                hasDigit = true
                hasAny = true
                if pendingHundred {
                    // "X百Y" → Y means tens (一百五 = 150).
                    total += current * 10
                    current = 0
                    pendingHundred = false
                }
            } else if ch == "十" {
                total += (current == 0 ? 1 : current) * 10
                current = 0
                pendingHundred = false
                hasAny = true
            } else if ch == "百" {
                total += (current == 0 ? 1 : current) * 100
                current = 0
                pendingHundred = true
                hasAny = true
            } else if ch == "千" {
                total += (current == 0 ? 1 : current) * 1000
                current = 0
                pendingHundred = false
                hasAny = true
            } else {
                return nil
            }
        }
        guard hasAny else { return nil }
        if hasDigit { total += current }
        return total
    }
}
