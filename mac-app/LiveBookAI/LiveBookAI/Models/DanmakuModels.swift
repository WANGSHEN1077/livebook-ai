import Foundation
import CoreGraphics

// MARK: - Danmaku bid models (R1: 实时弹幕出价解析)

/// One bid parsed from the danmaku column (right side of the live window).
struct DanmakuBid: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    let sender: String
    let price: Int
    /// Media timestamp (seconds) when the bid line was read.
    let timestamp: Double
}

/// A settled auction window with its full bid ladder. The last bid is the
/// winner: `buyer` + `price`.
struct DanmakuWindow: Identifiable, Codable, Sendable {
    let id: UUID
    let startTime: Double
    var endTime: Double?
    var bids: [DanmakuBid]

    var buyer: String? { bids.last?.sender }
    var price: Int? { bids.last?.price }
    var isSettled: Bool { endTime != nil }
}

/// Events emitted by `DanmakuBidParser.ingest`.
enum DanmakuBidParserEvent: Sendable {
    case bidAdded(DanmakuBid)
    case windowSettled(DanmakuWindow)
}

/// Danmaku column region: the right side of the live window.
/// Vision normalized coordinates (origin bottom-left, unit square).
enum DanmakuRegion {
    static let defaultRegion = CGRect(x: 0.72, y: 0.0, width: 0.28, height: 1.0)

    /// Whether an OCR observation belongs to the danmaku column.
    static func contains(_ obs: OCRObservation, region: CGRect = DanmakuRegion.defaultRegion) -> Bool {
        region.contains(CGPoint(x: obs.boundingBox.midX, y: obs.boundingBox.midY))
    }
}

// MARK: - Buyer catalog (决策#2：预置买家名单)

/// Preconfigured buyer catalog: 规范买家名 → 别名（弹幕精确用户名 + 音频 ASR
/// 误识别变体）。全部为虚构示例数据，不含任何真实用户名。
/// Danmaku usernames are exact text; the aliases mainly serve the audio path
/// (R2) but also tolerate small OCR misreads on the danmaku column.
enum BuyerCatalog {
    /// Canonical buyer name -> aliases (exact usernames + ASR misrecognitions).
    /// 别名一律使用小写、无空格无标点的写法（与 `TitleMatcher.normalize` 对齐）。
    static let aliases: [String: [String]] = [
        // —— 弹幕发送者（虚构用户名示例）——
        "买家甲": ["买家甲", "甲老师", "甲先生", "甲"],
        "买家乙": ["买家乙", "乙老师", "乙先生"],
        "买家丙": ["买家丙", "丙老师", "丙先生"],
        "买家丁": ["买家丁", "丁老师", "丁先生"],
        "买家戊": ["买家戊", "戊老师"],
        "买家己": ["买家己", "己老师"],
        "买家庚": ["买家庚", "庚老师", "庚先生"],
        // —— 音频 ASR 别名示例（R2 用；英文规范名 + 中文误识别变体）——
        "buyer_e": ["buyer_e", "buyere", "伊老师", "伊先生"],
    ]

    /// Host / platform account markers — never bidders.
    static let hostNames: Set<String> = ["示例书屋", "作者", "主播"]

    /// Non-bid danmaku lines (system / gift / join notices).
    static let systemKeywords: [String] = [
        "进入直播间", "送出", "礼物", "点赞", "关注", "分享", "订阅",
        "来了", "离开", "上线", "喜欢", "感谢", "欢迎",
    ]

    /// Map a raw sender substring to its canonical buyer name, if known.
    static func canonicalBuyer(for raw: String) -> String? {
        let n = TitleMatcher.normalize(raw)
        guard !n.isEmpty else { return nil }
        // Exact match first.
        for (canonical, aliasList) in aliases {
            if aliasList.contains(where: { $0 == n }) { return canonical }
        }
        // Containment fallback (tolerates small OCR misreads); require both
        // sides reasonably long to avoid over-matching short aliases.
        for (canonical, aliasList) in aliases {
            for alias in aliasList where alias.count >= 2 && n.count >= 2 {
                if n.contains(alias) || alias.contains(n) { return canonical }
            }
        }
        return nil
    }

    /// Whether the sender line belongs to the host (主播/作者).
    static func isHost(_ raw: String) -> Bool {
        let n = TitleMatcher.normalize(raw)
        return hostNames.contains { h in
            let hn = TitleMatcher.normalize(h)
            return !hn.isEmpty && (n.contains(hn) || hn.contains(n))
        }
    }

    /// Whether the line is a system/gift notice rather than a bid.
    static func isSystemLine(_ raw: String) -> Bool {
        let n = TitleMatcher.normalize(raw)
        return systemKeywords.contains { n.contains($0) }
    }
}
