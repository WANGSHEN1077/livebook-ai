import Foundation
import AVFoundation
import CoreVideo
import CoreGraphics

/// Reads frames from a video file via AVAssetReader to simulate a live window.
/// Supports speed multiplier (1x-32x) and seeking.
final class ReplayFileSource: FrameSource {
    let sourceID = UUID()
    let url: URL
    var kind: CaptureSource { .replay(url: url) }
    var displayName: String { url.lastPathComponent }

    var onFrame: (@Sendable (FrameSourceOutput) -> Void)?
    var onAudio: (@Sendable (AudioChunk) -> Void)?
    var onEnd: (@Sendable (Error?) -> Void)?

    // MARK: - State

    private let queue = DispatchQueue(label: "com.livebook.replay", qos: .userInitiated)
    private var asset: AVURLAsset
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var duration: Double = 0
    private var isRunning = false
    private var timer: DispatchSourceTimer?

    /// Current playhead position (media seconds).
    private(set) var playhead: Double = 0
    /// Playback speed multiplier (1.0 ... 32.0).
    private(set) var speed: Double = 1.0
    /// Frame delivery cadence target (Hz) at speed 1.0.
    private let tickRate: Double = 30
    /// Max pending frames to keep from the reader before discarding (prevents unbounded buffering).
    private let maxQueueDepth = 4

    init(url: URL) {
        self.url = url
        self.asset = AVURLAsset(url: url)
    }

    // MARK: - FrameSource

    func start() throws {
        queue.sync {
            self.ensureReader()
            self.isRunning = true
        }
        startTimer()
    }

    func stop() {
        queue.sync {
            self.isRunning = false
            self.timer?.cancel()
            self.timer = nil
            self.reader?.cancelReading()
            self.reader = nil
            self.output = nil
        }
    }

    func seek(to time: Double) {
        queue.async {
            self.playhead = min(max(0, time), self.duration)
            self.rebuildReader()
        }
    }

    func setSpeed(_ newSpeed: Double) {
        speed = min(32.0, max(1.0, newSpeed))
    }

    /// Loads asset duration. Returns nil if unknown. Called before start.
    func loadDuration() -> Double? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Double?
        Task {
            if let d = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(d)
                if seconds.isFinite, seconds > 0 { result = seconds }
            }
            semaphore.signal()
        }
        semaphore.wait()
        duration = result ?? 0
        return result
    }

    // MARK: - Reader management

    private func ensureReader() {
        if reader == nil { buildReader(at: playhead) }
    }

    private func rebuildReader() {
        reader?.cancelReading()
        reader = nil
        output = nil
        buildReader(at: playhead)
    }

    private func buildReader(at time: Double) {
        do {
            let r = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            guard let track = asset.tracks(withMediaType: .video).first else {
                onEnd?(nil)
                return
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            out.alwaysCopiesSampleData = false
            if r.canAdd(out) {
                r.add(out)
            } else {
                onEnd?(nil)
                return
            }
            r.timeRange = CMTimeRange(start: CMTime(seconds: time, preferredTimescale: 600),
                                      duration: CMTime(seconds: duration - time, preferredTimescale: 600))
            r.startReading()
            reader = r
            output = out
        } catch {
            onEnd?(error)
        }
    }

    // MARK: - Timer loop

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / tickRate)
        t.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = t
        t.resume()
    }

    private func tick() {
        guard isRunning, let output else { return }
        let step = speed / tickRate
        let target = playhead + step

        var latest: CVPixelBuffer?
        var latestTS: Double = playhead
        var discarded = 0

        while let sample = output.copyNextSampleBuffer() {
            let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard let buf = CMSampleBufferGetImageBuffer(sample) else {
                discarded += 1
                if discarded > 32 { break }   // guard against runaway
                continue
            }
            latest = buf
            latestTS = ts
            if ts >= target { break }
        }

        // Detect end of media.
        if latest == nil, let reader, reader.status == .completed || reader.status == .failed {
            finish()
            return
        }

        guard let buf = latest else { return }
        playhead = target

        let frame = FrameSourceOutput(timestamp: latestTS, pixelBuffer: buf)
        // Deliver only if the pipeline is ready; FramePipeline handles its own backpressure.
        onFrame?(frame)
    }

    private func finish() {
        isRunning = false
        timer?.cancel()
        timer = nil
        onEnd?(nil)
    }
}
