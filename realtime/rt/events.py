"""实时事件总线（P4）：管线 → Web 面板/终端 的事件推送。

线程安全：管线线程 publish，面板线程（uvicorn loop）通过
run_coroutine_threadsafe 发送 WebSocket 消息。
"""
from __future__ import annotations

import asyncio
import threading
from typing import Callable, List

import websockets


class EventBus:
    def __init__(self):
        self._clients: set = set()
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._history: List[dict] = []          # 最近事件（新连接补发）
        self._history_max = 200
        self._on_event: Callable[[dict], None] | None = None

    def set_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    def set_on_event(self, fn: Callable[[dict], None]) -> None:
        """publish 时的同步回调（供 rich 终端/日志用）。"""
        self._on_event = fn

    async def connect(self, ws) -> None:
        with self._lock:
            self._clients.add(ws)
        # 新连接补发历史（序列化为 JSON 字符串）
        import json
        for ev in self._history:
            await self._send(ws, json.dumps(ev, ensure_ascii=False))

    def disconnect(self, ws) -> None:
        with self._lock:
            self._clients.discard(ws)

    def publish(self, event: dict) -> None:
        with self._lock:
            self._history.append(event)
            if len(self._history) > self._history_max:
                del self._history[: len(self._history) - self._history_max]
            clients = list(self._clients)
        if self._on_event:
            try:
                self._on_event(event)
            except Exception:
                pass
        if not clients or self._loop is None:
            return
        import json
        payload = json.dumps(event, ensure_ascii=False)
        for ws in clients:
            try:
                asyncio.run_coroutine_threadsafe(self._send(ws, payload), self._loop)
            except Exception:
                pass

    async def _send(self, ws, payload: str) -> None:
        try:
            await ws.send_text(payload)
        except websockets.ConnectionClosed:
            self.disconnect(ws)
        except Exception:
            self.disconnect(ws)


# 全局单例
bus = EventBus()
