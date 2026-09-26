"""成交信号检测器（实时流式版，移植 fusion_pipeline_v7 + Swift R2）。

信号集：
- 结拍谐音 {结拍/节拍/接拍/截拍/解拍}
- 倒计时 [五无]?四三二一（0813 是裸"四三二一"）
- 独立"恭喜(我们)<买家>"（0813 中文场主收尾形式；锚点信号 ±30 字内去重）
- 流拍 {没人要/流了/流标/没人拍/下一本/撤拍}

价格：口语词典 + 通用中文数字 + 阿拉伯（2–2000），取信号前最近。
买家：恭喜后 / 价格前 35 字 / 信号前 60 字，优先级递减。

流式安全：滚动字符窗口（deque）+ 按绝对偏移去重；每个 ingest 喂增量文本。
"""
from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass
from typing import Optional

from . import buyers
from .buyers import canonical_buyer, cjk_number

# 口语价格词典（fusion_pipeline_v7 PRICE_CN + 常用十位）
PRICE_WORDS: dict[str, int] = {
    "一千": 1000, "两千": 2000,
    "一百八": 180, "一百九": 190, "两百六": 260, "二百六": 260,
    "两百八": 280, "二百八": 280, "一百五": 150, "一百三": 130,
    "一百二": 120, "一百一": 110, "两百五": 250, "二百五": 250,
    "一百二十": 120, "一百三十": 130, "一百一十": 110, "一百五十": 150,
    "两百": 200, "二百": 200, "三百": 300, "五百": 500, "八百": 800,
    "一百": 100, "五十": 50, "五十五": 55, "六十": 60, "六十五": 65,
    "七十": 70, "七十五": 75, "八十": 80, "八十五": 85, "九十": 90,
    "九十五": 95, "三十": 30, "四十": 40, "二十": 20, "十": 10,
}

SETTLE_SIGNALS = ["结拍", "节拍", "接拍", "截拍", "解拍"]
PASSED_KEYWORDS = ["没人要", "流了", "流标", "没人拍", "下一本", "撤拍"]
COUNTDOWN_RE = re.compile(r"[五无]?四三二一")
GONGXI_RE = re.compile(r"恭喜(?:我们)?([^，。！？\s]{1,12})")
ARABIC_RE = re.compile(r"(?<!\d)(\d{1,4})(?!\d)")
CJK_RE = re.compile(r"[零一二两三四五六七八九十百千]+")


@dataclass
class Signal:
    kind: str                    # "sold" / "passed"
    t: float
    buyer: Optional[str] = None
    price: Optional[int] = None

    def describe(self) -> str:
        if self.kind == "passed":
            return "流拍"
        return f"成交 买家:{self.buyer or '?'} 价格:{('¥' + str(self.price)) if self.price is not None else '?'}"


PRICE_TIME_WINDOW = 25.0  # 价格提取：信号前 25 秒（流式词级转写下，字符窗口会跨太远）


class SettlementSignalDetector:
    def __init__(self, max_window: int = 600, max_offsets: int = 500):
        self._chars: deque[str] = deque()
        self._times: deque[float] = deque()
        self._base = 0                  # chars[0] 的全局偏移
        self._seen: set[int] = set()
        self._max_window = max_window
        self._max_offsets = max_offsets

    def reset(self) -> None:
        self._chars.clear()
        self._times.clear()
        self._base = 0
        self._seen.clear()

    def ingest(self, text: str, t: float) -> list[Signal]:
        if not text:
            return []
        for ch in text:
            self._chars.append(ch)
            self._times.append(t)
        while len(self._chars) > self._max_window:
            self._chars.popleft()
            self._times.popleft()
            self._base += 1
        full = "".join(self._chars)
        signals: list[Signal] = []
        anchors: list[int] = []

        # 1) 结拍谐音
        for sig in SETTLE_SIGNALS:
            for m in re.finditer(sig, full):
                if self._seen_global(full, m.start()):
                    continue
                anchors.append(self._base + m.start())
                sold = self._extract_sold(full, m.start())
                if sold:
                    signals.append(Signal("sold", t, sold[0], sold[1]))

        # 2) 倒计时
        for m in COUNTDOWN_RE.finditer(full):
            if self._seen_global(full, m.start()):
                continue
            anchors.append(self._base + m.start())
            sold = self._extract_sold(full, m.start())
            if sold:
                signals.append(Signal("sold", t, sold[0], sold[1]))

        # 3) 流拍
        for kw in PASSED_KEYWORDS:
            for m in re.finditer(kw, full):
                if self._seen_global(full, m.start()):
                    continue
                signals.append(Signal("passed", t))

        # 4) 独立恭喜（±30 字内有锚点则跳过）
        for m in GONGXI_RE.finditer(full):
            global_pos = self._base + m.start()
            if any(abs(global_pos - a) <= 30 for a in anchors):
                continue
            if self._seen_global(full, m.start()):
                continue
            sold = self._extract_gongxi(full, m.start(), m.group(1))
            if sold:
                signals.append(Signal("sold", t, sold[0], sold[1]))

        if len(self._seen) > self._max_offsets:
            self._seen = set(sorted(self._seen)[-self._max_offsets // 2:])
        return signals

    # —— 内部 ——

    def _seen_global(self, full: str, local: int) -> bool:
        g = self._base + local
        if g in self._seen:
            return True
        self._seen.add(g)
        return False

    @staticmethod
    def find_prices(text: str) -> list[tuple[int, int]]:
        """返回 [(offset, value)]，offset 相对 text 起点。"""
        found: list[tuple[int, int, int]] = []  # (start, end, value)
        for word in sorted(PRICE_WORDS, key=len, reverse=True):
            value = PRICE_WORDS[word]
            for m in re.finditer(re.escape(word), text):
                found.append((m.start(), m.end(), value))
        for m in ARABIC_RE.finditer(text):
            v = int(m.group(1))
            if 2 <= v <= 2000:
                found.append((m.start(), m.end(), v))
        for m in CJK_RE.finditer(text):
            v = cjk_number(m.group(0))
            if v is not None and 2 <= v <= 2000:
                found.append((m.start(), m.end(), v))
        # 去重叠：同位置保留最长
        found.sort(key=lambda x: (x[0], -x[1]))
        deduped: list[tuple[int, int, int]] = []
        for f in found:
            if deduped and f[0] < deduped[-1][1]:
                continue
            deduped.append(f)
        return [(f[0], f[2]) for f in deduped]

    @staticmethod
    def _find_buyer(context: str, allow_single: bool) -> str | None:
        best: tuple[int, str] | None = None
        for canonical, aliases in buyers.BUYER_ALIASES.items():
            for a in aliases:
                if not allow_single and len(a) < 2:
                    continue
                for m in re.finditer(re.escape(a), context):
                    if best is None or m.start() > best[0]:
                        best = (m.start(), canonical)
        return best[1] if best else None

    def _pre_text(self, full: str, end_pos: int, time_window: float) -> str:
        """信号前 time_window 秒内的文本（按字符时间戳截断）。"""
        if end_pos <= 0:
            return ""
        sig_t = self._times[end_pos - 1] if end_pos - 1 < len(self._times) else self._times[-1]
        lo = end_pos - 1
        while lo > 0 and sig_t - self._times[lo - 1] < time_window:
            lo -= 1
        return full[lo:end_pos]

    def _extract_sold(self, full: str, sig_start: int) -> tuple[str | None, int | None] | None:
        pre = self._pre_text(full, sig_start, PRICE_TIME_WINDOW)
        prices = self.find_prices(pre)
        buyer: str | None = None

        # 恭喜（信号后 30 字）
        after = full[sig_start:sig_start + 30]
        gi = after.find("恭喜")
        if gi >= 0:
            ctx = after[gi + 2: gi + 22]
            buyer = self._find_buyer(ctx, allow_single=True)

        # 价格前 35 字
        if buyer is None and prices:
            price_abs = sig_start - len(pre) + prices[-1][0]
            ctx = full[max(0, price_abs - 35):price_abs]
            buyer = self._find_buyer(ctx, allow_single=False)

        # 信号前 60 字
        if buyer is None:
            ctx = full[max(0, sig_start - 60):sig_start]
            buyer = self._find_buyer(ctx, allow_single=False)

        if buyer is None and not prices:
            return None
        return (buyer, prices[-1][1] if prices else None)

    def _extract_gongxi(self, full: str, gongxi_start: int, name: str) -> tuple[str | None, int | None] | None:
        buyer = self._find_buyer(name, allow_single=False)
        pre = self._pre_text(full, gongxi_start, PRICE_TIME_WINDOW)
        prices = self.find_prices(pre)
        if buyer is None and not prices:
            return None
        return (buyer, prices[-1][1] if prices else None)


# 供外部使用的便捷函数
__all__ = ["Signal", "SettlementSignalDetector", "PRICE_WORDS", "SETTLE_SIGNALS", "PASSED_KEYWORDS"]
