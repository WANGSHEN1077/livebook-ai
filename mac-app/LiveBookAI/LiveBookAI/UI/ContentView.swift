import SwiftUI

struct ContentView: View {
    @StateObject private var model = LiveBookViewModel()

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
        } detail: {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    PreviewView(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    OCRInspectorView(model: model)
                        .frame(width: 320)
                }
                StatusBarView(model: model)
            }
            .padding()
            .onAppear {
                if model.replayURL == nil {
                    model.loadDefaultReplay()
                }
            }
        }
        .navigationTitle("LiveBook AI — Phase 1")
    }
}
