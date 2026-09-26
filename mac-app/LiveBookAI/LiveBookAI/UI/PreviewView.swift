import SwiftUI

/// Center panel: live preview + OCR bounding boxes + seek bar.
struct PreviewView: View {
    @ObservedObject var model: LiveBookViewModel

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                if let frame = model.latestFrame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .overlay {
                            BoundingBoxOverlay(result: model.currentOCR)
                        }
                } else {
                    Rectangle()
                        .fill(.black.opacity(0.2))
                        .overlay {
                            Text("暂无画面\n请点击「开始捕获」")
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            replayControls
        }
    }

    private var replayControls: some View {
        HStack(spacing: 12) {
            Button {
                model.seek(to: 0)
            } label: {
                Image(systemName: "backward.end")
            }

            Text(timeString(model.playhead))
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 70)

            Slider(value: Binding(
                get: { model.playhead },
                set: { model.seek(to: $0) }
            ), in: 0...max(model.duration, 1))
            .frame(maxWidth: .infinity)

            Text("/ \(timeString(model.duration))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    private func timeString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}
