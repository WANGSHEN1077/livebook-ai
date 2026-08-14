# LiveBook AI — macOS 直播图书智能识别系统

**版本：v1.0**
**平台：macOS**
**目标机器：M4 MacBook Air 16GB / Intel A2141**
**开发：Swift + SwiftUI + Python/FastAPI**

---

# 1. 项目目标

开发一个 macOS App：

```text
微信直播 / 浏览器直播 / 其他直播窗口
                 ↓
          ScreenCaptureKit
                 ↓
          实时视频帧
           ↙         ↘
       Vision OCR    图片采集
           ↓
      书名 / ISBN
                 ↓
        Book Matrix 匹配
                 ↓
        + 主播语音 ASR
                 ↓
           交易事件分析
          ↙             ↘
       成交               流标
        ↓                  ↓
     自动打印          二次销售池
        ↓                  ↓
      发货             孔夫子草稿
```

---

# 2. 最重要的设计

## 不获取微信内部直播流

第一版只做：

> **捕获用户屏幕上正常显示的直播窗口。**

使用：

```text
ScreenCaptureKit
```

因此不需要：

- 破解微信
- 获取内部直播 URL
- 修改微信客户端
- 逆向直播协议

---

# 3. 两种模式

## Mode A：观看别人的直播

输入：

```text
微信窗口
```

系统：

```text
屏幕画面
 ↓
OCR
 ↓
图片
```

同时：

```text
系统音频
 ↓
ASR
```

然后分析成交/流标。

## Mode B：自己的直播

如果有：

- 原始回放
- 音频
- 弹幕

则直播结束后进行：

```text
Replay AI
```

对实时结果进行第二次校对。

---

# 4. macOS 技术栈

核心：

```text
Swift
SwiftUI
ScreenCaptureKit
Vision
AVFoundation
CoreImage
CoreML
```

后台：

```text
Python
FastAPI
WebSocket
SQLite/PostgreSQL
```

第一版：

```text
Swift App
    ↓
localhost
    ↓
FastAPI
```

---

# 5. 视频捕获

使用：

```text
SCShareableContent
```

列出：

- 屏幕
- 窗口
- App

用户选择：

```text
微信
```

然后：

```text
SCStream
```

输出：

```text
CMSampleBuffer
```

---

# 6. 视频处理

不要：

```text
30 FPS
 ↓
30次 OCR
```

而应该：

```text
30 FPS Capture
       ↓
Frame Change Detector
       ↓
2 FPS OCR
```

画面变化明显：

```text
2 FPS → 5 FPS
```

画面静止：

```text
5 FPS → 0.5 FPS
```

---

# 7. Vision OCR

使用：

```swift
VNRecognizeTextRequest
```

支持：

```text
zh-Hans
zh-Hant
ja-JP
en-US
```

配置：

```text
Fast
Accurate
```

实时阶段优先：

```text
Fast
```

确认商品时：

```text
Accurate
```

---

# 8. ISBN

OCR 结果：

```text
ISBN 9787108025302
```

解析：

```text
9787108025302
```

然后 checksum。

支持：

```text
ISBN-10
ISBN-13
EAN-13
```

---

# 9. 最佳图片

一本书出现期间：

```text
Frame 1
Frame 2
Frame 3
...
Frame N
```

计算：

```text
sharpness
OCR confidence
book area
ISBN confidence
blur
occlusion
```

选最佳：

```text
cover_best
isbn_best
copyright_best
back_best
```

---

# 10. 图片的重要用途

流标之后：

```text
PASSED
 ↓
最佳封面
 ↓
Book Matrix
 ↓
孔夫子草稿
```

因此：

> **直播过程中已经完成商品摄影。**

无需重新拍照。

---

# 11. 音频

macOS 使用：

```text
ScreenCaptureKit
```

同时获取：

```text
屏幕视频
系统音频
```

如果系统/权限环境不适合，则使用：

```text
AVAudioEngine
```

或独立音频输入。

---

# 12. ASR

Provider：

```text
ASRProvider
```

实现：

```text
WhisperProvider
AppleSpeechProvider
RemoteASRProvider
```

第一版推荐：

```text
Whisper
```

M4 Air 上优先测试：

```text
Whisper small
```

如果延迟允许：

```text
Whisper medium
```

---

# 13. ASR 输出

```json
{
  "text": "日本美术全集第十二卷，三百块",
  "start": 321.1,
  "end": 324.2,
  "confidence": 0.92
}
```

必须保留时间戳。

---

# 14. OCR + ASR 时间轴

所有信息统一：

```text
timestamp
```

例如：

```text
20:31:20
OCR：日本美術全集

20:31:23
ASR：第十二卷

20:31:25
ASR：三百块

20:31:28
ASR：张三给你
```

系统最终：

```text
日本美術全集 第12卷
买家：张三
成交价：300
```

---

# 15. 当前商品状态

```text
DETECTED
 ↓
INTRODUCING
 ↓
BIDDING
 ↓
SOLD
```

或者：

```text
BIDDING
 ↓
PASSED
```

异常：

```text
CANCELLED
NEEDS_REVIEW
```

---

# 16. 成交识别

例如主播：

> “张三，三百给你。”

解析：

```text
buyer = 张三
price = 300
status = SOLD
```

但是不能仅仅因为出现：

> “三百”

就判断成交。

必须结合：

```text
当前商品
+
价格
+
成交语义
```

---

# 17. 流标识别

关键词：

```text
没人要
流了
流标
没人拍
下一本
撤拍
```

如果没有成交：

```text
status = PASSED
```

---

# 18. 低置信度

例如：

```text
买家：？
价格：300
状态：？
```

显示：

```text
NEEDS_REVIEW
```

人工确认。

---

# 19. 自动打印

成交：

```text
SALE_CONFIRMED
 ↓
SalesOrder
 ↓
PrintJob
```

打印：

```text
====================
      成交单
====================

商品：
日本美術全集 第12巻

ISBN：
9787108025302

买家：
张三

成交价：
¥300

订单号：
LIVE-20260814-0031

====================
```

---

# 20. 流标打印

可选：

```text
====================
      流标
====================

商品：
日本美術全集 第12巻

ISBN：
9787108025302

状态：
二次销售

====================
```

直接夹进书里。

---

# 21. 打印机

第一版：

```text
macOS System Printer
```

第二版：

```text
ESC/POS
```

接口：

```text
PrinterProvider
```

保证：

```text
同一个订单
不能重复自动打印。
```

---

# 22. Book Matrix

建立：

```text
BookMatrixClient
```

接口：

```text
findByISBN()
findByTitle()
findByImage()
createOrder()
attachImage()
createKongfzDraft()
```

第一阶段全部：

```text
Mock
```

等你提供现有 Book Matrix API 后再接。

---

# 23. 流标二次销售

```text
直播
 ↓
书籍识别
 ↓
图片保存
 ↓
流标
 ↓
SecondarySale
 ↓
Book Matrix
 ↓
孔夫子商品草稿
```

草稿必须包含：

```text
书名
ISBN
作者
出版社
图片
品相
直播时间
原起拍价
```

第一版：

> **只生成草稿，不自动发布。**

---

# 24. 自有直播 Replay

直播结束后：

```text
直播回放
+
音频
+
弹幕
+
实时事件
```

重新分析：

```text
Replay OCR
Replay ASR
Chat Parsing
```

然后：

```text
Realtime Result
       +
Replay Result
       ↓
Reconciliation
       ↓
Final Result
```

---

# 25. 数据库

核心表：

```text
sessions
live_items
media_assets
transcripts
events
sales_orders
print_jobs
review_tasks
```

`live_items`：

```sql
id
session_id
sequence_no
title
isbn
author
publisher
opening_price
final_price
buyer
status
confidence
started_at
ended_at
```

---

# 26. UI

主界面：

```text
┌────────────────────────────────────────┐
│ LiveBook AI                            │
│                                        │
│ [直播画面]              当前商品        │
│                         日本美術全集12  │
│                         ISBN ...       │
│                                        │
│                         买家：张三      │
│                         价格：¥300     │
│                         状态：成交      │
├────────────────────────────────────────┤
│ 实时语音                               │
│ “张三，三百给你……”                    │
├────────────────────────────────────────┤
│ 时间线                                 │
│ 20:31 OCR                              │
│ 20:32 ASR                              │
│ 20:33 成交                             │
│ 20:33 已打印                           │
└────────────────────────────────────────┘
```

---

# 27. 目录结构

```text
livebook-ai/
│
├── mac-app/
│   └── LiveBookAI/
│       ├── Capture/
│       ├── Vision/
│       ├── Audio/
│       ├── ASR/
│       ├── Streaming/
│       ├── Printing/
│       ├── Models/
│       ├── Services/
│       └── UI/
│
├── backend/
│   ├── api/
│   ├── database/
│   ├── services/
│   ├── providers/
│   │   ├── ocr/
│   │   ├── asr/
│   │   ├── bookmatrix/
│   │   ├── printer/
│   │   └── llm/
│   ├── replay/
│   └── main.py
│
├── tests/
├── docs/
├── data/
├── scripts/
├── .env.example
└── README.md
```

---

# 28. 开发阶段

### Phase 1

**ScreenCaptureKit + Vision**

只做：

```text
微信窗口
 ↓
ScreenCaptureKit
 ↓
Vision
 ↓
书名
 ↓
ISBN
 ↓
最佳图片
```

### Phase 2

加入：

```text
系统音频
 ↓
Whisper
 ↓
实时字幕
```

### Phase 3

加入：

```text
CurrentLiveItem
```

识别：

```text
下一本
当前书
起拍价
```

### Phase 4

交易：

```text
买家
价格
成交
流标
```

### Phase 5

打印：

```text
成交
 ↓
订单
 ↓
打印
```

### Phase 6

Book Matrix：

```text
ISBN
 ↓
库存
 ↓
商品
 ↓
订单
```

### Phase 7

Replay：

```text
视频
+
ASR
+
OCR
+
弹幕
 ↓
最终校对
```

### Phase 8

流标：

```text
PASSED
 ↓
图片
 ↓
Book Matrix
 ↓
孔夫子 Draft
```

---

# 29. 第一阶段给 OpenCode 的 Prompt

把下面这段**直接丢给 OpenCode**：

```text
请读取 docs/LIVEBOOK_AI_MACOS_SPEC.md。

我要开发一个 macOS 原生应用 LiveBook AI。

当前只开发 Phase 1，不要提前实现后面的功能。

Phase 1 的目标：

捕获用户当前正在观看的直播窗口，例如微信 Mac 客户端窗口，然后使用 Apple Vision 实时识别直播画面中的图书信息。

技术要求：

1. 使用 Swift + SwiftUI。
2. 使用 ScreenCaptureKit。
3. 列出当前可捕获的屏幕、窗口和应用。
4. 用户可以选择一个窗口。
5. 使用 SCStream 捕获窗口。
6. 获取 CMSampleBuffer / CVPixelBuffer。
7. 实现实时预览。
8. 使用 VNRecognizeTextRequest。
9. 支持中文简体、中文繁体和日文。
10. 默认 OCR 频率约 2 FPS。
11. 画面变化明显时允许提高到 5 FPS。
12. 画面不变化时降低到 0.5 FPS。
13. OCR 不能阻塞 ScreenCaptureKit。
14. 使用独立的 Vision processing queue。
15. 设置 alwaysDiscardsLateVideoFrames。
16. OCR worker 忙时丢弃旧帧。
17. 不允许无限缓存 CVPixelBuffer。
18. 实现 ISBN-10 / ISBN-13 parser。
19. 实现 ISBN checksum。
20. OCR 结果必须带 confidence。
21. OCR 结果必须带 boundingBox。
22. 在视频画面上显示 OCR bounding boxes。
23. 自动保存最佳图书画面。
24. 保存原始 frame 和处理后的图片。
25. 为图片计算 sharpness。
26. 为图片计算 OCR confidence。
27. 建立 BookCandidate 数据模型。
28. 建立 MediaAsset 数据模型。
29. 建立 OCRResult 数据模型。
30. 所有数据必须保存 timestamp。
31. 使用 SwiftData 或 SQLite 做本地缓存。
32. 第一阶段不需要 ASR。
33. 第一阶段不需要 Whisper。
34. 第一阶段不需要交易识别。
35. 第一阶段不需要打印。
36. 第一阶段不需要 Book Matrix。
37. 第一阶段不需要孔夫子。
38. 第一阶段不需要 LLM。
39. 所有未来服务都通过 protocol/interface 抽象。
40. 不要把任何 API key 写入代码。

UI 至少包含：

- 可捕获窗口列表
- 开始捕获
- 停止捕获
- 直播预览
- OCR bounding boxes
- 当前 OCR 文本
- ISBN
- OCR confidence
- 最佳图片
- 当前 FPS
- OCR latency

性能要求：

- 不允许 OCR 阻塞视频捕获。
- 不允许帧队列无限增长。
- OCR worker 忙时丢弃旧帧。
- UI 不允许因为 OCR 错误崩溃。
- ScreenCaptureKit 出错时可以重新启动。
- 权限不足时给出明确提示。

请先检查当前 repository。

如果 repository 为空，则创建完整项目结构。

完成后：

1. 编译。
2. 运行测试。
3. 测试 ISBN parser。
4. 测试 ISBN checksum。
5. 测试 OCR 数据模型。
6. 测试 frame sampling。
7. 测试最佳图片评分。
8. 更新 README。
9. 更新开发日志。
10. 输出实际测试结果。

不要实现 Phase 2。
```

---

## 最终架构

```text
                微信/其他直播
                       │
                       ▼
                Mac ScreenCaptureKit
                       │
             ┌─────────┴─────────┐
             ▼                   ▼
         Vision OCR             系统音频
             │                   │
             ▼                   ▼
        书名/ISBN               Whisper
             │                   │
             └─────────┬─────────┘
                       ▼
                 Event Fusion
                       │
              ┌────────┴────────┐
              ▼                 ▼
             成交               流标
              │                 │
              ▼                 ▼
          自动打印          保存直播图片
                                │
                                ▼
                           Book Matrix
                                │
                                ▼
                          孔夫子商品草稿
```

---

# Phase 1 实施方案（回放优先，本项目实际执行）

> 经确认，Phase 1 以**回放文件模拟直播窗口**为默认帧源，后续可无缝切换为 ScreenCaptureKit 真实窗口。

```text
FrameSource (protocol)
 ├── ScreenCaptureSource   ← SCStream（真实直播窗口，Phase 1 后期接入）
 └── ReplayFileSource      ← AVAssetReader 解码 mp4（本阶段默认）
              ↓
     AdaptiveFrameSampler (2/5/0.5 FPS)
              ↓
     Vision OCR → ISBNParser → BestFrameSelector → SwiftData/AssetStore
```

- 回放文件支持：倍速 1x–32x、seek 跳转到任意时刻。
- 基准校验模式：读取 0813.csv（书名）+ sales_0813_timed.json（no/t_sec）合并为 51 条基准，逐本跳转到起拍时刻跑 OCR 比对，输出命中/未命中清单。
- 默认回放路径：`/Users/wangshen/Downloads/直播回放-08月13日.mp4`。
