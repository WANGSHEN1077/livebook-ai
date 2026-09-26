import Foundation

/// A settlement signal detected from streaming ASR text (R2).
struct SettlementSignal: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        /// A sale closed. buyer/price may be nil when the audio alone could
        /// not determine them (the fuser falls back to the danmaku ladder).
        case sold(buyer: String?, price: Int?)
        /// The lot passed (no sale).
        case passed
    }
    let kind: Kind
    /// Approximate media time of the signal (seconds).
    let timestamp: Double
}

/// Detects auction settlement signals in streaming ASR text.
///
/// Ported from speech2text `fusion_pipeline_v7` (validated on 0807–0813):
/// - settle homophone set {结拍/节拍/接拍/截拍/解拍};
/// - countdown `[五无]四三二一` followed by `恭喜<买家>`;
/// - passed keywords {没人要/流了/流标/没人拍/下一本/撤拍};
/// - Chinese price dictionary + Arabic prices (30–2000), nearest before the
///   signal;
/// - buyer extraction priority: 恭喜(信号后30字) → 价格前35字 → 信号前60字,
///   using the preconfigured `BuyerCatalog` aliases.
///
/// Streaming-safe: keeps a rolling character window with per-char times and
/// deduplicates by absolute character offset. Thread-safe (NSLock).
final class SettlementSignalDetector: @unchecked Sendable {
    /// 口语中文价格词典（来自 fusion_pipeline_v7 PRICE_CN + 常用十位）。
    static let priceWords: [String: Int] = [
        "一千": 1000, "两千": 2000,
        "一百八": 180, "一百九": 190, "两百六": 260, "二百六": 260,
        "两百八": 280, "二百八": 280, "一百五": 150, "一百三": 130,
        "一百二": 120, "一百一": 110, "两百五": 250, "二百五": 250,
        "一百二十": 120, "一百三十": 130, "一百一十": 110, "一百五十": 150,
        "两百": 200, "二百": 200, "三百": 300, "五百": 500, "八百": 800,
        "一百": 100, "五十": 50, "五十五": 55, "六十": 60, "六十五": 65,
        "七十": 70, "七十五": 75, "八十": 80, "八十五": 85, "九十": 90,
        "九十五": 95, "三十": 30, "四十": 40, "二十": 20, "十": 10,
    ]
    /// 结拍谐音信号集。
    static let settleSignals = ["结拍", "节拍", "接拍", "截拍", "解拍"]
    /// 流拍关键词（规格 §17）。
    static let passedKeywords = ["没人要", "流了", "流标", "没人拍", "下一本", "撤拍"]

    private let lock = NSLock()
    private var chars: [Character] = []
    private var times: [Double] = []
    private var baseOffset = 0
    private var settledOffsets: Set<Int> = []
    private let maxWindow = 600
    private let maxOffsets = 500

    /// Ingests the incremental transcript text (new characters only).
    /// Returns signals found in the rolling window.
    @discardableResult
    func ingest(text: String, timestamp: Double) -> [SettlementSignal] {
        lock.lock()
        defer { lock.unlock() }
        guard !text.isEmpty else { return [] }
        for ch in text {
            chars.append(ch)
            times.append(timestamp)
        }
        if chars.count > maxWindow {
            let excess = chars.count - maxWindow
            chars.removeFirst(excess)
            times.removeFirst(excess)
            baseOffset += excess
        }
        let full = String(chars)
        var signals: [SettlementSignal] = []
        // Global offsets of settle/countdown anchors: a 恭喜 within ±30 chars
        // of one is the buyer-extractor for that anchor, not a new signal.
        var anchors: [Int] = []

        // 1. Settle homophones.
        for sig in Self.settleSignals {
            var searchRange = full.startIndex..<full.endIndex
            while let r = full.range(of: sig, range: searchRange) {
                searchRange = r.upperBound..<full.endIndex
                guard !markSeen(full: full, at: r.lowerBound) else { continue }
                anchors.append(baseOffset + full.distance(from: full.startIndex, to: r.lowerBound))
                if let sold = Self.extractSold(full: full, signalRange: r) {
                    signals.append(SettlementSignal(kind: .sold(buyer: sold.buyer, price: sold.price),
                                                    timestamp: timestamp))
                }
            }
        }

        // 2. Countdown (五/无)四三二一 → 恭喜<买家>. The 五/无 prefix is
        // optional — the 0813 session counts down with bare 四三二一.
        if let regex = try? NSRegularExpression(pattern: "[五无]?四三二一") {
            let ns = NSRange(full.startIndex..., in: full)
            for m in regex.matches(in: full, range: ns) {
                guard let r = Range(m.range, in: full) else { continue }
                guard !markSeen(full: full, at: r.lowerBound) else { continue }
                anchors.append(baseOffset + full.distance(from: full.startIndex, to: r.lowerBound))
                if let sold = Self.extractSold(full: full, signalRange: r) {
                    signals.append(SettlementSignal(kind: .sold(buyer: sold.buyer, price: sold.price),
                                                    timestamp: timestamp))
                }
            }
        }

        // 3. Passed keywords.
        for kw in Self.passedKeywords {
            var searchRange = full.startIndex..<full.endIndex
            while let r = full.range(of: kw, range: searchRange) {
                searchRange = r.upperBound..<full.endIndex
                guard !markSeen(full: full, at: r.lowerBound) else { continue }
                signals.append(SettlementSignal(kind: .passed, timestamp: timestamp))
            }
        }

        // 4. Standalone 恭喜<买家> settle marker — the dominant closing form
        // in the 0813 Chinese session ("恭喜我们丁老师", "好的恭喜甲老师").
        // Skipped when within ±30 chars of a settle/countdown anchor (that
        // anchor already consumed it as its buyer extractor).
        if let regex = try? NSRegularExpression(pattern: "恭喜(?:我们)?([^，。！？\\s]{1,12})") {
            let ns = NSRange(full.startIndex..., in: full)
            for m in regex.matches(in: full, range: ns) {
                guard m.numberOfRanges >= 2,
                      let fullRange = Range(m.range, in: full),
                      let nameRange = Range(m.range(at: 1), in: full) else { continue }
                let gongxiStart = full.distance(from: full.startIndex, to: fullRange.lowerBound)
                let global = baseOffset + gongxiStart
                if anchors.contains(where: { abs(global - $0) <= 30 }) { continue }
                guard !settledOffsets.contains(global) else { continue }
                settledOffsets.insert(global)
                let name = String(full[nameRange])
                if let sold = Self.extractSoldFromGongxi(full: full, gongxiStart: gongxiStart, name: name) {
                    signals.append(SettlementSignal(kind: .sold(buyer: sold.buyer, price: sold.price),
                                                    timestamp: timestamp))
                }
            }
        }

        if settledOffsets.count > maxOffsets {
            settledOffsets = Set(settledOffsets.sorted().suffix(maxOffsets / 2))
        }
        return signals
    }

    func reset() {
        lock.lock()
        chars = []
        times = []
        baseOffset = 0
        settledOffsets = []
        lock.unlock()
    }

    // MARK: - Internal

    private func markSeen(full: String, at index: String.Index) -> Bool {
        let lo = full.distance(from: full.startIndex, to: index)
        let global = baseOffset + lo
        guard !settledOffsets.contains(global) else { return true }
        settledOffsets.insert(global)
        return false
    }

    // MARK: - Extraction (pure, testable)

    private struct ExtractedSold {
        let buyer: String?
        let price: Int?
    }

    /// 在"恭喜<买家>"信号处提取：买家 = 捕获组里的名字（找别名），
    /// 价格 = 信号前 120 字内最近价格。
    private static func extractSoldFromGongxi(full: String, gongxiStart: Int, name: String) -> ExtractedSold? {
        let buyer = findBuyer(in: name, allowSingleChar: false)
        let preStart = max(0, gongxiStart - 120)
        let pre = String(full[full.index(full.startIndex, offsetBy: preStart)..<full.index(full.startIndex, offsetBy: gongxiStart)])
        let prices = findPrices(in: pre)
        guard buyer != nil || prices.last != nil else { return nil }
        return ExtractedSold(buyer: buyer, price: prices.last?.value)
    }

    /// 在信号位置提取 (price, buyer)：
    /// - 价格：信号前 120 字内的最近价格（价格词典 + 阿拉伯 30–2000）；
    /// - 买家优先级：信号后 30 字内恭喜 → 价格位置前 35 字 → 信号前 60 字。
    private static func extractSold(full: String, signalRange: Range<String.Index>) -> ExtractedSold? {
        let signalStart = full.distance(from: full.startIndex, to: signalRange.lowerBound)
        let preStart = max(0, signalStart - 120)
        let pre = String(full[full.index(full.startIndex, offsetBy: preStart)..<signalRange.lowerBound])
        let prices = findPrices(in: pre)
        var buyer: String?

        // 恭喜 in the 30 chars after the signal (countdown style).
        let afterCount = min(30, full.distance(from: signalRange.lowerBound, to: full.endIndex))
        if afterCount > 0 {
            let after = String(full[signalRange.lowerBound..<full.index(signalRange.lowerBound, offsetBy: afterCount)])
            if let gongxi = after.range(of: "恭喜") {
                let ctxCount = min(20, after.distance(from: gongxi.upperBound, to: after.endIndex))
                if ctxCount > 0 {
                    let ctx = String(after[gongxi.upperBound..<after.index(gongxi.upperBound, offsetBy: ctxCount)])
                    buyer = findBuyer(in: ctx, allowSingleChar: true)
                }
            }
        }

        // 35 chars before the nearest price.
        if buyer == nil, let lastPrice = prices.last {
            let priceAbs = preStart + lastPrice.offset
            let ctxLo = max(0, priceAbs - 35)
            if ctxLo < priceAbs {
                let ctx = String(full[full.index(full.startIndex, offsetBy: ctxLo)..<full.index(full.startIndex, offsetBy: priceAbs)])
                buyer = findBuyer(in: ctx, allowSingleChar: false)
            }
        }

        // 60 chars before the signal.
        if buyer == nil {
            let pre60Start = max(0, signalStart - 60)
            let ctx = String(full[full.index(full.startIndex, offsetBy: pre60Start)..<signalRange.lowerBound])
            buyer = findBuyer(in: ctx, allowSingleChar: false)
        }

        guard buyer != nil || prices.last != nil else { return nil }
        return ExtractedSold(buyer: buyer, price: prices.last?.value)
    }

    /// 价格词典 + 阿拉伯数字 + 通用中文数字（30–2000 → 放宽到 2–2000，
    /// 因为中文专场有 5/10/15 元起拍），返回相对 `text` 起点的位置列表。
    static func findPrices(in text: String) -> [(offset: Int, value: Int)] {
        guard !text.isEmpty else { return [] }
        var found: [(start: Int, end: Int, value: Int)] = []
        // 1. 口语价格词典（如 一百五=150）。
        for word in priceWords.keys.sorted(by: { $0.count > $1.count }) {
            guard let value = priceWords[word] else { continue }
            var searchRange = text.startIndex..<text.endIndex
            while let r = text.range(of: word, range: searchRange) {
                let start = text.distance(from: text.startIndex, to: r.lowerBound)
                let end = start + word.count
                found.append((start, end, value))
                searchRange = r.upperBound..<text.endIndex
            }
        }
        // 2. 阿拉伯数字（2–2000）。
        if let regex = try? NSRegularExpression(pattern: "(?<!\\d)(\\d{1,4})(?!\\d)") {
            let ns = NSRange(text.startIndex..., in: text)
            for m in regex.matches(in: text, range: ns) {
                guard let r = Range(m.range, in: text) else { continue }
                let sub = String(text[r])
                guard let v = Int(sub), v >= 2, v <= 2000 else { continue }
                let start = text.distance(from: text.startIndex, to: r.lowerBound)
                found.append((start, start + sub.count, v))
            }
        }
        // 3. 通用中文数字（十五=15、三十=30、一百五=150…）。
        let cjkRanges = text.ranges(ofPattern: "[零一二两三四五六七八九十百千]+")
        for r in cjkRanges {
            guard let v = DanmakuBidParser.cjkNumber(String(text[r])), v >= 2, v <= 2000 else { continue }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            let end = start + text[r].count
            found.append((start, end, v))
        }
        // 去重叠：同位置保留最长（长词优先）。
        found.sort { ($0.start, -$0.end) < ($1.start, -$1.end) }
        var deduped: [(start: Int, end: Int, value: Int)] = []
        for f in found {
            if let last = deduped.last, f.start < last.end { continue }
            deduped.append(f)
        }
        return deduped.map { (offset: $0.start, value: $0.value) }
    }

    /// 在上下文里找最后出现的买家别名 → 规范名。
    /// `allowSingleChar`：恭喜上下文允许单字别名（如"常"），其余上下文
    /// 要求别名 ≥2 字以减少误报（如"经常"含"常"）。
    static func findBuyer(in context: String, allowSingleChar: Bool) -> String? {
        var best: (position: Int, canonical: String)?
        for (canonical, aliasList) in BuyerCatalog.aliases {
            for alias in aliasList {
                guard allowSingleChar || alias.count >= 2 else { continue }
                var searchRange = context.startIndex..<context.endIndex
                while let r = context.range(of: alias, range: searchRange) {
                    let pos = context.distance(from: context.startIndex, to: r.lowerBound)
                    searchRange = r.upperBound..<context.endIndex
                    if best == nil || pos > best!.position {
                        best = (pos, canonical)
                    }
                }
            }
        }
        return best?.canonical
    }

    /// Human-readable description for the UI.
    static func describe(_ signal: SettlementSignal) -> String {
        switch signal.kind {
        case .sold(let buyer, let price):
            let b = buyer ?? "?"
            let p = price.map { "¥\($0)" } ?? "?"
            return String(format: "成交 买家:%@ 价格:%@", b, p)
        case .passed:
            return "流拍"
        }
    }
}
