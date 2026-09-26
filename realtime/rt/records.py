"""记录模型 + 导出（对齐 0816 弹幕方案格式）。"""
from __future__ import annotations

from dataclasses import dataclass, field, asdict
from typing import Optional


@dataclass
class DanmakuBid:
    sender: str
    price: int
    t: float


@dataclass
class AuctionRecord:
    no: int
    book: str
    isbn: Optional[str] = None
    buyer: Optional[str] = None
    price: Optional[int] = None
    bids: list = field(default_factory=list)  # list[DanmakuBid]
    window: tuple = (0.0, 0.0)                # (start, end) 秒
    status: str = "NEEDS_REVIEW"              # SOLD / PASSED / NEEDS_REVIEW
    source: str = ""                          # "danmaku" / "audio" / "both"
    t: float = 0.0                            # 结算时刻


def to_records_json(records, path) -> None:
    """导出为 danmu_0816_records.json 格式。"""
    out = [record_to_dict(r) for r in records]
    with open(path, "w", encoding="utf-8") as f:
        import json
        json.dump(out, f, ensure_ascii=False, indent=1)


def record_to_dict(r: AuctionRecord) -> dict:
    return {
        "no": r.no,
        "window_sec": [r.window[0], r.window[1]],
        "buyer": r.buyer,
        "price": r.price,
        "book": r.book,
        "isbn": r.isbn,
        "status": r.status,
        "source": r.source,
        "bids": [[b.sender, b.price] for b in r.bids],
    }


def to_event_dict(r: AuctionRecord) -> dict:
    """Web 面板事件（带结算时刻 t）。"""
    d = record_to_dict(r)
    d["t"] = r.t
    return d


def to_csv(records, path) -> None:
    """导出为 0808–0816.csv 格式：书名,买家,成交价（带 BOM）。"""
    with open(path, "w", encoding="utf-8-sig") as f:
        f.write("书名,买家,成交价\n")
        for r in records:
            book = r.book.replace(",", "，")
            f.write(f"{book},{r.buyer or ''},{r.price or ''}\n")
