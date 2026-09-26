import Foundation
import CoreGraphics

/// Detects scene change between consecutive downsampled grayscale frames.
enum ChangeDetector {
    /// Mean absolute difference between two 8-bit grayscale buffers, normalized to 0...1.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var sum: Int64 = 0
        for i in 0..<a.count {
            sum += Int64(abs(Int(a[i]) - Int(b[i])))
        }
        return Double(sum) / Double(a.count * 255)
    }

    /// Downsample a CGImage to grayscale bytes of the given size (CG coordinate: top-left origin).
    static func grayscaleBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let w = max(1, width)
        let h = max(1, height)
        var bytes = [UInt8](repeating: 0, count: w * h)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: &bytes,
                            width: w,
                            height: h,
                            bitsPerComponent: 8,
                            bytesPerRow: w,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let ctx = ctx else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return bytes
    }
}
