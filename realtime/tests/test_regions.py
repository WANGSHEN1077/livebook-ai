"""弹幕区自动检测测试。"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.regions import detect_danmaku_column, merge_columns  # noqa: E402

# 测试固定使用虚构示例名单（与真实客户名单解耦）
from rt import buyers as _buyers
_buyers.reload_catalog(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                    "buyers.example.json"))


def obs(text, x, y=0.5, w=0.05, h=0.03):
    return (text, 0.9, (x, y, w, h))


class RegionTests(unittest.TestCase):
    def test_no_danmaku_returns_none(self):
        # 封面长文本，无数字 → 无弹幕
        obs_list = [
            obs("明清时代庶民文化", 0.3, w=0.2),
            obs("王尔敏著", 0.4),
            obs("岳麓书社出版发行", 0.35, w=0.15),
        ]
        self.assertIsNone(detect_danmaku_column(obs_list))

    def test_right_column_bids_detected(self):
        # 右侧栏出价行 → 检测到右栏
        obs_list = [
            obs("买家甲 5", 0.85),
            obs("买家乙 10", 0.82),
            obs("买家丙 15", 0.88),
            obs("明清时代庶民文化", 0.3, w=0.2),
        ]
        region = detect_danmaku_column(obs_list)
        self.assertIsNotNone(region)
        self.assertGreaterEqual(region[0], 0.5)

    def test_left_side_numbers_not_danmaku(self):
        # 左侧零散数字（书页页码）不足以触发
        obs_list = [
            obs("第 5 页", 0.2),
            obs("2002 年", 0.3),
        ]
        self.assertIsNone(detect_danmaku_column(obs_list))

    def test_merge_across_frames(self):
        f1 = [obs("买家甲 5", 0.85)]
        f2 = [obs("买家乙 10", 0.83)]
        f3 = [obs("买家丙 15", 0.87)]
        region = merge_columns([f1, f2, f3], min_evidence=2)
        self.assertIsNotNone(region)
        self.assertGreaterEqual(region[0], 0.5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
