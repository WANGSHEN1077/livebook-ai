import XCTest
import AVFoundation
import CoreVideo
import CoreGraphics
@testable import LiveBookAI

/// Regression test for the "当前商品乱码" bug: OCRService must default to
/// `.accurate` so compressed replay covers are readable. `.fast` returns
/// garbage (e.g. "L llJJiH ll,tii") on this replay; `.accurate` reads the
/// Chinese title. Skips when the replay file is absent.
final class OCRServiceAccuracyTests: XCTestCase {
    private var videoURL: URL? {
        ReplayValidationTests.firstExistingReplay()
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard videoURL != nil else {
            throw XCTSkip("回放文件不存在，跳过 OCR 精度回归测试")
        }
    }

    func testOCRServiceDefaultsToAccurate() {
        let ocr = OCRService()
        XCTAssertEqual(ocr.recognitionLevel, .accurate,
                       "OCRService 必须默认 .accurate，否则压缩回放上的中文书名显示为乱码")
    }

    func testAccurateOCRReadsChineseTitleFromReplayFrame() async throws {
        guard let videoURL else { throw XCTSkip("回放文件不存在") }
        let ocr = OCRService()
        guard let cg = try await frameNear(t0: 202.4, videoURL: videoURL) else {
            throw XCTSkip("无法从回放提取帧")
        }
        let cropped = cg.cropping(to: CGRect(x: Double(cg.width) * 0.12,
                                             y: Double(cg.height) * 0.28,
                                             width: Double(cg.width) * 0.76,
                                             height: Double(cg.height) * 0.50)) ?? cg
        let result = ocr.recognize(cgImage: cropped, timestamp: 202.4)
        // Book #1 expected title: 明清时代庶民文化
        XCTAssertTrue(result.text.contains("明清时代"),
                      "OCR 应识别出 '明清时代'，实际文本: \(result.text)")
    }

    // MARK: - Helpers

    private func frameNear(t0: Double, videoURL: URL) async throws -> CGImage? {
        let asset = AVURLAsset(url: videoURL)
        guard let reader = try? AVAssetReader(asset: asset),
              let track = asset.tracks(withMediaType: .video).first else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return nil }
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600),
                                       duration: CMTime(seconds: 3, preferredTimescale: 600))
        guard reader.startReading() else { return nil }

        while let sample = out.copyNextSampleBuffer() {
            guard let buf = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(buf, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buf) else { continue }
            let w = CVPixelBufferGetWidth(buf)
            let h = CVPixelBufferGetHeight(buf)
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
            guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { continue }
            if let image = ctx.makeImage() {
                return image
            }
        }
        return nil
    }
}
