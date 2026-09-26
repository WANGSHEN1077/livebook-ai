"""弹幕出价解析器测试（unittest，零依赖）。"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.danmaku import DanmakuBidParser  # noqa: E402

# 测试固定使用虚构示例名单（与真实客户名单解耦）
from rt import buyers as _buyers
_buyers.reload_catalog(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                    "buyers.example.json"))


class DanmakuTests(unittest.TestCase):
    def setUp(self):
        self.p = DanmakuBidParser()

    def feed(self, text, t):
        return self.p.ingest(text, t)

    def bids(self):
        cur, _ = self.p.snapshot()
        return cur.bids if cur else []

    def test_basic_ladder(self):
        self.feed("买家甲 5", 10)
        self.feed("买家甲 10", 11)
        self.feed("买家乙 15", 12)
        bids = self.bids()
        self.assertEqual([b.price for b in bids], [5, 10, 15])
        self.assertEqual(bids[-1].sender, "买家乙")

    def test_colon_yuan(self):
        self.feed("买家甲:5元", 10)
        self.feed("买家丙 10块", 11)
        self.assertEqual([b.price for b in self.bids()], [5, 10])

    def test_bare_number_to_last_speaker(self):
        self.feed("买家甲 5", 10)
        self.feed("10", 11)
        bids = self.bids()
        self.assertEqual(len(bids), 2)
        self.assertEqual(bids[-1].sender, "买家甲")

    def test_bare_number_without_speaker_ignored(self):
        self.feed("5", 10)
        self.assertEqual(self.bids(), [])

    def test_separator_settles(self):
        self.feed("买家甲 5", 10)
        self.feed("买家乙 10", 12)
        events = self.feed("----------------", 15)
        self.assertIn("settled", events)
        _, settled = self.p.snapshot()
        self.assertEqual(len(settled), 1)
        self.assertEqual(settled[0].buyer, "买家乙")
        self.assertEqual(settled[0].price, 10)

    def test_monotonic(self):
        self.feed("买家甲 10", 10)
        self.feed("买家乙 5", 11)
        self.assertEqual(len(self.bids()), 1)

    def test_dedup(self):
        self.feed("买家甲 5", 10)
        self.feed("买家甲 5", 11)
        self.assertEqual(len(self.bids()), 1)

    def test_system_and_host(self):
        self.feed("买家甲 送出礼物", 10)
        self.feed("示例书屋 作者 5", 11)
        self.assertEqual(self.bids(), [])

    def test_canonical_buyer(self):
        self.feed("丁老师 5", 10)
        self.assertEqual(self.bids()[0].sender, "买家丁")

    def test_cjk_prices(self):
        self.feed("买家甲 十五", 10)
        self.feed("买家乙 一百五", 11)
        self.feed("买家丙 两百六", 12)
        self.assertEqual([b.price for b in self.bids()], [15, 150, 260])

    def test_separator_detect(self):
        self.assertTrue(DanmakuBidParser.is_separator("----------------"))
        self.assertTrue(DanmakuBidParser.is_separator("===="))
        self.assertFalse(DanmakuBidParser.is_separator("买家甲 5"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
