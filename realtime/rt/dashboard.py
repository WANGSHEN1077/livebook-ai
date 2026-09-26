"""FastAPI Web 实时面板（P4）：浏览器实时查看成交记录/弹幕出价/实时转写。

用法（在 run_live.py / run_replay_full.py 里以线程启动）：
    from rt.dashboard import serve_dashboard
    serve_dashboard(port=8888)   # 后台线程启动 uvicorn

浏览器打开 http://127.0.0.1:8888
"""
from __future__ import annotations

import threading

from fastapi import FastAPI, WebSocket, WebSocketDisconnect

from .events import bus

app = FastAPI(title="LiveBook AI 实时面板")

HTML = """<!doctype html>
<html lang="zh">
<head>
<meta charset="utf-8">
<title>LiveBook AI 实时成交</title>
<style>
 body { font-family: -apple-system, "PingFang SC", sans-serif; margin: 16px; background:#0f1115; color:#e6e6e6; }
 h1 { font-size: 18px; }
 .cols { display:flex; gap:16px; }
 .col { flex:1; min-width:0; }
 .card { background:#1a1d24; border-radius:8px; padding:12px; margin-bottom:12px; }
 .card h2 { font-size:14px; margin:0 0 8px; color:#9aa4b2; }
 table { width:100%; border-collapse:collapse; font-size:13px; }
 th,td { text-align:left; padding:4px 6px; border-bottom:1px solid #262b34; }
 th { color:#9aa4b2; font-weight:500; }
 .sold { color:#4ade80; } .passed { color:#9ca3af; } .review { color:#fbbf24; }
 #transcript, #danmaku { font-size:12px; color:#c9d1d9; white-space:pre-wrap; max-height:280px; overflow-y:auto; }
 .mono { font-variant-numeric: tabular-nums; }
 .status { font-weight:600; }
</style>
</head>
<body>
<h1>LiveBook AI — 实时成交记录</h1>
<div class="cols">
  <div class="col">
    <div class="card"><h2>成交记录</h2>
      <table id="records"><thead><tr><th>#</th><th>书名</th><th>买家</th><th>成交价</th><th>状态</th><th>时刻</th></tr></thead><tbody></tbody></table>
    </div>
  </div>
  <div class="col">
    <div class="card"><h2>弹幕出价（当前窗口）</h2><div id="danmaku">—</div></div>
    <div class="card"><h2>实时转写</h2><div id="transcript">—</div></div>
  </div>
</div>
<script>
const ws = new WebSocket(`ws://${location.host}/ws`);
const esc = s => (s ?? "").replace(/[<>&]/g, c => ({'<':'&lt;','>':'&gt;','&':'&amp;'}[c]));
const STATUS_CLS = {SOLD:'sold', PASSED:'passed', 'NEEDS_REVIEW':'review'};
function addRecord(r) {
  const tb = document.querySelector('#records tbody');
  const tr = document.createElement('tr');
  tr.innerHTML = `<td>${r.no}</td><td>${esc(r.book)}</td><td>${esc(r.buyer ?? '?')}</td>` +
    `<td class="mono">¥${r.price ?? '?'}</td><td class="status ${STATUS_CLS[r.status]||''}">${r.status}</td>` +
    `<td class="mono">${r.t?.toFixed?.(1) ?? ''}s</td>`;
  tb.prepend(tr);
}
ws.onmessage = ev => {
  const m = JSON.parse(ev.data);
  if (m.type === 'record') addRecord(m.record);
  else if (m.type === 'danmaku') document.querySelector('#danmaku').textContent = m.text;
  else if (m.type === 'transcript') {
    const el = document.querySelector('#transcript');
    el.textContent = m.text.slice(-2000);
    el.scrollTop = el.scrollHeight;
  }
};
</script>
</body>
</html>"""


@app.get("/")
async def index():
    return HTML


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    import asyncio
    await ws.accept()
    bus.set_loop(asyncio.get_running_loop())
    await bus.connect(ws)
    try:
        while True:
            await ws.receive_text()   # keep alive
    except WebSocketDisconnect:
        bus.disconnect(ws)
    except Exception:
        bus.disconnect(ws)


def serve_dashboard(port: int = 8888) -> threading.Thread:
    """后台线程启动 uvicorn 面板服务。"""
    import uvicorn
    config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning")
    server = uvicorn.Server(config)
    thread = threading.Thread(target=server.run, daemon=True)
    thread.start()
    return thread
