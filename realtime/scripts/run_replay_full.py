#!/usr/bin/env python3
"""P3 完整回放：音频（流式 ASR → 信号）+ 画面（OCR → 封面书名/弹幕出价）
按时间合并 → 融合 → 成交记录。

用法：
  PYTHONPATH= venv/bin/python scripts/run_replay_full.py [--start 0] [--end 1000] [--frame-interval 5]
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.asr import StreamingASR          # noqa: E402
from rt.sources import (ReplayAudioSource, ReplayFrameSource,  # noqa: E402
                        DANMAKU_REGION, COVER_REGION)
from rt.ocr import VisionOCR, crop       # noqa: E402
from rt.signals import SettlementSignalDetector  # noqa: E402
from rt.danmaku import DanmakuBidParser  # noqa: E402
from rt.fuser import AuctionFuser        # noqa: E402
from rt.records import to_records_json, to_csv, to_event_dict  # noqa: E402
from rt.console import RichSink, publish_record, publish_transcript, publish_danmaku  # noqa: E402
from rt import config  # noqa: E402

DEFAULT_WAV = config.REPLAY_WAV
DEFAULT_VIDEO = config.REPLAY_VIDEO


def merged(iter_a, iter_b):
    """按 (t, ...) 时间顺序合并两个事件源。"""
    a, b = iter(iter_a), iter(iter_b)
    na, nb = next(a, None), next(b, None)
    while na is not None or nb is not None:
        if nb is None or (na is not None and na[0] <= nb[0]):
            yield ("audio",) + na
            na = next(a, None)
        else:
            yield ("frame",) + nb
            nb = next(b, None)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--wav", default=DEFAULT_WAV)
    ap.add_argument("--video", default=DEFAULT_VIDEO)
    ap.add_argument("--start", type=float, default=0.0)
    ap.add_argument("--end", type=float, default=1000.0)
    ap.add_argument("--frame-interval", type=float, default=5.0)
    ap.add_argument("--danmaku", action="store_true",
                    help="开启弹幕通道（0813 回放无弹幕，默认关闭；实时直播画面才开）")
    ap.add_argument("--web", type=int, metavar="PORT", default=0,
                    help="启动浏览器实时面板（如 --web 8888）")
    ap.add_argument("--console", action="store_true", help="rich 终端实时面板")
    args = ap.parse_args()

    if args.web:
        from rt.dashboard import serve_dashboard
        serve_dashboard(args.web)
        print(f"Web 面板: http://127.0.0.1:{args.web}")
    sink = RichSink() if args.console else None
    if sink:
        sink.start()

    asr = StreamingASR()
    stream = asr.create_stream()
    detector = SettlementSignalDetector()
    danmaku = DanmakuBidParser() if args.danmaku else None
    fuser = AuctionFuser()
    ocr = VisionOCR()
    prev_text = ""

    audio_src = ReplayAudioSource(args.wav, start=args.start, end=args.end)
    frame_src = ReplayFrameSource(args.video, interval=args.frame_interval, start=args.start)

    def process_frame(t, path):
        if t > args.end:
            return
        # 封面区 → 书名候选
        cover_path = f"/tmp/rt_cover_{int(t)}.png"
        crop(path, cover_path, *COVER_REGION)
        for text, _, _ in ocr.recognize(cover_path):
            if len(text) >= 2:
                fuser.on_ocr("cover", text, t)
        # 弹幕区 → 出价阶梯（仅当画面确有弹幕栏时开启）
        if danmaku is None:
            return
        danmu_path = f"/tmp/rt_danmu_{int(t)}.png"
        crop(path, danmu_path, *DANMAKU_REGION)
        for text, _, _ in ocr.recognize(danmu_path):
            for ev in danmaku.ingest(text, t):
                if ev == "settled":
                    _print_rec(fuser.on_danmaku_event("settled", t))
                elif ev == "bid":
                    cur, _ = danmaku.snapshot()
                    if cur and cur.bids:
                        fuser.on_danmaku_event("bid", t, cur.bids[-1])
                        publish_danmaku(" | ".join(f"{b.sender} {b.price}"
                                                   for b in cur.bids[-12:]))

    def _print_rec(rec):
        if rec:
            line = (f"[{rec.t:8.1f}s] #{rec.no} {rec.buyer or '?'} "
                    f"¥{rec.price if rec.price is not None else '?'} "
                    f"[{rec.status}] {rec.book}")
            print(line, flush=True)
            publish_record(rec)

    for kind, t, payload in merged(audio_src, frame_src):
        if t > args.end:
            break
        if kind == "audio":
            text = asr.feed(stream, payload)
            if len(text) > len(prev_text):
                delta = text[len(prev_text):]
                prev_text = text
                publish_transcript(text[-400:])
                for sig in detector.ingest(delta, t):
                    _print_rec(fuser.on_signal(sig))
        else:
            process_frame(t, payload)

    tail = asr.finish(stream)
    if len(tail) > len(prev_text):
        for sig in detector.ingest(tail[len(prev_text):], args.end):
            _print_rec(fuser.on_signal(sig))

    print(f"\n== 切片 [{args.start},{args.end}]s 完成：{len(fuser.records)} 条记录 ==")
    to_records_json(fuser.records, "/tmp/rt_records_full.json")
    to_csv(fuser.records, "/tmp/rt_records_full.csv")
    print("已导出 /tmp/rt_records_full.json 和 .csv")
    if sink:
        sink.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
