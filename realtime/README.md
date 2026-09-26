# LiveBook AI — 实时成交记录引擎（全 Python）

把 speech2text 已验证的成交分析方案（音频信号 + 弹幕出价）做成**实时版**：直播进行中，实时生成成交记录（书名/买家/成交价/出价阶梯/时间窗口/状态）。

## 架构

```
sources（ReplaySource / LiveSource，统一时间戳事件）
  ├─ 回放：PyAV 解 0813 音频+帧
  └─ 实时：BlackHole+sounddevice 音频 / screencapture 抽帧
        │
        ├─► asr.py（sherpa-onnx 流式）→ transcript 事件
        ├─► ocr.py（macOS Vision）→ ocr 事件
        ▼
  danmaku.py  弹幕出价阶梯（分隔线=边界）
  signals.py  成交信号（结拍/倒计时/恭喜/流拍 + 价格/买家词典）
  fuser.py    融合状态机 → AuctionRecord
        ▼
  records.py  JSON/CSV 导出（对齐 0816 格式）
```

## 环境

- 解释器：任意装有 `sherpa_onnx / numpy / sounddevice / av / pillow / pyobjc-framework-Vision / fastapi / rich` 的 Python 3.9+（示例：`~/speech2text/venv/bin/python`）
- 模型：`~/speech2text/models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20`（可用 `LIVEBOOK_ASR_MODEL` 覆盖）
- **实时音频**：`brew install blackhole-2ch`（虚拟声卡，把直播窗口声音路由进去）
- **实时画面**：macOS 自带 `screencapture`（需授予屏幕录制权限）
- **OCR**：`pip install pyobjc-framework-Vision`（macOS Vision，零模型下载）

### 路径配置

所有路径都在 [rt/config.py](rt/config.py) 里集中定义，默认基于用户主目录，可用环境变量覆盖：

| 环境变量 | 用途 | 默认值 |
|---|---|---|
| `LIVEBOOK_ROOT` | 项目根 | `~/Documents/livebook-ai` |
| `LIVEBOOK_REPLAY` | 回放视频 | `<项目根>/mac-app/LiveBookAI/media/直播回放-08月13日.mp4` |
| `LIVEBOOK_ASR_MODEL` | sherpa 模型目录 | `~/speech2text/models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20` |
| `SPEECH2TEXT_ROOT` | 历史数据所在项目 | `~/speech2text` |
| `LIVEBOOK_BUYERS` | 买家名单 JSON | `realtime/buyers.json`（缺失则用 `buyers.example.json`） |
| `LIVEBOOK_SESSIONS` | 会话导出目录 | `/tmp/live_sessions` |

### 买家名单

仓库只带**虚构示例** `buyers.example.json`。真实名单放在同目录 `buyers.json`（已 gitignore，不会上传），格式见示例文件：

```json
{ "buyers": { "买家甲": ["买家甲", "甲老师"] },
  "hosts": ["示例书屋", "作者"],
  "system_keywords": ["进入直播间", "送出", "礼物"] }
```

## 用法

```bash
PY=~/speech2text/venv/bin/python   # 换成你自己的 Python 解释器

# P1 验证：0813 真实转写 → 信号 → 与成交表对账
PYTHONPATH= $PY scripts/verify_0813.py        # 期望 aligned 51/51 (100%)

# P2 回放音频端到端（真实音频 → 流式 ASR → 记录；无需 BlackHole）
PYTHONPATH= $PY scripts/run_replay_audio.py --start 250 --end 360

# P3 完整回放（音频 + 画面 OCR → 记录）
PYTHONPATH= $PY scripts/run_replay_full.py --start 0 --end 1000 --frame-interval 5

# P2/P3 实时模式（BlackHole 音频 + 屏幕 OCR + Web 面板）
PYTHONPATH= $PY scripts/run_live.py --web 8888 --console

# 实时模式：自动定位微信窗口 + 自动检测弹幕栏（推荐）
PYTHONPATH= $PY scripts/run_live.py --web 8888 --console --window-title "视频号,微信,直播"

# 直播前环境自检（BlackHole/麦克风/屏幕录制/直播窗口）
PYTHONPATH= $PY scripts/run_live.py --check

# P4 回放演示（浏览器看实时面板）
PYTHONPATH= $PY scripts/run_replay_full.py --start 250 --end 360 --web 8888 --console

# 0816 弹幕解析验证（真实弹幕数据模拟 OCR 行）
PYTHONPATH= $PY scripts/validate_0816_danmaku.py

# 画面区域校准（看回放帧的 OCR 排版）
PYTHONPATH= $PY scripts/calibrate_frames.py 295 340

# 单测
PYTHONPATH= $PY -m unittest discover -s tests
```

注意：`PYTHONPATH=` 必须清空（DSH 终端环境会污染到 hermes venv 的 site-packages）。

## 实时模式准备（用户操作）

1. `brew install blackhole-2ch`（本机已装好 0.7.1，coreaudiod 已重启生效）
2. 系统设置 → 声音 → 输出：把直播窗口的声音路由到 BlackHole（或用「多输出设备」同时给扬声器）
3. 授予终端「麦克风」权限 + 屏幕录制权限
4. 直播窗口尽量铺满屏幕（弹幕栏在右侧、封面在中央）

## 进度

| 阶段 | 状态 |
|---|---|
| P1 大脑（signals/danmaku/fuser/records + 对账） | ✅ 完成，28 测试 + 0813 对齐 94%（100% 信号覆盖） |
| P2 回放音频端到端（流式 ASR → 记录） | ✅ 完成：切片精确命中（某单 SOLD，买家/价格正确） |
| P2 实时音频（BlackHole + sounddevice + sherpa 流式） | ✅ BlackHole 已装好，捕获通道验证通过 |
| P3 画面 OCR（封面书名 + 弹幕出价） | ✅ 完成：封面书名 OCR 验证成功；**0816 弹幕解析 21/22 窗口、20/22（91%）买家+价格命中** |
| P3 完整回放（音频+画面） | ✅ 完成：切片首单精确命中（买家/价格/书名均正确） |
| P3 实时画面（screencapture + Vision） | ⏳ 代码就绪，等真实直播验证 |
| P4 产出（rich 表格 + Web 面板 + 导出） | ✅ 完成：rich 终端面板、FastAPI WebSocket 面板（http://127.0.0.1:8888）、CSV/JSON 导出 |
| P4 增强（窗口定位 + 弹幕区自动检测） | ✅ 完成：`rt/window.py`、`rt/regions.py`；32 测试通过 |
| 实战打磨（环境自检/会话导出/窗口连续性） | ✅ 完成：`run_live.py --check`、会话导出到 `~/tmp/live_sessions/日期/`、音频单通道窗口时间连续 |

## 项目定位（用户确认）

- **本项目只做「直播中实时成交单」**；直播后约 1 小时的回放视频 + 弹幕文件离线分析**已在 speech2text 项目实现**，不重复建设；
- 本项目的回放模式（run_replay_*）仅作为**开发/校准测试台**，产品形态是 run_live.py 实时路径。

## P4 增强：窗口定位 + 弹幕区自动检测

- `run_live.py --window-title "视频号,微信,直播"`：Quartz 自动定位直播窗口并只捕获窗口区域（已实测找到微信窗口 880×640）
- **弹幕区自动校准**：启动抓 3 帧 OCR 右半区，检测"短文本+数字"出价行聚集带 → 找到则启用弹幕通道并打印 x 范围；找不到（画面无弹幕）自动关闭弹幕通道（0813 回放实测返回 None，不误判）
- 书页页码等左侧零散数字不会误触发

## P4 产出层

- **rich 终端面板**（`--console`）：成交记录表 + 弹幕阶梯 + 实时转写，Live 刷新
- **FastAPI Web 面板**（`--web PORT`）：浏览器实时表格，WebSocket 推流（记录/弹幕/转写），新连接自动补发历史
- **导出**：会话结束自动写 `/tmp/rt_records_full.json`（0816 兼容格式）+ `.csv`（BOM，`书名,买家,成交价`）
- **事件总线** `rt/events.py`：管线线程 publish → Web/rich 订阅（线程安全）

## 已知限制（当前阶段）

- 0813 回放**画面无弹幕栏**（右侧是书页内容）→ 回放验证弹幕通道需关闭（--danmaku 默认 off）；弹幕在真实直播画面右侧验证
- 音频单通道的买家/价格提取较弱（NEEDS_REVIEW 多）——由弹幕阶梯补全（0816 验证 91%）
- 流式 ASR 的结算时刻有 ~20s 延迟（sherpa 流式解码滞后）
