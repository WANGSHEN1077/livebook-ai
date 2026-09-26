import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreVideo
import CoreMedia
/// Error types surfaced when screen capture cannot be started.
enum ScreenCaptureError: LocalizedError {
    case permissionDenied
    case noContent
    case streamFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "屏幕录制权限被拒绝。请在 系统设置 → 隐私与安全性 → 屏幕录制 中允许本 App。"
        case .noContent:
            return "没有可捕获的屏幕或窗口。"
        case .streamFailed(let m):
            return "ScreenCaptureKit 启动失败: \(m)"
        }
    }
}

/// Capable of enumerating capturable windows and starting a real SCStream.
/// Captures both video and system audio (the app's audio track) for live
/// transcription.
final class ScreenCaptureManager: NSObject, FrameSource, SCStreamOutput {
    private let sourceIDValue = UUID()
    var onFrame: (@Sendable (FrameSourceOutput) -> Void)?
    var onAudio: (@Sendable (AudioChunk) -> Void)?
    var onEnd: (@Sendable (Error?) -> Void)?

    private let stateLock = NSLock()
    private var isStreamingValue = false
    private var stream: SCStream?

    var sourceID: UUID { sourceIDValue }
    var displayName: String { windowTitle }
    var kind: CaptureSource { .screen(windowID: windowID, title: windowTitle) }
    var isStreaming: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isStreamingValue
    }

    private let windowID: CGWindowID
    private let windowTitle: String

    init(windowID: CGWindowID, title: String) {
        self.windowID = windowID
        self.windowTitle = title
        super.init()
    }

    // MARK: - FrameSource

    func start() throws {
        guard !isStreaming else { return }
        // SCShareableContent APIs are async; bridge to sync for the FrameSource contract.
        let semaphore = DispatchSemaphore(value: 0)
        var contentResult: SCShareableContent?
        var contentError: Error?
        Task {
            do {
                contentResult = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            } catch {
                contentError = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let contentError { throw contentError }
        guard let content = contentResult,
              let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw ScreenCaptureError.noContent
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // max 5 FPS
        config.queueDepth = 2
        config.showsCursor = false
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        self.stream = stream
        stream.startCapture { [weak self] error in
            guard let self else { return }
            if let error {
                self.onEnd?(error)
            } else {
                self.stateLock.lock()
                self.isStreamingValue = true
                self.stateLock.unlock()
            }
        }
    }

    func stop() {
        stream?.stopCapture { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            self.isStreamingValue = false
            self.stateLock.unlock()
            self.stream = nil
        }
    }

    // MARK: - Enumeration helper

    static func availableWindows() async throws -> [(CGWindowID, String)] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.windows
            .filter { $0.title?.isEmpty == false }
            .map { ($0.windowID, $0.title ?? "Untitled") }
    }

    /// Whether the app has already been granted screen-recording permission.
    static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of outputType: SCStreamOutputType) {
        switch outputType {
        case .screen:
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            onFrame?(FrameSourceOutput(timestamp: ts, pixelBuffer: pixelBuffer))
        case .audio:
            guard let samples = Self.audioChunk(from: sampleBuffer) else { return }
            let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            onAudio?(AudioChunk(timestamp: ts, samples: samples))
        @unknown default:
            break
        }
    }

    /// Extracts 16 kHz mono float PCM samples from an audio sample buffer.
    /// ScreenCaptureKit delivers float32 audio at the configured rate; if the
    /// rate/channel count differ, resample/downmix to the expected input shape.
    private static func audioChunk(from sampleBuffer: CMSampleBuffer) -> [Float]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt) else { return nil }
        let rate = asbd.pointee.mSampleRate
        guard rate > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer())
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == noErr else { return nil }

        // We configured a single audio buffer; read it directly.
        let buf = audioBufferList.mBuffers
        let byteCount = Int(buf.mDataByteSize)
        guard byteCount > 0, let mData = buf.mData else { return nil }
        let floatCount = byteCount / MemoryLayout<Float>.size
        let ptr = mData.assumingMemoryBound(to: Float.self)
        var samples = Array(UnsafeBufferPointer(start: ptr, count: floatCount))

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        if channels > 1 {
            samples = Self.downmix(samples, channels: channels)
        }
        if abs(rate - 16000.0) > 1 {
            samples = Self.resample(samples, fromRate: rate, toRate: 16000.0)
        }
        return samples
    }

    private static func downmix(_ samples: [Float], channels: Int) -> [Float] {
        guard channels > 1 else { return samples }
        var out: [Float] = []
        out.reserveCapacity(samples.count / channels)
        var i = 0
        while i + channels <= samples.count {
            var sum: Float = 0
            for c in 0..<channels { sum += samples[i + c] }
            out.append(sum / Float(channels))
            i += channels
        }
        return out
    }

    /// Linear interpolation resampling. Sufficient for ASR input.
    private static func resample(_ samples: [Float], fromRate: Double, toRate: Double) -> [Float] {
        guard fromRate != toRate, fromRate > 0, !samples.isEmpty else { return samples }
        let ratio = toRate / fromRate
        let outCount = Int(Double(samples.count) * ratio)
        guard outCount > 0 else { return samples }
        var out = [Float](repeating: 0, count: outCount)
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let lo = Int(src)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(src - Double(lo))
            out[i] = samples[lo] * (1 - frac) + samples[hi] * frac
        }
        return out
    }
}

extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onEnd?(error)
        stateLock.lock()
        isStreamingValue = false
        stateLock.unlock()
    }
}
