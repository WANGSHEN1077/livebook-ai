"""成交信号检测器 + 融合器测试（unittest，零依赖）。"""
from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from rt.signals import SettlementSignalDetector  # noqa: E402
from rt.fuser import AuctionFuser  # noqa: E402
from rt.records import DanmakuBid  # noqa: E402

# 测试固定使用虚构示例名单（与真实客户名单解耦）
from rt import buyers as _buyers  # noqa: E402
_buyers.reload_catalog(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                                    "buyers.example.json"))


class SignalTests(unittest.TestCase):
    def setUp(self):
        self.d = SettlementSignalDetector()

    def test_settle_homophones(self):
        for sig in ["结拍", "节拍", "接拍", "截拍", "解拍"]:
            d = SettlementSignalDetector()
            s = d.ingest(f"五十元恭喜买家甲老师{sig}", 100)
            self.assertEqual(len(s), 1, sig)
            self.assertEqual(s[0].buyer, "买家甲", sig)
            self.assertEqual(s[0].price, 50, sig)

    def test_countdown(self):
        s = self.d.ingest("现在五十元五四三二一恭喜买家甲老师", 100)
        self.assertEqual(len(s), 1)
        self.assertEqual(s[0].buyer, "买家甲")
        self.assertEqual(s[0].price, 50)

    def test_bare_countdown(self):
        s = self.d.ingest("就以丁老师三十节拍", 100)
        self.assertEqual(len(s), 1)
        self.assertEqual(s[0].buyer, "买家丁")
        self.assertEqual(s[0].price, 30)

    def test_standalone_gongxi(self):
        s = self.d.ingest("那我们恭喜乙老师", 100)
        self.assertEqual(len(s), 1)
        self.assertEqual(s[0].buyer, "买家乙")

    def test_gongxi_with_price(self):
        s = self.d.ingest("出价是四十好的那我们恭喜乙老师", 100)
        self.assertEqual(s[0].buyer, "买家乙")
        self.assertEqual(s[0].price, 40)

    def test_passed(self):
        for kw in ["没人要", "流了", "流标", "没人拍", "下一本", "撤拍"]:
            d = SettlementSignalDetector()
            s = d.ingest(kw, 100)
            self.assertEqual(s[0].kind, "passed", kw)

    def test_cjk_price_forms(self):
        for text, expected in [("一百五结拍", 150), ("三百块结拍", 300),
                               ("七十五结拍", 75), ("五十五结拍", 55)]:
            d = SettlementSignalDetector()
            s = d.ingest(text, 100)
            self.assertEqual(s[0].price, expected, text)

    def test_split_across_ingests(self):
        self.d.ingest("恭喜买家甲五", 10)
        s = self.d.ingest("十元结拍", 11)
        self.assertTrue(any(x.buyer == "买家甲" and x.price == 50 for x in s))

    def test_gongxi_dedup_near_anchor(self):
        # 恭喜在倒计时 ±30 字内 → 不重复触发
        s = self.d.ingest("现在五十元五四三二一恭喜买家甲老师", 100)
        sold = [x for x in s if x.kind == "sold"]
        self.assertEqual(len(sold), 1)


class FuserTests(unittest.TestCase):
    def test_danmaku_signal_merge(self):
        f = AuctionFuser()
        f.on_danmaku_event("bid", 10, DanmakuBid("买家甲", 5, 10))
        f.on_danmaku_event("bid", 11, DanmakuBid("买家乙", 10, 11))
        f.on_ocr("cover", "明清时代庶民文化", 8)
        rec = f.on_signal(SignalFactory.sold("买家乙", 10, t=15))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.buyer, "买家乙")
        self.assertEqual(rec.price, 10)
        self.assertEqual(rec.book, "明清时代庶民文化")
        self.assertEqual(rec.status, "SOLD")
        self.assertEqual(len(rec.bids), 2)

    def test_audio_fallback_without_danmaku(self):
        f = AuctionFuser()
        rec = f.on_signal(SignalFactory.sold("买家丁", 30, t=15))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.buyer, "买家丁")
        self.assertEqual(rec.price, 30)

    def test_passed_no_bids(self):
        f = AuctionFuser()
        rec = f.on_signal(SignalFactory.passed(t=15))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.status, "PASSED")

    def test_danmaku_fills_missing_signal(self):
        # 音频信号缺买家/价格时，弹幕阶梯补全 → 完整成交
        f = AuctionFuser()
        f.on_danmaku_event("bid", 10, DanmakuBid("买家甲", 5, 10))
        rec = f.on_signal(SignalFactory.sold(None, None, t=15))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.status, "SOLD")
        self.assertEqual(rec.buyer, "买家甲")
        self.assertEqual(rec.price, 5)

    def test_needs_review_when_nothing(self):
        # 信号有买家但无价格，也无弹幕 → NEEDS_REVIEW
        f = AuctionFuser()
        rec = f.on_signal(SignalFactory.sold("买家甲", None, t=15))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.status, "NEEDS_REVIEW")

    def test_passed_after_sold_ignored(self):
        # 成交后 20s 内的"下一本"不是流拍
        f = AuctionFuser()
        f.on_signal(SignalFactory.sold("买家丁", 30, t=15))
        rec = f.on_signal(SignalFactory.passed(t=22))
        self.assertIsNone(rec)

    def test_passed_after_20s(self):
        f = AuctionFuser()
        f.on_signal(SignalFactory.sold("买家丁", 30, t=15))
        rec = f.on_signal(SignalFactory.passed(t=40))
        self.assertIsNotNone(rec)
        self.assertEqual(rec.status, "PASSED")

    def test_dedup_close_records(self):
        f = AuctionFuser()
        f.on_signal(SignalFactory.sold("买家丁", 30, t=15))
        rec2 = f.on_signal(SignalFactory.sold("买家丁", 30, t=20))
        self.assertIsNone(rec2)


class SignalFactory:
    @staticmethod
    def sold(buyer, price, t):
        from rt.signals import Signal
        return Signal("sold", t, buyer, price)

    @staticmethod
    def passed(t):
        from rt.signals import Signal
        return Signal("passed", t)


if __name__ == "__main__":
    unittest.main(verbosity=2)
