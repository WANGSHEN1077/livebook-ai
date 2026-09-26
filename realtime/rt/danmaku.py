"""弹幕出价解析器（移植 Swift R1 DanmakuBidParser）。

规则：
- "-------------" 分隔线 = 成交边界（结算当前窗口，开新窗口）；
- 出价行：`发送者 数字` / `发送者:数字元` / 纯数字（归属最近发言者）；
- 主播/系统/礼物行不参与；
- 窗口内价格单调递增；同(发送者,价格)去重。
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Optional

from . import buyers
from .buyers import canonical_buyer, is_host, is_system_line, cjk_number, normalize

SEPARATOR_RE = re.compile(r"[-=－—＿~]{4,}")
DIGIT_RE = re.compile(r"\d+")
CJK_NUM_RE = re.compile(r"[零一二两三四五六七八九十百千]+")


@dataclass
class DanmakuBid:
    sender: str
    price: int
    t: float


@dataclass
class DanmakuWindow:
    id: int
    start: float
    end: Optional[float] = None
    bids: list = field(default_factory=list)  # list[DanmakuBid]

    @property
    def buyer(self) -> str | None:
        return self.bids[-1].sender if self.bids else None

    @property
    def price(self) -> int | None:
        return self.bids[-1].price if self.bids else None


class DanmakuBidParser:
    def __init__(self, speaker_window: float = 30.0, max_price: int = 10000,
                 max_settled: int = 500):
        self._speaker_window = speaker_window
        self._max_price = max_price
        self._max_settled = max_settled
        self._current: DanmakuWindow | None = None
        self._settled: list[DanmakuWindow] = []
        self._last_speaker: str | None = None
        self._last_speaker_t: float = -1e9
        self._window_seq = 0

    def reset(self) -> None:
        self._current = None
        self._settled = []
        self._last_speaker = None
        self._last_speaker_t = -1e9

    @staticmethod
    def is_separator(text: str) -> bool:
        t = text.strip()
        if len(t) < 4:
            return False
        dash = "".join(ch for ch in t if ch in "-=－—＿~")
        if len(dash) < 4:
            return False
        rest = "".join(ch for ch in t if ch not in "-=－—＿~")
        rest_n = normalize(rest)
        if not rest_n:
            return True
        # 允许横线前带主播名（"作者 -------------"）
        return any(normalize(h) and (normalize(h) in rest_n or rest_n in normalize(h))
                   for h in buyers.HOST_NAMES)

    @staticmethod
    def parse_bid(text: str) -> tuple[str | None, int] | None:
        t = text.strip()
        if not t:
            return None
        # 找最后一个数字 token（阿拉伯优先，其次中文数字）
        candidates: list[tuple[int, int, int]] = []  # (start, end, value)
        for m in DIGIT_RE.finditer(t):
            v = int(m.group(0))
            candidates.append((m.start(), m.end(), v))
        for m in CJK_NUM_RE.finditer(t):
            v = cjk_number(m.group(0))
            if v is not None:
                candidates.append((m.start(), m.end(), v))
        if not candidates:
            return None
        start, end, price = max(candidates, key=lambda c: c[0])

        prefix = t[:start].strip()
        for kw in ("出价", "报价", "元", "块"):
            prefix = prefix.replace(kw, "")
        norm = normalize(prefix)
        if not norm:
            return (None, price)  # 纯数字 → 归属最近发言者
        # 名字须含汉字或字母
        has_name = any("\u4e00" <= ch <= "\u9fff" or ch.isalpha() for ch in norm)
        if not has_name or len(norm) > 16:
            return (None, price)
        return (norm, price)

    def ingest(self, text: str, t: float) -> list[str]:
        """返回事件标记列表："bid" / "settled"。"""
        events: list[str] = []

        if self.is_separator(text):
            if self._current is not None and self._current.bids:
                self._current.end = t
                self._settled.append(self._current)
                events.append("settled")
                if len(self._settled) > self._max_settled:
                    del self._settled[: self._max_settled // 2]
            self._window_seq += 1
            self._current = DanmakuWindow(id=self._window_seq, start=t)
            return events

        if is_system_line(text):
            return events

        parsed = self.parse_bid(text)
        if not parsed:
            return events
        raw_sender, price = parsed
        if not (1 <= price <= self._max_price):
            return events

        if raw_sender is not None:
            if is_host(raw_sender):
                return events
            sender = canonical_buyer(raw_sender) or raw_sender
            self._last_speaker = sender
            self._last_speaker_t = t
        else:
            if self._last_speaker is None or t - self._last_speaker_t > self._speaker_window:
                return events
            sender = self._last_speaker

        if self._current is None:
            self._window_seq += 1
            self._current = DanmakuWindow(id=self._window_seq, start=t)
        win = self._current
        if win.bids and price <= win.bids[-1].price:
            return events  # 非递增
        if any(b.sender == sender and b.price == price for b in win.bids):
            return events  # 去重
        win.bids.append(DanmakuBid(sender=sender, price=price, t=t))
        events.append("bid")
        return events

    def snapshot(self) -> tuple[DanmakuWindow | None, list[DanmakuWindow]]:
        return (self._current, list(reversed(self._settled)))
