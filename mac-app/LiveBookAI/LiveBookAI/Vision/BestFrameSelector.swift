import Foundation
import CoreGraphics

/// Selects the best frame for each asset kind based on sharpness, OCR confidence,
/// ISBN presence, and text coverage.
struct BestFrameSelector: Sendable {
    struct Selection: Sendable {
        var scoredFrame: ScoredFrame
        /// CGImage captured alongside the score (kept for persistence).
        var image: CGImage?
    }

    private(set) var best: [MediaAssetKind: Selection] = [:]

    /// Weights for scoring.
    var sharpnessWeight = 0.45
    var confidenceWeight = 0.35
    var isbnWeight = 0.15
    var areaWeight = 0.05

    /// Register a frame; returns true when it became a new best for its kind.
    mutating func register(_ frame: ScoredFrame, kind: MediaAssetKind, image: CGImage?) -> Bool {
        let score = Self.computeScore(frame, weights: (sharpnessWeight, confidenceWeight, isbnWeight, areaWeight))
        var updated = frame
        updated.score = score

        if let current = best[kind] {
            guard score > current.scoredFrame.score else { return false }
        }
        best[kind] = Selection(scoredFrame: updated, image: image)
        return true
    }

    /// Pure scoring used by tests.
    static func computeScore(_ frame: ScoredFrame,
                             weights: (Double, Double, Double, Double) = (0.45, 0.35, 0.15, 0.05)) -> Double {
        let sharp = frame.sharpness * weights.0
        let conf = Double(frame.ocrConfidence) * weights.1
        let isbn = (frame.hasISBN ? 1.0 : 0.0) * weights.2
        let area = min(1.0, frame.textArea) * weights.3
        return sharp + conf + isbn + area
    }

    /// Select best image for a kind.
    func best(for kind: MediaAssetKind) -> Selection? {
        best[kind]
    }

    /// All current best selections.
    var all: [(MediaAssetKind, Selection)] {
        best.sorted { $0.key.rawValue < $1.key.rawValue }.map { ($0.key, $0.value) }
    }
}
