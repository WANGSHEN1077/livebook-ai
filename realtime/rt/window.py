"""窗口定位（P4 增强）：用 Quartz 找直播窗口的像素边界。"""
from __future__ import annotations

from typing import Optional, Tuple

import Quartz


def list_windows() -> list[dict]:
    """列出屏幕上的窗口（名称 + 边界）。"""
    wins = Quartz.CGWindowListCopyWindowInfo(
        Quartz.kCGWindowListOptionOnScreenOnly, Quartz.kCGNullWindowID) or []
    out = []
    for w in wins:
        name = w.get("kCGWindowName") or ""
        owner = w.get("kCGWindowOwnerName") or ""
        b = w.get("kCGWindowBounds") or {}
        try:
            bounds = (int(b.get("X", 0)), int(b.get("Y", 0)),
                      int(b.get("Width", 0)), int(b.get("Height", 0)))
        except Exception:
            continue
        if bounds[2] < 50 or bounds[3] < 50:
            continue  # 过滤菜单栏/小部件
        out.append({"name": name, "owner": owner,
                    "pid": w.get("kCGWindowOwnerPID"), "bounds": bounds})
    return out


def find_window(keywords: Tuple[str, ...] = ("视频号", "微信", "直播")) -> Optional[dict]:
    """按标题关键词找直播窗口；命中多个取最大的。"""
    best = None
    for w in list_windows():
        title = f"{w['owner']} {w['name']}"
        if any(k in title for k in keywords):
            if best is None or w["bounds"][2] * w["bounds"][3] > \
                    best["bounds"][2] * best["bounds"][3]:
                best = w
    return best
