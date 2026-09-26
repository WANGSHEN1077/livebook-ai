#!/usr/bin/env python3
"""P3 校准：抽 0813 回放帧，OCR 弹幕栏 + 封面区，观察真实排版。

用法：
  PYTHONPATH= venv/bin/python scripts/calibrate_frames.py [t0] [t1]
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt import config  # noqa: E402
from rt.sources import ReplayFrameSource, DANMAKU_REGION, COVER_REGION  # noqa: E402
from rt.ocr import VisionOCR, crop  # noqa: E402

VIDEO = config.REPLAY_VIDEO
OCR = VisionOCR()


def main() -> int:
    t0 = float(sys.argv[1]) if len(sys.argv) > 1 else 295.0
    t1 = float(sys.argv[2]) if len(sys.argv) > 2 else 340.0

    for t, path in ReplayFrameSource(VIDEO, interval=5.0, start=t0, max_frames=9):
        if t > t1:
            break
        danmu_path = f"/tmp/rt_calib_danmu_{int(t)}.png"
        cover_path = f"/tmp/rt_calib_cover_{int(t)}.png"
        crop(path, danmu_path, *DANMAKU_REGION)
        crop(path, cover_path, *COVER_REGION)

        danmu = OCR.recognize(danmu_path)
        cover = OCR.recognize(cover_path)
        print(f"=== t={t:.1f}s ===")
        print(f"  弹幕栏({len(danmu)}): " + " | ".join(f"{txt}" for txt, _, _ in danmu[:8]))
        print(f"  封面区({len(cover)}): " + " | ".join(f"{txt}" for txt, _, _ in cover[:8]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
