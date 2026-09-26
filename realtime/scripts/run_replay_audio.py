#!/usr/bin/env python3
"""P2 端到端：回放音频 → 流式 ASR → 成交信号 → 融合 → 成交记录。

用 0813 真实音频（afconvert 抽出的 WAV）跑通完整实时管线——
与实时模式唯一区别是音频源（文件 vs BlackHole），管线代码完全一致。

用法（venv，PYTHONPATH 需清空）：
  PYTHONPATH= venv/bin/python scripts/run_replay_audio.py [--start 250] [--end 350]

输出：终端记录表 + /tmp/rt_records.json
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.asr import StreamingASR          # noqa: E402
from rt.sources import ReplayAudioSource  # noqa: E402
from rt.signals import SettlementSignalDetector  # noqa: E402
from rt.fuser import AuctionFuser        # noqa: E402
from rt.records import to_records_json   # noqa: E402
from rt import config  # noqa: E402

DEFAULT_WAV = config.REPLAY_WAV


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default=DEFAULT_WAV)
    ap.add_argument("--start", type=float, default=250.0)
    ap.add_argument("--end", type=float, default=350.0)
    args = ap.parse_args()

    asr = StreamingASR()
    stream = asr.create_stream()
    detector = SettlementSignalDetector()
    fuser = AuctionFuser()

    prev_text = ""
    chunk_count = 0
    for t, samples in ReplayAudioSource(args.wav, start=args.start, end=args.end):
        text = asr.feed(stream, samples)
        chunk_count += 1
        if len(text) > len(prev_text):
            delta = text[len(prev_text):]
            prev_text = text
            for sig in detector.ingest(delta, t):
                rec = fuser.on_signal(sig)
                if rec:
                    print(f"[{rec.t:8.1f}s] 成交 #{rec.no} {rec.buyer or '?'} "
                          f"¥{rec.price if rec.price is not None else '?'} "
                          f"[{rec.status}] {rec.book}")

    tail = asr.finish(stream)
    if len(tail) > len(prev_text):
        delta = tail[len(prev_text):]
        prev_text = tail
        for sig in detector.ingest(delta, args.end or 0):
            rec = fuser.on_signal(sig)
            if rec:
                print(f"[{rec.t:8.1f}s] 成交 #{rec.no} {rec.buyer or '?'} "
                      f"¥{rec.price if rec.price is not None else '?'} "
                      f"[{rec.status}] {rec.book}")

    print(f"\n== 切片 [{args.start},{args.end}]s 处理完成：{chunk_count} 块 ==")
    print(f"检测到成交信号: {len(fuser.records)} 条记录")
    to_records_json(fuser.records, "/tmp/rt_records.json")
    print("已导出 /tmp/rt_records.json")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
