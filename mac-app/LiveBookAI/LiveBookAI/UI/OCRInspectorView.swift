import SwiftUI
import AppKit

/// Right inspector: current OCR text, ISBN, confidence, best frame, metrics.
struct OCRInspectorView: View {
    @ObservedObject var model: LiveBookViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("当前商品")
                .font(.headline)

            if let result = model.currentOCR {
                ScrollView {
                    Text(model.currentItemText.isEmpty ? "（无识别文本）" : model.currentItemText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 180)

                Divider()

                metricsRow("ISBN", value: result.isbn?.display ?? "—")
                if let isbn = result.isbn {
                    HStack {
                        Text(isbn.isValid ? "有效" : "无效")
                            .foregroundStyle(isbn.isValid ? .green : .red)
                        Text(isbn.kind.rawValue.uppercased())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
                metricsRow("置信度", value: String(format: "%.0f%%", result.confidence * 100))
            } else {
                Text("等待 OCR…")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text("最佳画面")
                .font(.headline)
            if let best = model.bestFrame {
                Image(decorative: best, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("类型: \(model.bestKind.rawValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("暂无")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                metricsRow("采集 FPS", value: String(format: "%.1f", model.captureFPS))
                metricsRow("OCR FPS", value: String(format: "%.1f", model.ocrFPS))
                metricsRow("OCR 延迟", value: String(format: "%.0f ms", model.ocrLatency * 1000))
                metricsRow("播放位置", value: String(format: "%.1fs / %.1fs", model.playhead, model.duration))
            }
            .font(.caption)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func metricsRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.caption, design: .monospaced))
        }
    }
}
