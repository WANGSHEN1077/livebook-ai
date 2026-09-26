# LiveBook AI

**直播卖书场景下，直播进行中实时生成成交单**（书名 / 买家 / 成交价）。

系统在直播过程中同时看和听：

```text
直播窗口画面 ──┬─► 封面区 OCR ──────► 书名 / ISBN
（屏幕捕获）    └─► 弹幕区 OCR ──────► 出价阶梯（谁出到多少钱）
系统音频 ─────────► 流式 ASR ────────► 成交信号（结拍 / 倒计时 / 恭喜 / 流拍）
                          │
                          ▼
                      融合器（状态机）──► 成交记录（书名·买家·成交价·出价阶梯·状态）
                          ▼
                实时列表（终端 / 浏览器）+ CSV / JSON 导出
```

三路信号互补：**弹幕定"谁出到多少钱"**（精确文本），**音频定"这一单何时结束"**（成交语义），**封面 OCR 定"卖哪本书"**。

---

## 目录结构

```text
realtime/     ★ 实时成交引擎（Python，产品主线）
mac-app/      Swift macOS 原型（捕获 / Vision OCR / ISBN / 最佳画面 / 基准校验）
docs/         设计文档与历史规格
scripts/      OCR 诊断小工具
```

## 快速开始（实时引擎）

```bash
# 依赖：Python 3.9+ 与 sherpa_onnx / numpy / sounddevice / av / pillow /
#       pyobjc-framework-Vision / fastapi / rich / websockets
# 实时音频需要 BlackHole 虚拟声卡：brew install blackhole-2ch

cd realtime

# 直播前环境自检（BlackHole / 麦克风 / 屏幕录制 / 直播窗口）
PYTHONPATH= python scripts/run_live.py --check

# 开跑：BlackHole 音频 + 屏幕 OCR + Web 面板
PYTHONPATH= python scripts/run_live.py --web 8888 --console
# 浏览器打开 http://127.0.0.1:8888
```

使用前把直播窗口的声音输出路由到 BlackHole（或用「音频 MIDI 设置」建一个
BlackHole + 扬声器的多输出设备），并授予终端麦克风与屏幕录制权限。

详细的测试流程见 [realtime/TESTING_GUIDE.md](realtime/TESTING_GUIDE.md)，
模块说明与路径配置见 [realtime/README.md](realtime/README.md)。

## 买家名单

仓库只带虚构示例 `realtime/buyers.example.json`。真实名单放在
`realtime/buyers.json`（已 gitignore），格式见示例文件，或用环境变量
`LIVEBOOK_BUYERS` 指定。

## Swift 原型（mac-app）

Phase 1 开发的 macOS 应用原型：ScreenCaptureKit 捕获、Vision OCR、
ISBN 解析、最佳画面评分、0813 基准校验。构建方式：

```bash
cd mac-app/LiveBookAI
xcodebuild -project LiveBookAI.xcodeproj -scheme LiveBookAI -configuration Debug build
xcodebuild -project LiveBookAI.xcodeproj -scheme LiveBookAI test
```

路径（回放视频 / sherpa 模型 / 基准 CSV）均可用环境变量覆盖：
`LIVEBOOK_REPLAY`、`LIVEBOOK_ASR_MODEL`、`LIVEBOOK_DANMU_CSV`。
首次以真实窗口模式运行需授予「屏幕录制」权限。

## 文档

- [realtime/README.md](realtime/README.md) — 实时引擎用法、路径配置、进度
- [realtime/TESTING_GUIDE.md](realtime/TESTING_GUIDE.md) — 直播测试操作手册
- [docs/REALTIME_AUCTION_DESIGN.md](docs/REALTIME_AUCTION_DESIGN.md) — 实时成交引擎设计
- [docs/LIVEBOOK_AI_MACOS_SPEC.md](docs/LIVEBOOK_AI_MACOS_SPEC.md) — 原始 macOS 规格（Phase 1）
- [docs/DEVLOG.md](docs/DEVLOG.md) — 开发日志
