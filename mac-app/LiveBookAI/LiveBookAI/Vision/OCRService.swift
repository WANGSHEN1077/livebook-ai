import Foundation
import Vision
import CoreGraphics

/// Runs Vision text recognition on a frame. Pure worker: called from a serial queue.
final class OCRService: @unchecked Sendable {
    /// Supported recognition languages (zh-Hans, zh-Hant, ja-JP, en-US).
    var recognitionLanguages: [String] = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
    /// Default to .accurate: .fast cannot read Chinese text on compressed
    /// screen-recording replays (verified on 0813 frames — .fast returns
    /// garbage like "L llJJiH ll,tii"). The adaptive sampler (2/5/0.5 FPS) and
    /// busy-frame dropping keep .accurate affordable.
    var recognitionLevel: VNRequestTextRecognitionLevel = .accurate

    private let queue = DispatchQueue(label: "com.livebook.ocr", qos: .userInitiated)
    /// Set true while a request is in flight; the pipeline drops frames when busy.
    private let busyLock = NSLock()
    private var _isBusy = false

    var isBusy: Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        return _isBusy
    }

    /// Synchronously recognize text in a frame. Must be called from the OCR queue.
    func recognize(cgImage: CGImage, timestamp: TimeInterval) -> OCRResult {
        let start = CFAbsoluteTimeGetCurrent()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])

        let latency = CFAbsoluteTimeGetCurrent() - start

        let observations = (request.results ?? [])
            .map { observation -> OCRObservation in
                let text = observation.topCandidates(1).first?.string ?? ""
                let conf = observation.topCandidates(1).first?.confidence ?? 0
                return OCRObservation(id: UUID(),
                                     text: text,
                                     confidence: conf,
                                     boundingBox: observation.boundingBox,
                                     isISBN: ISBNParser.parse(from: text) != nil)
            }
            .filter { !$0.text.isEmpty }
            .sorted { $0.confidence > $1.confidence }

        let avgConf = observations.isEmpty ? 0 : observations.reduce(0.0) { $0 + Float($1.confidence) } / Float(observations.count)
        let fullText = observations.map(\.text).joined(separator: " ")
        let isbn = observations.compactMap { ISBNParser.parse(from: $0.text) }.first

        return OCRResult(id: UUID(),
                         timestamp: timestamp,
                         text: fullText,
                         confidence: avgConf,
                         observations: observations,
                         isbn: isbn,
                         latency: latency)
    }

    /// Mark busy state. Returns false if already busy (caller should drop the frame).
    func tryAcquire() -> Bool {
        busyLock.lock()
        defer { busyLock.unlock() }
        guard !_isBusy else { return false }
        _isBusy = true
        return true
    }

    func release() {
        busyLock.lock()
        _isBusy = false
        busyLock.unlock()
    }
}
