"""弹幕区/封面区自动检测（P4 增强）。

实时直播时窗口位置/比例不固定，先用几帧做校准：
- 弹幕区：右侧区域中"短文本+数字"密集的栏（出价行特征）；
  若画面没有弹幕（如 0813 回放），返回 None → 弹幕通道自动关闭。
"""
from __future__ import annotations

from typing import List, Optional, Tuple

# 观察 = (text, confidence, box(x,y,w,h))，box 为 Vision 归一化坐标（原点左下）
Observation = Tuple[str, float, Tuple[float, float, float, float]]


def _is_danmaku_like(text: str) -> bool:
    """出价行特征：短文本且含数字，或纯数字，或"名字+数字"。"""
    t = text.strip()
    if not t or len(t) > 10:
        return False
    has_digit = any(ch.isdigit() for ch in t)
    if has_digit:
        return True
    # 无数字的短行也可能是弹幕（如"这本书真好"），但不足以当证据
    return False


def detect_danmaku_column(observations: List[Observation],
                          min_evidence: int = 2) -> Optional[Tuple[float, float]]:
    """从一帧 OCR 观察里检测弹幕栏的归一化 x 范围。

    策略：右侧区域（x≥0.5）内统计"出价行特征"观察；找到最右的连续聚集带。
    证据不足返回 None。
    """
    # 右半区按 0.05 宽度分 bin
    bins: dict[int, int] = {}
    for text, _conf, (_x, _y, w, _h) in observations:
        if not _is_danmaku_like(text):
            continue
        midx = _x + w / 2
        if midx < 0.5:
            continue
        bin_idx = int(midx * 20)  # 0.05 每 bin
        bins[bin_idx] = bins.get(bin_idx, 0) + 1

    if sum(bins.values()) < min_evidence:
        return None

    # 从最右的 bin 往左延伸（密度 ≥ 峰值/3）
    max_bin = max(bins)
    lo = max_bin
    peak = bins[max_bin]
    while lo > 10 and bins.get(lo - 1, 0) >= max(1, peak // 3):
        lo -= 1
    x0 = max(0.5, lo / 20.0)
    return (x0, 1.0)


def merge_columns(frames: List[List[Observation]],
                  min_evidence: int = 3) -> Optional[Tuple[float, float]]:
    """跨多帧累计证据后检测（更稳）。"""
    acc: dict[int, int] = {}
    for obs_list in frames:
        for text, _conf, (_x, _y, w, _h) in obs_list:
            if not _is_danmaku_like(text):
                continue
            midx = _x + w / 2
            if midx < 0.5:
                continue
            acc[int(midx * 20)] = acc.get(int(midx * 20), 0) + 1
    if sum(acc.values()) < min_evidence:
        return None
    max_bin = max(acc)
    lo = max_bin
    peak = acc[max_bin]
    while lo > 10 and acc.get(lo - 1, 0) >= max(1, peak // 3):
        lo -= 1
    return (max(0.5, lo / 20.0), 1.0)
