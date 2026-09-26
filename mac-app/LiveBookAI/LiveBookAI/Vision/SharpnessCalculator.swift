import Foundation

/// Image sharpness via variance of Laplacian over a grayscale buffer.
enum SharpnessCalculator {
    /// Returns a normalized (0...1) sharpness score.
    static func sharpness(_ grayscale: [UInt8]) -> Double {
        let w = laplacianVariance(grayscale)
        // Heuristic normalization: variance around 3000 is "sharp" for downscaled frames.
        return min(1.0, w / 3000.0)
    }

    /// Variance of the 3x3 Laplacian over a grayscale buffer.
    /// Higher = sharper. Assumes row-major layout.
    static func laplacianVariance(_ bytes: [UInt8], width: Int? = nil) -> Double {
        guard !bytes.isEmpty else { return 0 }
        let w = width ?? Int(Double(bytes.count).squareRoot())
        let h = w == 0 ? 0 : bytes.count / w
        guard w > 2, h > 2 else { return 0 }

        var values: [Double] = []
        values.reserveCapacity(bytes.count)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let center = Double(bytes[i]) * 4.0
                let neighbors = Double(bytes[i - w]) + Double(bytes[i + w])
                    + Double(bytes[i - 1]) + Double(bytes[i + 1])
                let lap = center - neighbors
                values.append(lap)
            }
        }
        guard !values.isEmpty else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance
    }
}
