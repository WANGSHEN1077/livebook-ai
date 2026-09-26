import Foundation
import CoreGraphics
import CoreVideo

/// Sink that consumes OCR results and best-frame selections.
protocol FramePipelineDelegate: AnyObject {
    /// Called on the main queue with the latest recognized text.
    func pipeline(_ pipeline: FramePipeline, didProduce result: OCRResult)
    /// Called on the main queue with a new best frame.
    func pipeline(_ pipeline: FramePipeline, didSelectBest frame: ScoredFrame, kind: MediaAssetKind, image: CGImage)
    /// Called on the main queue when capture ends.
    func pipelineDidEnd(_ pipeline: FramePipeline, error: Error?)
}

/// Consumes FrameSource output: applies adaptive sampling, runs OCR on a serial queue,
/// scores best frames, and reports results. Never blocks the capture callback.
final class FramePipeline: @unchecked Sendable {
    weak var delegate: FramePipelineDelegate?

    /// Downsample width used for change detection & sharpness.
    private let analysisWidth = 96
    private var analysisHeight = 170

    private let ocr: OCRService
    private let ocrQueue = DispatchQueue(label: "com.livebook.ocr-pipeline", qos: .userInitiated)
    private let stateLock = NSLock()

    private var sampler = AdaptiveFrameSampler()
    private var selector = BestFrameSelector()
    private var previousGray: [UInt8]?
    private var lastOCRResult: OCRResult?

    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var fpsFrames = 0
    private var fpsStartLock = NSLock()
    private var fpsLock = NSLock()

    private(set) var captureFPS: Double = 0
    private(set) var ocrFPS: Double = 0

    init(ocr: OCRService) {
        self.ocr = ocr
    }

    /// Feed a captured frame (called from capture callback — must not block).
    func ingest(_ output: FrameSourceOutput) {
        updateCaptureFPS()
        guard let cgImage = pixelBufferToCGImage(output.pixelBuffer) else { return }
        let gray = ChangeDetector.grayscaleBytes(from: cgImage,
                                                 width: analysisWidth,
                                                 height: analysisHeight)
        let change: Double
        if let gray, let prev = previousGray {
            change = ChangeDetector.difference(prev, gray)
        } else {
            change = 1.0
        }
        if let gray {
            previousGray = gray
        }

        let shouldOCR: Bool
        stateLock.lock()
        shouldOCR = sampler.considerFrame(at: output.timestamp, change: change)
        stateLock.unlock()

        guard shouldOCR, ocr.tryAcquire() else { return }

        let timestamp = output.timestamp
        let sharpness = gray.map { SharpnessCalculator.sharpness($0) } ?? 0
        let size = CGSize(width: cgImage.width, height: cgImage.height)

        ocrQueue.async { [weak self] in
            guard let self else { return }
            let result = self.ocr.recognize(cgImage: cgImage, timestamp: timestamp)
            self.ocr.release()
            self.handleOCRResult(result, cgImage: cgImage, sharpness: sharpness, size: size)
        }
    }

    private func handleOCRResult(_ result: OCRResult, cgImage: CGImage, sharpness: Double, size: CGSize) {
        updateOCRFPS()
        lastOCRResult = result

        // Build scored frame.
        let textArea = result.observations.reduce(0.0) {
            $0 + Double($1.boundingBox.width * $1.boundingBox.height)
        }
        var frame = ScoredFrame(id: result.id,
                                timestamp: result.timestamp,
                                pixelSize: size,
                                sharpness: sharpness,
                                ocrConfidence: result.confidence,
                                hasISBN: result.isbn != nil,
                                textArea: textArea,
                                score: 0,
                                isValid: size.width > 0)

        stateLock.lock()
        let kind = MediaAssetKind(rawValue: frame.hasISBN ? MediaAssetKind.isbnBest.rawValue : MediaAssetKind.coverBest.rawValue) ?? .coverBest
        let improved = selector.register(frame, kind: kind, image: cgImage)
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if improved {
                frame.score = BestFrameSelector.computeScore(frame)
                self.delegate?.pipeline(self, didSelectBest: frame, kind: kind, image: cgImage)
            }
            self.delegate?.pipeline(self, didProduce: result)
        }
    }

    func reset(seekTime: Double? = nil) {
        stateLock.lock()
        sampler.reset()
        previousGray = nil
        stateLock.unlock()
    }

    func finish(error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.pipelineDidEnd(self, error: error)
        }
    }

    // MARK: - FPS tracking

    private func updateCaptureFPS() {
        fpsLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        fpsFrames += 1
        if now - fpsWindowStart >= 1.0 {
            captureFPS = Double(fpsFrames) / (now - fpsWindowStart)
            fpsFrames = 0
            fpsWindowStart = now
        }
        fpsLock.unlock()
    }

    private func updateOCRFPS() {
        ocrFPSLock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        ocrFrames += 1
        if now - ocrFPSStart >= 1.0 {
            ocrFPS = Double(ocrFrames) / (now - ocrFPSStart)
            ocrFrames = 0
            ocrFPSStart = now
        }
        ocrFPSLock.unlock()
    }

    private let ocrFPSLock = NSLock()
    private var ocrFPSStart = CFAbsoluteTimeGetCurrent()
    private var ocrFrames = 0

    // MARK: - Conversion

    private func pixelBufferToCGImage(_ buffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: base,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        return ctx.makeImage()
    }
}
