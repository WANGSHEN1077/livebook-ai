#!/usr/bin/env python3
"""0816 弹幕解析验证：把平台导出的弹幕模拟成屏幕 OCR 行喂给 DanmakuBidParser，
与人工核定的窗口/买家/价格记录对账。

屏幕弹幕行 ≈ "发送者 内容"（如 "买家甲 5"、"作者 -------------"）。
数据文件路径见 rt/config.py（可用环境变量覆盖）。
"""
from __future__ import annotations

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt import config  # noqa: E402
from rt.danmaku import DanmakuBidParser  # noqa: E402

DANMU = config.DANMU_0816
RECORDS = config.DANMU_0816_RECORDS


def mmss_to_sec(s: str) -> float:
    try:
        parts = s.split(":")
        return int(parts[0]) * 60 + int(parts[1])
    except Exception:
        return 0.0


def main() -> int:
    data = json.load(open(DANMU, encoding="utf-8"))
    items = data["danmu"]
    records = json.load(open(RECORDS, encoding="utf-8"))

    parser = DanmakuBidParser()
    for it in items:
        t = mmss_to_sec(it.get("appear_time", ""))
        sender = it.get("sender", "")
        content = it.get("content", "")
        line = f"{sender} {content}".strip()
        parser.ingest(line, t)

    _, settled = parser.snapshot()
    print(f"弹幕行: {len(items)} | 结算窗口: {len(settled)} | 期望记录: {len(records)}")

    hit_buyer = hit_window = 0
    for r in records:
        w0, w1 = r["window_sec"]
        buyer, price = r["buyer"], r["price"]
        near = [s for s in settled if abs(s.start - w0) < 120]
        if near:
            hit_window += 1
        if any(s.buyer == buyer and s.price == price for s in near):
            hit_buyer += 1
        else:
            print(f"  未命中: no={r['no']} {buyer} ¥{price} 窗口[{w0},{w1}] "
                  f"最近窗口: {[(round(s.start), s.buyer, s.price) for s in near[:2]]}")

    print(f"窗口命中: {hit_window}/{len(records)} | 买家+价格命中: {hit_buyer}/{len(records)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
