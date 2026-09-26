import Foundation
import CoreGraphics

/// A single text observation produced by Vision.
struct OCRObservation: Identifiable, Codable, Sendable {
    let id: UUID
    /// Recognized text.
    let text: String
    /// 0.0 ... 1.0
    let confidence: Float
    /// Normalized bounding box in Vision coordinates (origin = bottom-left, unit square).
    let boundingBox: CGRect
    /// True when the observation was parsed as an ISBN.
    let isISBN: Bool
}

/// Result of a single OCR pass over one frame.
struct OCRResult: Identifiable, Codable, Sendable {
    let id: UUID
    /// Media timestamp of the source frame (seconds).
    let timestamp: TimeInterval
    /// Concatenated recognized text (lines joined by space).
    let text: String
    /// Average confidence of all observations (0.0 ... 1.0).
    let confidence: Float
    /// All observations, sorted by confidence descending.
    let observations: [OCRObservation]
    /// First valid ISBN found in the frame, if any.
    let isbn: ISBN?
    /// Wall-clock time spent in the Vision request (seconds).
    let latency: TimeInterval
}

/// The kind of a captured media asset.
enum MediaAssetKind: String, Codable, Sendable {
    case raw
    case coverBest
    case isbnBest
    case backBest
    case copyrightBest
}

/// A scored image candidate captured from the stream.
struct ScoredFrame: Identifiable, Codable, Sendable {
    let id: UUID
    /// Media timestamp of the frame.
    let timestamp: TimeInterval
    /// Pixel dimensions of the source frame.
    let pixelSize: CGSize
    /// 0.0 ... 1.0 normalized sharpness.
    let sharpness: Double
    /// 0.0 ... 1.0 average OCR confidence.
    let ocrConfidence: Float
    /// Whether a valid ISBN was recognized.
    let hasISBN: Bool
    /// Fraction of frame area covered by text observations (0...1).
    let textArea: Double
    /// Combined score used for selection.
    var score: Double
    /// True when this frame is a valid full image (usable for persistence).
    let isValid: Bool
}

/// A book whose cover has been recognized in the stream (transient model).
struct BookCandidate: Identifiable, Codable, Sendable {
    let id: UUID
    let timestamp: TimeInterval
    var title: String?
    var isbn: String?
    var isbnType: String?
    var author: String?
    var confidence: Float
    var ocrText: String
    var bestAssetKind: MediaAssetKind
    var sessionID: UUID
}

extension OCRResult {
    /// Text of the observations that belong to the book display area
    /// (everything except the right-hand danmaku column), ordered top-to-bottom
    /// and joined with newlines so each recognized line stays on its own row.
    ///
    /// Vision coordinates: normalized, origin at bottom-left, so "top" has the
    /// larger `maxY`. `danmakuMinX` matches the danmaku-column heuristic used
    /// by `LiveAuctionParser.ingestOCR` (maxX > 0.72).
    func bookAreaText(danmakuMinX: Double = 0.72) -> String {
        observations
            .filter { $0.boundingBox.maxX <= danmakuMinX }
            .sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
            .map(\.text)
            .joined(separator: "\n")
    }
}
