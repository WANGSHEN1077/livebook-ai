import Foundation
import AVFoundation

/// In-app speech transcription channel backed by sherpa-onnx (fully on-device,
/// the same model the manual pipeline uses). Extracts the audio of a time
/// window from a replay video, transcodes it to 16 kHz mono PCM WAV, and runs
/// sherpa's streaming recognizer to get the spoken text.
///
/// This replaces the previous SFSpeechRecognizer backend whose on-device
/// Chinese accuracy was too low on the compressed replay audio.
final class TranscriptionService: @unchecked Sendable {
    private let sherpa = SherpaTranscriptionService()

    /// Transcribe the audio of `[start, end]` seconds of the video.
    /// Returns the best transcription text, or nil if transcription is unavailable.
    func transcribe(videoURL: URL, start: Double, end: Double) async throws -> String? {
        let asset = AVURLAsset(url: videoURL)
        guard asset.tracks(withMediaType: .audio).first != nil else { return nil }

        // Export the requested window to a temporary 16 kHz mono PCM WAV that
        // sherpa-onnx consumes directly (no transcode step needed afterwards).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("livebook_sherpa_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startTime = CMTime(seconds: max(0, start), preferredTimescale: 600)
        let duration = CMTime(seconds: max(0.1, end - start), preferredTimescale: 600)

        // AVAssetExportSession m4a preset is simple but requires a transcode to
        // wav afterwards; instead read the audio track directly with an
        // AVAssetReader and write a PCM WAV ourselves.
        guard let reader = try? AVAssetReader(asset: asset),
              let track = asset.tracks(withMediaType: .audio).first else { return nil }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = true
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: startTime, duration: duration)

        guard reader.startReading() else { return nil }

        var pcm = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var length = 0
            var dataPtr: UnsafeMutablePointer<CChar>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &dataPtr)
            if let dataPtr, length > 0 {
                pcm.append(contentsOf: UnsafeRawBufferPointer(start: dataPtr, count: length))
            }
        }
        reader.cancelReading()

        guard pcm.count > 44 else { return nil }
        var wav = Self.makeWAVHeader(byteCount: pcm.count)
        wav?.append(pcm)
        guard let wavData = wav else { return nil }
        try? wavData.write(to: tmp)

        return try sherpa.transcribe(wavURL: tmp)
    }

    /// 16-bit mono 16 kHz PCM WAV header (44 bytes).
    static func makeWAVHeader(byteCount: Int) -> Data? {
        var data = Data(capacity: 44)
        func append(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
        func appendUInt32(_ v: UInt32) { append(withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        func appendUInt16(_ v: UInt16) { append(withUnsafeBytes(of: v.littleEndian) { Array($0) }) }
        append(Array("RIFF".utf8)); appendUInt32(UInt32(36 + byteCount)); append(Array("WAVE".utf8))
        append(Array("fmt ".utf8)); appendUInt32(16)
        appendUInt16(1); appendUInt16(1); appendUInt32(16000); appendUInt32(32000)
        appendUInt16(2); appendUInt16(16)
        append(Array("data".utf8)); appendUInt32(UInt32(byteCount))
        return data
    }
}