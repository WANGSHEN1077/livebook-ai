// Standalone OCR diagnostic: compares Vision .fast vs .accurate recognition
// on frames extracted from the replay video around a given timestamp.
// Usage: swiftc ocr_diag.swift -o /tmp/ocr_diag && /tmp/ocr_diag [videoPath] [t0]
import Foundation
import AVFoundation
import Vision
import CoreGraphics
import CoreVideo

// 默认视频路径：可用环境变量 LIVEBOOK_REPLAY 覆盖，否则取当前用户主目录下
// 的工程内回放文件（不硬编码个人绝对路径）。
let defaultVideoPath: String = {
    if let override = ProcessInfo.processInfo.environment["LIVEBOOK_REPLAY"], !override.isEmpty {
        return override
    }
    return FileManager.default.homeDirectoryForCurrentUser.path
        + "/Documents/livebook-ai/mac-app/LiveBookAI/media/直播回放-08月13日.mp4"
}()
let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : defaultVideoPath
let t0 = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 202.4) : 202.4

guard FileManager.default.fileExists(atPath: path) else {
    print("video not found: \(path)")
    exit(1)
}

let asset = AVURLAsset(url: URL(fileURLWithPath: path))
guard let reader = try? AVAssetReader(asset: asset),
      let track = asset.tracks(withMediaType: .video).first else {
    print("cannot open video")
    exit(1)
}
let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
])
out.alwaysCopiesSampleData = false
guard reader.canAdd(out) else { print("cannot add output"); exit(1) }
reader.add(out)
reader.timeRange = CMTimeRange(start: CMTime(seconds: t0, preferredTimescale: 600),
                               duration: CMTime(seconds: 12, preferredTimescale: 600))
guard reader.startReading() else { print("startReading failed"); exit(1) }

func recognize(_ cg: CGImage, level: VNRequestTextRecognitionLevel) -> [(String, Float)] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = level
    req.usesLanguageCorrection = true
    req.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "en-US"]
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    try? handler.perform([req])
    return (req.results ?? []).compactMap { obs in
        guard let c = obs.topCandidates(1).first else { return nil }
        return (c.string, c.confidence)
    }.sorted { $0.1 > $1.1 }
}

func pixelBufferToCGImage(_ buf: CVPixelBuffer) -> CGImage? {
    CVPixelBufferLockBaseAddress(buf, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buf, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
    let w = CVPixelBufferGetWidth(buf), h = CVPixelBufferGetHeight(buf)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buf)
    guard let ctx = CGContext(data: base, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
    return ctx.makeImage()
}

var frameCount = 0
while let sample = out.copyNextSampleBuffer(), frameCount < 4 {
    guard let buf = CMSampleBufferGetImageBuffer(sample),
          let cg = pixelBufferToCGImage(buf) else { continue }
    let ts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
    let w = Double(cg.width), h = Double(cg.height)
    let cropRect = CGRect(x: w * 0.12, y: h * 0.28, width: w * 0.76, height: h * 0.50)
    let cropped = cg.cropping(to: cropRect) ?? cg

    let fast = recognize(cropped, level: .fast)
    let accurate = recognize(cropped, level: .accurate)
    print("=== t=\(String(format: "%.1f", ts)) (full \(Int(w))x\(Int(h))) ===")
    print("FAST[\(fast.count)]    : " + fast.prefix(6).map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }.joined(separator: " | "))
    print("ACCURATE[\(accurate.count)]: " + accurate.prefix(6).map { "\($0.0)(\(String(format: "%.2f", $0.1)))" }.joined(separator: " | "))
    frameCount += 1
}
print("done, frames=\(frameCount)")
