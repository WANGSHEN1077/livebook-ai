import Foundation
import CoreGraphics
import CoreVideo

/// Runs ground-truth validation: for each expected book, seek the replay to t0,
/// OCR the display window, and compare against the expected title.
///
/// This class is UI-independent so it can run both from the app and from unit tests.
final class ValidationRunner: @unchecked Sendable {
    /// Build the OCR service used per book.
    private func makeOCR() -> OCRService {
        let ocr = OCRService()
        // .fast fails to read the compressed replay covers; .accurate reliably
        // returns the Chinese titles (verified on 0813 frames).
        ocr.recognitionLevel = .accurate
        return ocr
    }

    /// Whether the transcription channel is enabled. Validation triggers it
    /// only for books OCR failed to match, so enabling it adds bounded work.
    var enableTranscription = true

    /// Run validation over the given ground truth. `progress` is called on a background queue.
    /// Returns the full summary.
    func run(items: [GroundTruthItem],
             videoURL: URL,
             progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> ValidationSummary {
        let started = Date()
        var results: [ValidationResult] = []
        var matched = 0

        for (index, item) in items.enumerated() {
            // Compute display window start: when consecutive books share the same t0
            // anchor (duplicate t0 in books_0813b.json), use the previous book's
            // settlement time as the start; the actual covers are shown sequentially.
            let windowStart: Double?
            if index > 0, abs(items[index - 1].t0 - item.t0) < 1.0 {
                windowStart = items[index - 1].tSec
            } else {
                windowStart = nil
            }
            let result = try await validateOne(item: item, videoURL: videoURL, windowStart: windowStart)
            if result.matched { matched += 1 }
            results.append(result)
            progress?(index + 1, items.count)
        }

        return ValidationSummary(total: items.count,
                                 matched: matched,
                                 failed: items.count - matched,
                                 startedAt: started,
                                 duration: Date().timeIntervalSince(started),
                                 results: results)
    }

    /// Validate a single book: seek to t0, capture frames across [t0, t0+displayWindow],
    /// aggregate OCR text, match against the title.
    func validateOne(item: GroundTruthItem, videoURL: URL, windowStart providedStart: Double? = nil) async throws -> ValidationResult {
        let start = CFAbsoluteTimeGetCurrent()
        let ocr = makeOCR()
        let source = ReplayFileSource(url: videoURL)
        _ = source.loadDuration()
        source.setSpeed(32.0)   // scan the display window fast

        let effectiveStart = providedStart ?? item.t0
        // For shared-t0 books the window is [prev.tSec, this.tSec]; otherwise
        // [t0, t0+60]. Scan length driven by this book's tSec when available.
        let displayWindow = providedStart.map { _ in item.tSec - effectiveStart + 10 } ?? 60.0
        let windowStart = effectiveStart

        let semaphore = DispatchSemaphore(value: 0)
        var sampleCount = 0
        var sampleError: String?
        // Best single-observation overlap with the expected title, plus the OCR text
        // that achieved it; used instead of whole-blob containment to resist danmaku noise.
        var bestOverlap: Double = 0
        var bestMatchText = ""
        var bestConfidence: Float = 0
        var isbnFound: String?

        let lock = NSLock()

        source.onFrame = { output in
            guard output.timestamp >= windowStart else { return }
            let rel = output.timestamp - windowStart
            // Sample OCR roughly every 0.5s during the window.
            let sampleIndex = Int(rel / 0.5)
            guard sampleIndex >= sampleCount else { return }
            lock.lock()
            sampleCount += 1
            lock.unlock()

            guard let cg = self.pixelBufferToCGImage(output.pixelBuffer) else { return }
            // Crop to the cover band and OCR directly. Direct crop (no resampling):
            // CGContext-drawn rescaled images fail Vision OCR on this SDK while
            // direct crops succeed.
            let cropped = Self.coverCrop(cg)
            let result = ocr.recognize(cgImage: cropped ?? cg, timestamp: output.timestamp)

            lock.lock()
            if result.confidence > bestConfidence {
                bestConfidence = result.confidence
            }
            for obs in result.observations {
                let ov = TitleMatcher.overlap(ocr: obs.text, expectedTitle: item.title)
                if ov > bestOverlap {
                    bestOverlap = ov
                    bestMatchText = obs.text
                }
            }
            if let isbn = result.isbn {
                isbnFound = isbn.digits
            }
            lock.unlock()

            // Stop once the display window has been fully scanned.
            if output.timestamp >= windowStart + displayWindow {
                semaphore.signal()
            }
        }

        source.onEnd = { error in
            if let error { sampleError = error.localizedDescription }
            semaphore.signal()
        }

        do {
            try source.start()
            source.seek(to: windowStart)
        } catch {
            return ValidationResult(no: item.no,
                                    expectedTitle: item.title,
                                    matched: false,
                                    bestOCR: "",
                                    bestConfidence: 0,
                                    sampleCount: 0,
                                    isbnFound: nil,
                                    transcriptText: nil,
                                    transcriptMatched: false,
                                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - start,
                                    error: error.localizedDescription)
        }

        // Wait until the window is scanned or timeout (real-time cap at any speed).
        _ = semaphore.wait(timeout: .now() + 50)
        source.stop()

        let ocrMatched = bestOverlap >= 0.7
        var transcriptText: String?
        var transcriptMatched = false
        var transcriptError: String?

        // Transcription channel: the host reads the title aloud near the
        // auction, so spoken text can recover titles OCR cannot read. Runs
        // only when OCR missed, over the window [windowStart-5, tSec+15]
        // (windowStart is providedStart for shared-t0 books, else item.t0).
        if enableTranscription, !ocrMatched {
            let lo = max(0, windowStart - 5)
            let hi = item.tSec + 15
            do {
                let text = try await TranscriptionService().transcribe(videoURL: videoURL, start: lo, end: hi)
                if let text {
                    transcriptText = text
                    transcriptMatched = TitleMatcher.transcriptMatches(spoken: text, expectedTitle: item.title)
                }
            } catch {
                transcriptError = error.localizedDescription
            }
        }

        let isMatch = ocrMatched || transcriptMatched

        return ValidationResult(no: item.no,
                                expectedTitle: item.title,
                                matched: isMatch,
                                bestOCR: bestMatchText,
                                bestConfidence: bestConfidence,
                                sampleCount: sampleCount,
                                isbnFound: isbnFound,
                                transcriptText: transcriptText,
                                transcriptMatched: transcriptMatched,
                                elapsedSeconds: CFAbsoluteTimeGetCurrent() - start,
                                error: sampleError ?? transcriptError)
    }

    private func pixelBufferToCGImage(_ buffer: CVBuffer) -> CGImage? {
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

    /// Crops to the cover band (x 0.12-0.88, y 0.28-0.78 of the portrait frame).
    /// Direct crop, no resampling.
    static func coverCrop(_ image: CGImage) -> CGImage? {
        let w = Double(image.width)
        let h = Double(image.height)
        let rect = CGRect(x: w * 0.12, y: h * 0.28, width: w * 0.76, height: h * 0.50)
        return image.cropping(to: rect)
    }
}
