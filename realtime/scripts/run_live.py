#!/usr/bin/env python3
"""P2/P3 实时模式：BlackHole 音频 + 屏幕画面 → 流式 ASR + OCR → 实时成交记录。

前提（用户操作）：
  1. brew install blackhole-2ch
  2. 系统设置 → 声音：把直播窗口的输出路由到 BlackHole
  3. 授予终端 麦克风/录音 权限 + 屏幕录制权限
  4. 直播窗口尽量铺满屏幕（弹幕栏在右侧，封面在中央）

用法：
  PYTHONPATH= venv/bin/python scripts/run_live.py
  （Ctrl-C 结束；每单结算即打印，结束后导出 JSON）
"""
from __future__ import annotations

import os
import signal
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.asr import StreamingASR          # noqa: E402
from rt.sources import (LiveAudioSource, ScreenSource,  # noqa: E402
                        DANMAKU_REGION, COVER_REGION)
from rt.ocr import VisionOCR, crop       # noqa: E402
from rt.signals import SettlementSignalDetector  # noqa: E402
from rt.danmaku import DanmakuBidParser  # noqa: E402
from rt.fuser import AuctionFuser        # noqa: E402
from rt.records import to_records_json, to_csv  # noqa: E402
from rt.console import RichSink, publish_record, publish_transcript, publish_danmaku  # noqa: E402
from rt import config  # noqa: E402

FRAME_INTERVAL = 2.0


def check_env(window_title: str = "视频号,微信,直播", report: bool = False) -> dict:
    """直播前环境自检：BlackHole / 麦克风权限 / 屏幕录制权限 / 直播窗口。"""
    import sounddevice as sd
    result: dict = {}

    # 1. BlackHole 设备
    bh = None
    for i, d in enumerate(sd.query_devices()):
        if "blackhole" in d["name"].lower() and d["max_input_channels"] > 0:
            bh = i
            break
    result["BlackHole 设备"] = f"OK（设备 #{bh}）" if bh is not None else "缺失：brew install blackhole-2ch"

    # 2. 麦克风/录音权限：试开 0.2s
    if bh is not None:
        try:
            with sd.InputStream(device=bh, samplerate=16000, channels=1, dtype="float32"):
                pass
            result["麦克风权限"] = "OK"
        except Exception as e:
            result["麦克风权限"] = f"被拒/失败：{e}"
    else:
        result["麦克风权限"] = "跳过（无 BlackHole）"

    # 3. 屏幕录制权限：抓一张测试图看是否全黑
    import subprocess, tempfile
    test = os.path.join(tempfile.gettempdir(), "rt_screen_test.png")
    subprocess.run(["screencapture", "-x", test], check=False)
    if os.path.exists(test) and os.path.getsize(test) > 500:
        from PIL import Image
        im = Image.open(test).convert("L")
        px = list(im.getdata())
        mean = sum(px[: len(px): 97]) / max(1, len(range(0, len(px), 97)))
        result["屏幕录制权限"] = "OK" if mean > 3 else "异常（画面全黑，可能无权限或屏幕锁定）"
        os.remove(test)
    else:
        result["屏幕录制权限"] = "被拒（screencapture 无输出）"

    # 4. 直播窗口
    if window_title:
        from rt.window import find_window
        kw = tuple(k.strip() for k in window_title.split(",") if k.strip())
        win = find_window(kw)
        result["直播窗口"] = (f"找到：[{win['owner']} {win['name']}] {win['bounds']}"
                              if win else f"未找到（关键词 {kw}）")
    else:
        result["直播窗口"] = "跳过"

    if report:
        print("=== 直播前环境自检 ===")
        for k, v in result.items():
            mark = "✅" if str(v).startswith("OK") or str(v).startswith("找到") else "⚠️"
            print(f"  {mark} {k}: {v}")
    return result


def main() -> int:
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--web", type=int, metavar="PORT", default=0,
                    help="启动浏览器实时面板（如 --web 8888）")
    ap.add_argument("--console", action="store_true", help="rich 终端实时面板")
    ap.add_argument("--window-title", default="视频号,微信,直播",
                    help="自动定位直播窗口的关键词（逗号分隔）")
    ap.add_argument("--no-danmaku", action="store_true", help="强制关闭弹幕通道")
    ap.add_argument("--check", action="store_true",
                    help="只做环境自检并退出（不开直播监听）")
    args = ap.parse_args()

    if args.check:
        check_env(args.window_title, report=True)
        return 0

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
    fuser = AuctionFuser()
    ocr = VisionOCR()
    prev_text = ""

    # —— 窗口定位 + 弹幕区校准 ——
    capture_region = None
    if args.window_title:
        from rt.window import find_window
        kw = tuple(k.strip() for k in args.window_title.split(",") if k.strip())
        win = find_window(kw)
        if win:
            capture_region = win["bounds"]
            print(f"定位到直播窗口: [{win['owner']} {win['name']}] "
                  f"{capture_region}（分辨率缩放可能影响坐标，必要时用 --window-title 调整）")
        else:
            print(f"未找到匹配窗口（{kw}），退回全屏捕获")

    screen_iter = iter(ScreenSource(region=capture_region, interval=FRAME_INTERVAL))

    danmaku_region = None
    if not args.no_danmaku:
        from rt.regions import merge_columns
        # 校准：抓 3 帧，OCR 右半区，累计证据检测弹幕栏
        evidence = []
        for _ in range(3):
            try:
                t, path = next(screen_iter)
            except StopIteration:
                break
            half = f"/tmp/rt_calib_half_{int(t)}.png"
            crop(path, half, 0.5, 0.0, 1.0, 1.0)
            obs_list = []
            for text, conf, (bx, by, bw, bh) in ocr.recognize(half):
                obs_list.append((text, conf, (0.5 + bx * 0.5, by, bw * 0.5, bh)))
            evidence.append(obs_list)
        danmaku_region = merge_columns(evidence) if evidence else None
        if danmaku_region:
            print(f"检测到弹幕栏: x∈[{danmaku_region[0]:.2f}, 1.0]（右侧）")
        else:
            print("未检测到弹幕出价行（画面可能无弹幕栏）→ 弹幕通道关闭，仅用音频+封面")

    danmaku = DanmakuBidParser() if danmaku_region else None
    cover_region = COVER_REGION

    audio_iter = iter(LiveAudioSource())
    audio_ready = next(audio_iter, None)
    screen_ready = next(screen_iter, None)

    # 会话调试转储（校准用）
    session_signals: list = []
    session_danmaku: list = []

    def process_screen(t, path):
        # 封面区 → 书名候选
        cover_path = f"/tmp/rt_live_cover_{int(t)}.png"
        crop(path, cover_path, *cover_region)
        for text, _, _ in ocr.recognize(cover_path):
            if len(text) >= 2:
                fuser.on_ocr("cover", text, t)
        # 弹幕区 → 出价阶梯（仅当校准检测到弹幕栏）
        if danmaku is None:
            return
        danmu_path = f"/tmp/rt_live_danmu_{int(t)}.png"
        crop(path, danmu_path, *danmaku_region)
        for text, _, _ in ocr.recognize(danmu_path):
            for ev in danmaku.ingest(text, t):
                if ev == "settled":
                    _print_rec(fuser.on_danmaku_event("settled", t))
                elif ev == "bid":
                    cur, _ = danmaku.snapshot()
                    if cur and cur.bids:
                        b = cur.bids[-1]
                        fuser.on_danmaku_event("bid", t, b)
                        session_danmaku.append({"t": t, "sender": b.sender, "price": b.price})
                        publish_danmaku(" | ".join(f"{x.sender} {x.price}"
                                                   for x in cur.bids[-12:]))

    def _print_rec(rec):
        if rec:
            print(f"[{rec.t:8.1f}s] 成交 #{rec.no} {rec.buyer or '?'} "
                  f"¥{rec.price if rec.price is not None else '?'} "
                  f"[{rec.status}] {rec.book}", flush=True)
            publish_record(rec)

    def finish(*_):
        import datetime
        tail = asr.finish(stream)
        if len(tail) > len(prev_text):
            for sig in detector.ingest(tail[len(prev_text):], 0):
                _print_rec(fuser.on_signal(sig))
        sess = os.path.join(config.SESSION_ROOT,
                            datetime.datetime.now().strftime("%Y%m%d_%H%M"))
        os.makedirs(sess, exist_ok=True)
        to_records_json(fuser.records, os.path.join(sess, "records.json"))
        to_csv(fuser.records, os.path.join(sess, "records.csv"))
        # 调试转储：转写全文 / 成交信号 / 弹幕出价 / 配置
        with open(os.path.join(sess, "transcript.txt"), "w", encoding="utf-8") as f:
            f.write(prev_text)
        with open(os.path.join(sess, "signals.json"), "w", encoding="utf-8") as f:
            import json
            json.dump(session_signals, f, ensure_ascii=False, indent=1)
        with open(os.path.join(sess, "danmaku.json"), "w", encoding="utf-8") as f:
            import json
            json.dump(session_danmaku, f, ensure_ascii=False, indent=1)
        with open(os.path.join(sess, "config.json"), "w", encoding="utf-8") as f:
            import json
            json.dump({"capture_region": capture_region,
                       "danmaku_region": danmaku_region,
                       "cover_region": list(cover_region),
                       "window_title": args.window_title,
                       "danmaku_enabled": danmaku is not None}, f, ensure_ascii=False, indent=1)
        if sink:
            sink.stop()
        print(f"\n== 本场共 {len(fuser.records)} 条记录 ==")
        print(f"已导出: {sess}/（records.json/.csv, transcript.txt, signals.json, danmaku.json）")
        raise SystemExit(0)

    signal.signal(signal.SIGINT, finish)

    print("实时监听中（BlackHole 音频 + 屏幕 OCR）… Ctrl-C 结束")
    try:
        while audio_ready is not None:
            # 处理音频块
            t_audio, samples = audio_ready
            text = asr.feed(stream, samples)
            if len(text) > len(prev_text):
                delta = text[len(prev_text):]
                prev_text = text
                publish_transcript(text[-400:])
                for sig in detector.ingest(delta, t_audio):
                    session_signals.append({"t": t_audio, "kind": sig.kind,
                                            "buyer": sig.buyer, "price": sig.price})
                    _print_rec(fuser.on_signal(sig))
            audio_ready = next(audio_iter, None)
            # 处理到期的屏幕帧
            while screen_ready is not None and screen_ready[0] <= (audio_ready[0] if audio_ready else 1e18):
                process_screen(*screen_ready)
                screen_ready = next(screen_iter, None)
    except KeyboardInterrupt:
        finish()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
