"""融合器状态机（R3）：把三路事件合成 AuctionRecord。

事件源：
- DanmakuBidParser.ingest → "bid" / "settled"（弹幕出价阶梯 + 分隔线边界）
- SettlementSignalDetector.ingest → Signal(kind=sold/passed, buyer, price)

融合规则：
- buyer/price：弹幕阶梯最后一条为主，音频信号兜底；
- book：封面对齐（CoverAligner 输出）兜底；
- 结算触发：音频 sold 信号（优先）或弹幕分隔线 settled；
- 流拍：音频 passed 或窗口内零出价；
- 缺 buyer/price → NEEDS_REVIEW。
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from .records import AuctionRecord, DanmakuBid
from .signals import Signal


@dataclass
class CoverCandidate:
    text: str
    t: float
    confidence: float = 0.0


class AuctionFuser:
    def __init__(self):
        self._records: list[AuctionRecord] = []
        self._no = 0
        # 当前窗口状态
        self._window_start: float | None = None
        self._bids: list[DanmakuBid] = []
        self._covers: list[CoverCandidate] = []
        self._last_sold_t: float | None = None
    def reset(self) -> None:
        self._records = []
        self._no = 0
        self._window_start = None
        self._bids = []
        self._covers = []
        self._last_sold_t = None

    # —— 事件入口 ——

    def on_ocr(self, region: str, text: str, t: float) -> None:
        """封面区 OCR → 书名候选；弹幕区交给 DanmakuBidParser（外部喂入）。"""
        if region == "cover" and text:
            self._covers.append(CoverCandidate(text=text, t=t))
            if len(self._covers) > 200:
                del self._covers[:100]

    def on_danmaku_event(self, event: str, t: float, bid: DanmakuBid | None = None) -> Optional[AuctionRecord]:
        """DanmakuBidParser 的事件。返回产出的记录（若有）。"""
        if event == "bid" and bid is not None:
            if self._window_start is None:
                self._window_start = bid.t
            self._bids.append(bid)
            return None
        if event == "settled":
            return self._settle(t, source="danmaku")
        return None

    def on_signal(self, signal: Signal) -> Optional[AuctionRecord]:
        """SettlementSignalDetector 的信号。"""
        if signal.kind == "sold":
            # 音频兜底：若弹幕窗口没给，用信号里的 buyer/price
            return self._settle(signal.t, source="audio", fallback_buyer=signal.buyer,
                                fallback_price=signal.price)
        if signal.kind == "passed":
            # 成交后 20s 内的"下一本"等是正常衔接，不是流拍
            if self._last_sold_t is not None and signal.t - self._last_sold_t < 20:
                return None
            if not self._bids:
                return self._settle(signal.t, source="audio", status="PASSED")
            return None  # 有出价则以弹幕结算为准
        return None

    # —— 内部 ——

    def _settle(self, t: float, source: str, fallback_buyer: str | None = None,
                fallback_price: int | None = None, status: str = "SOLD") -> AuctionRecord | None:
        # 去重：同 buyer+price 且 30s 内（同一单多信号触发）→ 合并
        buyer = self._bids[-1].sender if self._bids else fallback_buyer
        price = self._bids[-1].price if self._bids else fallback_price
        if self._last_sold_t is not None and t - self._last_sold_t < 30:
            last = self._records[-1] if self._records else None
            if last is not None and last.buyer == buyer and last.price == price:
                return None
        if self._last_sold_t is not None and t - self._last_sold_t < 10:
            return None
        # 无任何信息 → 不产出（PASSED 允许空买家/价格）
        if status != "PASSED" and not self._bids and fallback_buyer is None and fallback_price is None:
            return None

        if status == "SOLD" and (buyer is None or price is None):
            status = "NEEDS_REVIEW"

        book = self._nearest_cover(t)
        # 窗口起点：弹幕首个出价 / 上一条记录结束（音频单通道时窗口连续）
        wstart = self._window_start
        if wstart is None:
            wstart = self._records[-1].window[1] if self._records else max(0.0, t - 60.0)
        self._no += 1
        rec = AuctionRecord(
            no=self._no,
            book=book,
            buyer=buyer,
            price=price,
            bids=list(self._bids),
            window=(wstart, t),
            status=status,
            source=source if not self._bids else ("danmaku" if source == "danmaku" else "both"),
            t=t,
        )
        self._records.append(rec)
        self._last_sold_t = t
        # 开新窗口
        self._bids = []
        self._covers = []
        self._window_start = None
        return rec

    def _nearest_cover(self, t: float, window: float = 300) -> str:
        """窗口内取出现最频繁的封面候选（众数）——翻页内容页是瞬时的，
        封面标题反复出现，众数最稳。"""
        from collections import Counter
        counts: Counter = Counter()
        for c in self._covers:
            dt = t - c.t
            if 0 <= dt <= window:
                counts[c.text] += 1
        if not counts:
            return "（待识别）"
        return counts.most_common(1)[0][0]

    @property
    def records(self) -> list[AuctionRecord]:
        return list(self._records)
