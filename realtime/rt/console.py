"""rich 终端实时面板（P4）：成交记录表 + 弹幕阶梯 + 实时转写。"""
from __future__ import annotations

import threading
from typing import Optional

from rich.console import Console
from rich.live import Live
from rich.panel import Panel
from rich.table import Table

from .events import bus
from .records import to_event_dict

_STATUS_STYLE = {"SOLD": "bold green", "PASSED": "dim", "NEEDS_REVIEW": "bold yellow"}


class RichSink:
    """订阅 EventBus，用 rich.Live 刷新终端面板。"""

    def __init__(self):
        self._console = Console()
        self._records: list = []
        self._danmaku = "—"
        self._transcript = ""
        self._lock = threading.Lock()

    def start(self) -> None:
        self._live = Live(self._render(), console=self._console, refresh_per_second=4)
        self._live.start()
        bus.set_on_event(self._on_event)

    def stop(self) -> None:
        if hasattr(self, "_live"):
            self._live.stop()

    def _on_event(self, ev: dict) -> None:
        with self._lock:
            if ev["type"] == "record":
                self._records.insert(0, ev["record"])
                self._records = self._records[:30]
            elif ev["type"] == "danmaku":
                self._danmaku = ev["text"]
            elif ev["type"] == "transcript":
                self._transcript = ev["text"][-2000:]
        self._live.update(self._render(), refresh=True)

    def _render(self):
        table = Table(title="成交记录", show_header=True, header_style="bold")
        for col in ("#", "书名", "买家", "价格", "状态", "时刻"):
            table.add_column(col)
        with self._lock:
            for r in self._records:
                table.add_row(
                    str(r["no"]), r["book"][:18], r.get("buyer") or "?",
                    f"¥{r.get('price') or '?'}", r["status"],
                    f"{r.get('t', 0):.1f}s",
                    style=_STATUS_STYLE.get(r["status"], ""))
            danmu = self._danmaku
            trans = self._transcript
        layout = Table.grid(expand=True)
        layout.add_column(ratio=3)
        layout.add_column(ratio=2)
        layout.add_row(
            Panel(table, border_style="green"),
            Panel(danmu + "\n\n" + trans[-600:], title="弹幕出价 / 实时转写", border_style="blue"))
        return layout


def publish_record(rec) -> None:
    bus.publish({"type": "record", "record": to_event_dict(rec)})


def publish_danmaku(text: str) -> None:
    bus.publish({"type": "danmaku", "text": text})


def publish_transcript(text: str) -> None:
    bus.publish({"type": "transcript", "text": text})
