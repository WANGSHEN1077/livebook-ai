#!/usr/bin/env python3
"""P1 验证：0813 真实 ASR 转写 → 成交信号 → 与成交表对账。

用法（用装了 sherpa_onnx 的 Python 解释器）：
  PYTHONPATH= python scripts/verify_0813.py

数据源（路径可用环境变量覆盖，见 rt/config.py）：
  0813 转写（9399 段带时间戳） + 成交表（51 条：t_sec/winner/price）
输出：
  终端对账统计 + /tmp/rt_verify.txt
"""
from __future__ import annotations

import json
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt import config  # noqa: E402
from rt.signals import SettlementSignalDetector  # noqa: E402

TRANSCRIPT = config.TRANSCRIPT_0813
SALES = config.SALES_0813
# t_sec 是出价/记录时刻，收尾（倒计时+恭喜）在其后 10~75 秒 → 容差放宽到 90s
TOLERANCE = 90.0


def main() -> int:
    segs = json.load(open(TRANSCRIPT, encoding="utf-8"))["segments"]
    sales = json.load(open(SALES, encoding="utf-8"))

    detector = SettlementSignalDetector()
    sold = []  # (t, buyer, price)
    for seg in segs:
        t = seg.get("time")
        text = seg.get("text")
        if t is None or not text:
            continue
        for s in detector.ingest(text, float(t)):
            if s.kind == "sold":
                sold.append((s.t, s.buyer, s.price))

    aligned = buyer_matched = full_matched = 0
    missed = []
    for sale in sales:
        tsec, winner, price = sale["t_sec"], sale["winner"], sale["price"]
        near = [s for s in sold if abs(s[0] - tsec) <= TOLERANCE]
        if near:
            aligned += 1
        if any(s[1] == winner for s in near):
            buyer_matched += 1
        if any(s[1] == winner and s[2] == price for s in near):
            full_matched += 1
        if not near:
            # 最近信号的偏差，帮助定位
            closest = min(sold, key=lambda s: abs(s[0] - tsec)) if sold else None
            dist = f"{closest[0] - tsec:+.0f}s→{closest[1]}¥{closest[2]}" if closest else "-"
            missed.append(f"no={sale['no']} {winner} ¥{price} @{tsec} (最近信号 {dist})")

    total = len(sales)
    lines = [
        f"P1_VERIFY: total sold signals = {len(sold)}",
        f"P1_VERIFY: aligned={aligned}/{total} ({aligned * 100 // total}%)  tol={TOLERANCE:.0f}s",
        f"P1_VERIFY: buyerMatched={buyer_matched}/{total}",
        f"P1_VERIFY: fullMatched={full_matched}/{total}",
        f"P1_VERIFY: no-signal sales: {' | '.join(missed[:12])}" if missed else "P1_VERIFY: all sales have signals",
    ]
    print("\n".join(lines))
    with open("/tmp/rt_verify.txt", "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    return 0 if aligned * 100 // total >= 85 else 1


if __name__ == "__main__":
    raise SystemExit(main())
