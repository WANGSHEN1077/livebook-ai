import Foundation
import SherpaOnnx

/// sherpa-onnx streaming transcription (C API bridging). Runs fully on-device
/// (no network). Feeds audio in 0.5s chunks to the online recognizer and
/// returns the accumulated text — the same model the manual pipeline uses.
///
/// Model files are loaded from a fixed model directory (kept out of the app
/// bundle to avoid inflating it by ~340 MB).
final class SherpaTranscriptionService: @unchecked Sendable {
    /// sherpa-onnx 模型目录：优先取环境变量 `LIVEBOOK_ASR_MODEL`，否则回落到
    /// 当前用户主目录下的模型缓存目录（避免硬编码个人绝对路径）。
    static var defaultModelDir: String {
        if let override = ProcessInfo.processInfo.environment["LIVEBOOK_ASR_MODEL"], !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/speech2text/models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
    }

    private let modelDir: String

    init(modelDir: String = SherpaTranscriptionService.defaultModelDir) {
        self.modelDir = modelDir
    }

    /// Transcribe a WAV file (16 kHz mono PCM). Returns the raw accumulated text.
    /// Replicates the CLI probe in /tmp/sherpa_swift (validated against 0813).
    func transcribe(wavURL: URL) throws -> String {
        guard let samples = Self.readWAV(path: wavURL.path) else {
            throw TranscriptionError.audioReadFailed
        }
        return transcribe(samples: samples, sampleRate: 16000)
    }

    /// Transcribe raw PCM samples ([-1,1] floats) at 16 kHz, streaming.
    func transcribe(samples: [Float], sampleRate: Int32 = 16000) -> String {
        guard let recognizer = makeRecognizer() else {
            return ""
        }
        guard let stream = SherpaOnnxCreateOnlineStream(recognizer) else {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
            return ""
        }
        var text = ""
        let chunk = 8000 // 0.5s at 16 kHz
        var idx = 0
        while idx < samples.count {
            let end = min(idx + chunk, samples.count)
            Array(samples[idx..<end]).withUnsafeBufferPointer { buf in
                SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, buf.baseAddress, Int32(buf.count))
            }
            idx = end
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            text = Self.accumulate(recognizer: recognizer, stream: stream, previous: text)
        }

        SherpaOnnxOnlineStreamInputFinished(stream)
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        text = Self.accumulate(recognizer: recognizer, stream: stream, previous: text)

        SherpaOnnxDestroyOnlineStream(stream)
        SherpaOnnxDestroyOnlineRecognizer(recognizer)
        return text
    }

    /// A persistent streaming transcriber: created once, fed incrementally with
    /// short PCM chunks (e.g. from live screen capture), and reset on demand.
    /// Keeps the recognizer + stream alive so decoding context spans chunk
    /// boundaries. Not thread-safe; call from a single serial queue.
    final class LiveTranscriber {
        private let recognizer: OpaquePointer
        private var stream: OpaquePointer
        private var text = ""

        init?(service: SherpaTranscriptionService) {
            guard let recognizer = service.makeRecognizer(),
                  let stream = SherpaOnnxCreateOnlineStream(recognizer) else { return nil }
            self.recognizer = recognizer
            self.stream = stream
        }

        /// Feed one chunk (16 kHz mono float PCM). Returns the current accumulated text.
        @discardableResult
        func feed(samples: [Float], sampleRate: Int32 = 16000) -> String {
            Array(samples).withUnsafeBufferPointer { buf in
                SherpaOnnxOnlineStreamAcceptWaveform(stream, sampleRate, buf.baseAddress, Int32(buf.count))
            }
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            text = SherpaTranscriptionService.accumulate(recognizer: recognizer, stream: stream, previous: text)
            return text
        }

        /// Finalize the current utterance and return the last accumulated text.
        func flush() -> String {
            SherpaOnnxOnlineStreamInputFinished(stream)
            while SherpaOnnxIsOnlineStreamReady(recognizer, stream) == 1 {
                SherpaOnnxDecodeOnlineStream(recognizer, stream)
            }
            text = SherpaTranscriptionService.accumulate(recognizer: recognizer, stream: stream, previous: text)
            return text
        }

        /// Start a fresh utterance (drops current context).
        func reset() {
            SherpaOnnxDestroyOnlineStream(stream)
            if let newStream = SherpaOnnxCreateOnlineStream(recognizer) {
                stream = newStream
            }
            text = ""
        }

        func destroy() {
            SherpaOnnxDestroyOnlineStream(stream)
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
        }
    }

    // MARK: - Private

    /// Create a persistent streaming transcriber for live capture.
    func makeLiveTranscriber() -> SherpaTranscriptionService.LiveTranscriber? {
        LiveTranscriber(service: self)
    }

    private func makeRecognizer() -> OpaquePointer? {
        var config = SherpaOnnxOnlineRecognizerConfig()
        config.feat_config = SherpaOnnxFeatureConfig(sample_rate: 16000, feature_dim: 80)
        config.decoding_method = UnsafePointer(strdup("greedy_search"))
        config.max_active_paths = 4
        config.enable_endpoint = 0

        var transducer = SherpaOnnxOnlineTransducerModelConfig()
        transducer.encoder = UnsafePointer(strdup(modelDir + "/encoder-epoch-99-avg-1.onnx"))
        transducer.decoder = UnsafePointer(strdup(modelDir + "/decoder-epoch-99-avg-1.onnx"))
        transducer.joiner = UnsafePointer(strdup(modelDir + "/joiner-epoch-99-avg-1.onnx"))

        var modelConfig = SherpaOnnxOnlineModelConfig()
        modelConfig.transducer = transducer
        modelConfig.tokens = UnsafePointer(strdup(modelDir + "/tokens.txt"))
        modelConfig.num_threads = 4
        modelConfig.provider = UnsafePointer(strdup("cpu"))
        modelConfig.debug = 0
        modelConfig.model_type = UnsafePointer(strdup(""))
        modelConfig.modeling_unit = UnsafePointer(strdup("bpe"))
        modelConfig.bpe_vocab = UnsafePointer(strdup(modelDir + "/bpe.vocab"))

        config.model_config = modelConfig
        return SherpaOnnxCreateOnlineRecognizer(&config)
    }

    /// Fetch the latest streaming result, returning the longest text seen.
    private static func accumulate(recognizer: OpaquePointer?,
                                   stream: OpaquePointer?,
                                   previous: String) -> String {
        guard let result = SherpaOnnxGetOnlineStreamResult(recognizer, stream) else { return previous }
        let text = result.pointee.text.flatMap { String(cString: $0) } ?? previous
        SherpaOnnxDestroyOnlineRecognizerResult(result)
        // sherpa accumulates; keep the longer string.
        return text.count > previous.count ? text : previous
    }

    /// Minimal WAV (PCM 16-bit mono) reader; fails on other formats.
    static func readWAV(path: String) -> [Float]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard data.count > 44 else { return nil }
        let rate = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: Int32.self) }
        let nCh = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 22, as: Int16.self) })
        let bits = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 34, as: Int16.self) })
        guard rate == 16000, nCh == 1, bits == 16 else { return nil }
        let pcm = data[44...]
        let count = pcm.count / 2
        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            for i in 0..<count { samples[i] = Float(ints[i]) / 32768.0 }
        }
        return samples
    }
}

enum TranscriptionError: Error {
    case audioReadFailed
}