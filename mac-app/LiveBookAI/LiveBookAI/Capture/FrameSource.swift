import Foundation
import CoreVideo
import CoreGraphics

/// A single frame delivered by a FrameSource.
struct FrameSourceOutput: @unchecked Sendable {
    /// Media timestamp in seconds.
    let timestamp: TimeInterval
    /// Retained pixel buffer (BGRA).
    let pixelBuffer: CVPixelBuffer
}

/// A chunk of captured audio (16 kHz mono float PCM in [-1, 1]).
struct AudioChunk: @unchecked Sendable {
    /// Media timestamp in seconds.
    let timestamp: TimeInterval
    /// PCM samples.
    let samples: [Float]
}

/// Identifies a capturable source.
enum CaptureSource: Hashable, Sendable {
    /// Replay video file (simulated live window).
    case replay(url: URL)
    /// Real screen/window via ScreenCaptureKit.
    case screen(windowID: CGWindowID, title: String)
}

/// A source that emits video frames. All sources produce the same output shape so the
/// OCR pipeline is source-agnostic.
protocol FrameSource: AnyObject {
    /// Unique identity.
    var sourceID: UUID { get }
    /// Human-readable name.
    var displayName: String { get }
    /// Kind discriminator.
    var kind: CaptureSource { get }
    /// Callback invoked on the source's delivery queue for each captured frame.
    var onFrame: (@Sendable (FrameSourceOutput) -> Void)? { get set }
    /// Callback invoked for each captured audio chunk (optional for video-only sources).
    var onAudio: (@Sendable (AudioChunk) -> Void)? { get set }
    /// Callback invoked when the stream ends or errors.
    var onEnd: (@Sendable (Error?) -> Void)? { get set }
    /// Start producing frames. Returns error immediately if start fails.
    func start() throws
    /// Stop producing frames.
    func stop()
}
