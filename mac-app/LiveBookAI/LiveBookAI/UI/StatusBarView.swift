import SwiftUI

/// Bottom status bar.
struct StatusBarView: View {
    @ObservedObject var model: LiveBookViewModel

    var body: some View {
        HStack {
            Circle()
                .fill(model.isCapturing ? Color.green : Color.gray)
                .frame(width: 8, height: 8)
            Text(model.statusMessage ?? (model.isCapturing ? "捕获中…" : "待机"))
                .font(.caption)
                .foregroundStyle(model.statusIsError ? .red : .secondary)
            Spacer()
            if model.isCapturing {
                Text("回放模式")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }
}
