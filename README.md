# LiveBook AI

macOS 直播图书智能识别系统 —— **Phase 1：屏幕/回放捕获 + Vision OCR + ISBN + 最佳画面**

## 架构

```text
FrameSource (protocol)
 ├── ScreenCaptureSource   ← SCStream（真实直播窗口，Phase 1 后期接入）
 └── ReplayFileSource      ← AVAssetReader 解码 mp4（本阶段默认）
              ↓
     AdaptiveFrameSampler (2/5/0.5 FPS)
              ↓
     Vision OCR → ISBNParser → BestFrameSelector → SwiftData/AssetStore
```

设计要点：
- **回放优先**：Phase 1 默认用回放文件模拟直播窗口，后续无缝切换为 ScreenCaptureKit，OCR 管线零改动。
- 全链路 FrameSource 抽象，未来 ASR/Book Matrix/打印等均通过 `Protocols.swift` 接入。

## 构建与运行

```bash
cd mac-app/LiveBookAI
xcodebuild -project LiveBookAI.xcodeproj -scheme LiveBookAI -configuration Debug build
xcodebuild -project LiveBookAI.xcodeproj -scheme LiveBookAI test
open mac-app/LiveBookAI/build/.../LiveBookAI.app   # 或用 Xcode 打开后运行
```

首次运行时授予「屏幕录制」权限（仅真实窗口模式需要；回放模式不需要）。

## Phase 1 功能
- 可捕获源列表（回放文件 / 屏幕窗口占位）
- 回放控制：倍速 1x–32x、跳转、暂停
- 实时预览 + OCR 包围框叠加
- 当前 OCR 文本 / ISBN / 置信度 / FPS / 延迟
- 最佳画面自动评分与保存（清晰度 + 置信度 + ISBN）
- 基准校验模式：自动核对 0813 全 51 本

## 目录
```
mac-app/LiveBookAI/
├── LiveBookAI/     App 源码（Capture/Vision/Models/Services/UI）
├── LiveBookAITests/ 单元测试
└── LiveBookAI.xcodeproj
docs/               规格与开发日志
```

详见 `docs/LIVEBOOK_AI_MACOS_SPEC.md`。
