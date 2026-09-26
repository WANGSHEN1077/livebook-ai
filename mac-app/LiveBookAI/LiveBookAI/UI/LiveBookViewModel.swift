import SwiftUI
import AppKit
import CoreGraphics
import AVFoundation
import CoreVideo

@MainActor
final class LiveBookViewModel: ObservableObject {
    // MARK: - Published UI state

    @Published var currentOCR: OCRResult?
    /// OCR text of the book display area only (danmaku column excluded),
    /// one recognized line per row. What the "当前商品" panel shows.
    @Published var currentItemText: String = ""
    @Published var latestFrame: CGImage?
    @Published var bestFrame: CGImage?
    @Published var bestKind: MediaAssetKind = .coverBest
    @Published var captureFPS: Double = 0
    @Published var ocrFPS: Double = 0
    @Published var ocrLatency: Double = 0
    @Published var isCapturing = false
    @Published var statusMessage: String?
    @Published var statusIsError = false

    // Replay controls
    @Published var replayURL: URL?
    @Published var playbackSpeed: Double = 1.0
    @Published var playhead: Double = 0
    @Published var duration: Double = 0

    // Validation
    @Published var isValidating = false
    @Published var validationSummary: ValidationSummary?
    @Published var validationProgress: Double = 0

    // Live capture (real WeChat live window)
    @Published var availableWindows: [(id: CGWindowID, title: String)] = []
    @Published var isLoadingWindows = false
    @Published var isCapturingLive = false
    @Published var liveTranscript: String = ""
    @Published var recognizedBooks: [String] = []
    @Published var selectedWindowID: CGWindowID?
    @Published var liveWindowID: CGWindowID?

    // Live auction parsing + OCR aggregation
    @Published var auctionRecords: [AuctionRecord] = []
    @Published var coverCandidates: [String] = []
    @Published var danmakuLines: [String] = []
    @Published var auxPrice: Int?
    @Published var auxBuyer: String?

    // R1: real-time danmaku bids (right column)
    @Published var danmakuCurrentBids: [DanmakuBid] = []
    @Published var danmakuSettledWindows: [DanmakuWindow] = []

    // R2: settlement signals detected from streaming ASR (debug/实时列表)
    @Published var settlementEvents: [String] = []

    @Published var needsScreenPermission = false

    func selectWindowID(_ id: CGWindowID) {
        selectedWindowID = id
    }

    /// Pick the window most likely to be the WeChat 视频号 live stream.
    /// Prefers explicit 视频号 keywords, then WeChat; falls back to any title.
    func autoSelectWeChatWindow() {
        let w = availableWindows.first { $0.title.contains("视频号") }
            ?? availableWindows.first { $0.title.contains("微信") }
            ?? availableWindows.first
        if let w {
            selectedWindowID = w.id
        }
    }

    func startLiveCaptureFromSelectedWindow() {
        guard let id = selectedWindowID else {
            statusMessage = "请先选择直播窗口"
            statusIsError = true
            return
        }
        let title = availableWindows.first { $0.id == id }?.title ?? "直播窗口"
        liveWindowID = id
        startLiveCapture(windowID: id, title: title)
    }

    // MARK: - Internals

    private var source: FrameSource?
    private let pipeline: FramePipeline
    private let dataStore: DataStore?
    private let assetStore = AssetStore()
    private var session: CaptureSession?

    private var liveTranscriber: SherpaTranscriptionService.LiveTranscriber?
    private let transcriptionService = SherpaTranscriptionService()
    private var bookTitles: [String] = []
    /// Dedup cache for transcript hits, written only from the audio callback queue.
    nonisolated(unsafe) private var recognizedBooksCache: [String] = []
    /// Snapshot of the book catalog for the (nonisolated) audio callback.
    nonisolated(unsafe) private var bookTitlesSnapshot: [String] = []
    /// Live-mode flag readable from nonisolated capture callbacks.
    nonisolated(unsafe) private var isLiveParsing = false
    /// Auction parser (audio + OCR), safe to access from the capture queues.
    nonisolated(unsafe) private let auctionParser = LiveAuctionParser()
    /// R1: real-time danmaku bid ladder parser (right column OCR lines).
    nonisolated(unsafe) private let danmakuParser = DanmakuBidParser()
    /// R2: settlement signal detector on the streaming ASR transcript.
    nonisolated(unsafe) private let signalDetector = SettlementSignalDetector()
    /// Length of the transcript already fed to the signal detector.
    nonisolated(unsafe) private var lastTranscriptLen = 0
    /// Cover region in normalized Vision coords (matches ValidationRunner.coverCrop).
    private let coverRect = CGRect(x: 0.12, y: 0.28, width: 0.76, height: 0.50)

    private let captureQueue = DispatchQueue(label: "com.livebook.frames", qos: .userInitiated)

    /// 默认回放视频路径：优先取环境变量 `LIVEBOOK_REPLAY`，否则回落到当前
    /// 用户主目录下的工程内回放文件（避免硬编码个人绝对路径）。
    static var defaultReplayPath: String {
        if let override = ProcessInfo.processInfo.environment["LIVEBOOK_REPLAY"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/Documents/livebook-ai/mac-app/LiveBookAI/media/直播回放-08月13日.mp4"
    }

    init() {
        let ocr = OCRService()
        pipeline = FramePipeline(ocr: ocr)
        dataStore = try? DataStore()
        pipeline.delegate = self
    }

    /// Catalog of candidate book titles used for live recognition (from 0813 ground truth).
    func loadBookCatalog() {
        guard bookTitles.isEmpty, let items = try? GroundTruthLoader.load() else { return }
        bookTitles = items.map(\.title)
        bookTitlesSnapshot = bookTitles
    }

    /// Enumerate capturable windows (async, runs off the main actor).
    func loadWindows(autoSelect: Bool = false) async {
        isLoadingWindows = true
        defer { isLoadingWindows = false }
        do {
            let windows = try await ScreenCaptureManager.availableWindows()
            availableWindows = windows
            if autoSelect {
                autoSelectWeChatWindow()
            }
        } catch {
            if let scErr = error as? ScreenCaptureError, case .permissionDenied = scErr {
                needsScreenPermission = true
                statusMessage = "需要屏幕录制权限：请到 系统设置 → 隐私与安全性 → 屏幕录制 允许本 App，然后重新启动 App。首次允许后只需一次。"
            } else {
                statusMessage = "无法枚举窗口: \(error.localizedDescription)"
            }
            statusIsError = true
        }
    }

    /// Open the macOS Screen Recording settings pane.
    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Start real-time capture + recognition from a live window.
    func startLiveCapture(windowID: CGWindowID, title: String) {
        guard !isCapturing else { return }
        loadBookCatalog()
        recognizedBooks = []
        recognizedBooksCache = []
        liveTranscript = ""
        auctionParser.clear()
        auctionRecords = []
        coverCandidates = []
        danmakuLines = []
        auxPrice = nil
        auxBuyer = nil
        danmakuParser.reset()
        danmakuCurrentBids = []
        danmakuSettledWindows = []
        signalDetector.reset()
        lastTranscriptLen = 0
        settlementEvents = []

        let capture = ScreenCaptureManager(windowID: windowID, title: title)
        session = dataStore?.createSession(sourceKind: "live", sourceName: title)
        source = capture
        pipeline.reset()
        isCapturing = true
        isCapturingLive = true
        isLiveParsing = true
        statusMessage = "正在实时识别直播窗口: \(title)"
        statusIsError = false

        let transcriber = transcriptionService.makeLiveTranscriber()
        liveTranscriber = transcriber

        capture.onFrame = { [weak self] output in
            self?.pipeline.ingest(output)
        }
        capture.onAudio = { [weak self] chunk in
            self?.handleAudio(chunk: chunk, transcriber: transcriber)
        }
        capture.onEnd = { [weak self] error in
            self?.pipeline.finish(error: error)
        }

        do {
            try capture.start()
        } catch {
            stopCapture()
            statusMessage = "启动失败: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    /// Feed audio to the streaming transcriber, match catalog titles, and run
    /// the auction parser (buyer + price extraction).
    nonisolated private func handleAudio(chunk: AudioChunk, transcriber: SherpaTranscriptionService.LiveTranscriber?) {
        guard let transcriber else { return }
        let text = transcriber.feed(samples: chunk.samples)
        let time = chunk.timestamp

        // R2: incremental transcript → settlement signal detector.
        let delta = String(text.dropFirst(lastTranscriptLen))
        if !delta.isEmpty {
            lastTranscriptLen = text.count
            let signals = signalDetector.ingest(text: delta, timestamp: time)
            if !signals.isEmpty {
                let descriptions = signals.map { SettlementSignalDetector.describe($0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.settlementEvents.insert(contentsOf: descriptions, at: 0)
                    if self.settlementEvents.count > 100 {
                        self.settlementEvents.removeLast(50)
                    }
                }
            }
        }

        let recent = String(text.suffix(400))
        var newMatches: [String] = []
        for title in bookTitlesSnapshot where !recognizedBooksCache.contains(title) {
            if TitleMatcher.transcriptMatches(spoken: recent, expectedTitle: title) {
                newMatches.append(title)
                recognizedBooksCache.append(title)
            }
        }
        // Auction parser: buyer / price from spoken text.
        let settled = auctionParser.ingestSpoken(text, at: time)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.liveTranscript = String(text.suffix(200))
            if !newMatches.isEmpty {
                self.recognizedBooks.append(contentsOf: newMatches)
                self.statusMessage = "识别到书名: \(newMatches.joined(separator: "、"))"
                self.statusIsError = false
            }
            if !settled.isEmpty {
                self.auctionRecords.insert(contentsOf: settled, at: 0)
            }
            self.refreshAuctionSnapshot()
        }
    }

    /// Feed OCR observations for cover-title aggregation + danmaku extraction.
    nonisolated private func handleOCR(_ observations: [OCRObservation], timestamp: TimeInterval) {
        auctionParser.ingestOCR(observations, at: timestamp, coverRect: coverRect)
        // R1: route right-column danmaku lines into the bid parser.
        var danmakuEvents: [DanmakuBidParserEvent] = []
        for obs in observations where DanmakuRegion.contains(obs) {
            danmakuEvents.append(contentsOf: danmakuParser.ingest(text: obs.text, timestamp: timestamp))
        }
        DispatchQueue.main.async { [weak self] in
            self?.refreshAuctionSnapshot()
            self?.refreshDanmakuSnapshot()
        }
    }

    /// Publish the danmaku parser state to the UI on the main actor.
    private func refreshDanmakuSnapshot() {
        let snap = danmakuParser.snapshot()
        danmakuCurrentBids = snap.current?.bids ?? []
        danmakuSettledWindows = snap.settled
    }

    /// Publish the parser snapshot to the UI on the main actor.
    private func refreshAuctionSnapshot() {
        let snap = auctionParser.snapshot()
        auctionRecords = snap.records
        coverCandidates = Array(snap.covers.suffix(40).reversed())
        danmakuLines = Array(snap.danmaku.suffix(60).reversed())
        let lastSettled = snap.records.first
        auxPrice = lastSettled?.price
        auxBuyer = lastSettled?.buyer
    }

    /// Load the default replay file (Phase 1 simulation of a live window).
    func loadDefaultReplay() {
        let url = URL(fileURLWithPath: Self.defaultReplayPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusMessage = "未找到默认回放文件: \(url.path)\n请在界面中选择其他文件。"
            statusIsError = true
            return
        }
        replayURL = url
        statusMessage = "已加载回放: \(url.lastPathComponent)"
        statusIsError = false
    }

    func pickReplayFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audiovisualContent]
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.replayURL = url
            self.statusMessage = "已选择: \(url.lastPathComponent)"
            self.statusIsError = false
        }
    }

    func startCapture() {
        guard !isCapturing else { return }
        guard let url = replayURL else {
            statusMessage = "请先选择回放文件"
            statusIsError = true
            return
        }

        let replay = ReplayFileSource(url: url)
        _ = replay.loadDuration()
        duration = replayDuration(from: url) ?? 0
        replay.setSpeed(playbackSpeed)
        session = dataStore?.createSession(sourceKind: "replay", sourceName: url.lastPathComponent)
        source = replay
        pipeline.reset()
        danmakuParser.reset()
        danmakuCurrentBids = []
        danmakuSettledWindows = []
        signalDetector.reset()
        lastTranscriptLen = 0
        settlementEvents = []
        isCapturing = true
        statusMessage = "捕获中: \(url.lastPathComponent)"
        statusIsError = false

        replay.onFrame = { [weak self] output in
            self?.pipeline.ingest(output)
            DispatchQueue.main.async { [weak self] in
                self?.playhead = output.timestamp
            }
        }
        replay.onEnd = { [weak self] error in
            self?.pipeline.finish(error: error)
        }

        do {
            try replay.start()
        } catch {
            isCapturing = false
            statusMessage = "启动失败: \(error.localizedDescription)"
            statusIsError = true
        }
    }

    func stopCapture() {
        source?.stop()
        source = nil
        liveTranscriber?.destroy()
        liveTranscriber = nil
        if let session {
            dataStore?.endSession(session)
        }
        isCapturing = false
        isCapturingLive = false
        isLiveParsing = false
        statusMessage = "已停止捕获"
        statusIsError = false
    }

    func seek(to time: Double) {
        guard let replay = source as? ReplayFileSource else { return }
        pipeline.reset(seekTime: time)
        replay.seek(to: time)
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = speed
        (source as? ReplayFileSource)?.setSpeed(speed)
    }

    // MARK: - Validation

    func runValidation() {
        guard let url = replayURL else {
            statusMessage = "请先选择回放文件再运行校验"
            statusIsError = true
            return
        }
        guard !isValidating else { return }
        isValidating = true
        validationSummary = nil
        validationProgress = 0
        statusMessage = "基准校验运行中…"
        statusIsError = false

        Task.detached { [weak self] in
            guard let self else { return }
            do {
                let items = try GroundTruthLoader.load()
                let runner = ValidationRunner()
                let summary = try await runner.run(items: items, videoURL: url) { done, total in
                    Task { @MainActor in
                        self.validationProgress = Double(done) / Double(total)
                    }
                }
                Task { @MainActor in
                    self.isValidating = false
                    self.validationSummary = summary
                    self.statusMessage = "校验完成: \(summary.matched)/\(summary.total) 命中"
                    self.statusIsError = summary.failed > 0
                    self.persistValidation(summary)
                }
            } catch {
                Task { @MainActor in
                    self.isValidating = false
                    self.statusMessage = "校验失败: \(error.localizedDescription)"
                    self.statusIsError = true
                }
            }
        }
    }

    private func persistValidation(_ summary: ValidationSummary) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("LiveBookAI/validation", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("validation_\(Date().timeIntervalSince1970).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(summary) {
            try? data.write(to: url)
        }
    }

    // MARK: - Persistence of best frames

    private func persistBest(image: CGImage, kind: MediaAssetKind, frame: ScoredFrame) {
        guard let session else { return }
        if let url = assetStore.save(image: image, sessionID: session.id, kind: kind, timestamp: frame.timestamp) {
            let asset = MediaAsset(kind: kind.rawValue,
                                   filePath: url.path,
                                   width: Int(frame.pixelSize.width),
                                   height: Int(frame.pixelSize.height),
                                   sharpness: frame.sharpness,
                                   ocrConfidence: frame.ocrConfidence,
                                   ocrText: currentOCR?.text ?? "",
                                   timestamp: frame.timestamp,
                                   session: session)
            dataStore?.recordMediaAsset(asset, session: session)
        }
    }

    private func replayDuration(from url: URL) -> Double? {
        let asset = AVURLAsset(url: url)
        let semaphore = DispatchSemaphore(value: 0)
        var duration: Double?
        Task {
            if let d = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(d)
                if seconds.isFinite, seconds > 0 { duration = seconds }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return duration
    }
}

// MARK: - FramePipelineDelegate

extension LiveBookViewModel: FramePipelineDelegate {
    nonisolated func pipeline(_ pipeline: FramePipeline, didProduce result: OCRResult) {
        // Collect cover candidates + danmaku in both live and replay modes so
        // the danmaku panel scrolls during replay too.
        if !result.observations.isEmpty {
            handleOCR(result.observations, timestamp: result.timestamp)
        }
        Task { @MainActor in
            self.currentOCR = result
            self.currentItemText = result.bookAreaText()
            self.ocrLatency = result.latency
            self.captureFPS = pipeline.captureFPS
            self.ocrFPS = pipeline.ocrFPS
            if !result.text.isEmpty {
                do {
                    let t = String(result.text.prefix(120))
                    let obs = result.observations.map { o in
                        String(format: "(%.2f,%.2f,%.2f,%.2f)%@", o.boundingBox.minX, o.boundingBox.minY, o.boundingBox.maxX, o.boundingBox.maxY, String(o.text.prefix(40)))
                    }.joined(separator: " | ")
                    let entry = String(format: "%.1f\t%d\t%@\t%@\n", result.timestamp, result.observations.count, t, obs)
                    let fh = try FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/ocr_diag.txt"))
                    fh.seekToEndOfFile()
                    fh.write(entry.data(using: .utf8) ?? Data())
                    try fh.close()
                } catch {
                    FileManager.default.createFile(atPath: "/tmp/ocr_diag.txt", contents: "".data(using: .utf8))
                }
            }
        }
    }

    nonisolated func pipeline(_ pipeline: FramePipeline, didSelectBest frame: ScoredFrame, kind: MediaAssetKind, image: CGImage) {
        Task { @MainActor in
            self.bestFrame = image
            self.bestKind = kind
            self.persistBest(image: image, kind: kind, frame: frame)
        }
    }

    nonisolated func pipelineDidEnd(_ pipeline: FramePipeline, error: Error?) {
        Task { @MainActor in
            self.isCapturing = false
            self.isCapturingLive = false
            if let error {
                self.statusMessage = "流结束: \(error.localizedDescription)"
                self.statusIsError = true
            } else {
                self.statusMessage = "回放结束"
                self.statusIsError = false
            }
            if let session = self.session {
                self.dataStore?.endSession(session)
            }
        }
    }
}
