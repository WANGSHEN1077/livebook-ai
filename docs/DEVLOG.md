# 开发日志 (DEVLOG)

## v0.1.0 — Phase 1 骨架搭建

### 环境
- macOS 26.5.2 (arm64), Xcode 26.6, Swift 6.3.3, SDK 26.5
- 目标：M4 MacBook Air 16GB（开发）+ Intel A2141（兼容测试）
- 通用二进制 `ARCHS = arm64 x86_64`, `MACOSX_DEPLOYMENT_TARGET = 15.0`

### Phase 1 范围（本日志对应实现）
- FrameSource 协议 + ReplayFileSource（AVAssetReader，倍速/跳转）
- ScreenCaptureSource 占位（SCStream，Phase 1 后期接入）
- AdaptiveFrameSampler（2 / 5 / 0.5 FPS）
- Vision OCR（VNRecognizeTextRequest, zh-Hans/zh-Hant/ja-JP/en-US）
- ISBN-10/ISBN-13/EAN-13 parser + checksum
- BestFrameSelector + SharpnessCalculator + ChangeDetector
- SwiftData Models（BookCandidate / MediaAsset / CaptureSession）
- AssetStore（原始 + 处理后图片持久化）
- UI（源列表 / 预览 + 包围框 / 检查器 / 回放控制 / 基准校验模式）
- 基准校验模式：0813 全 51 本自动比对

### 决策记录
- 回放优先：先用 `~/Documents/livebook-ai/mac-app/LiveBookAI/media/直播回放-08月13日.mp4` 模拟直播窗口，后续替换为真实直播窗口，管线零改动（同一 FrameSource 抽象）。
- 无 brew/xcodegen：手写 `.xcodeproj`（objectVersion 77 + PBXFileSystemSynchronizedRootGroup）。
- 基准数据源：`~/Documents/danmu/0813.csv`（书名）+ `/tmp/sales_0813_timed.json`（no/t_sec/t0）。

### 测试 / 构建结果
（本阶段执行后填写）
