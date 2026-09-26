import SwiftUI

/// Overlays Vision bounding boxes on the preview.
/// Vision coordinates are normalized with origin at bottom-left; SwiftUI is top-left,
/// so we mirror Y.
struct BoundingBoxOverlay: View {
    let result: OCRResult?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let result {
                    ForEach(result.observations) { obs in
                        let box = obs.boundingBox
                        let rect = CGRect(
                            x: box.minX * geo.size.width,
                            y: (1 - box.maxY) * geo.size.height,
                            width: box.width * geo.size.width,
                            height: box.height * geo.size.height
                        )
                        Rectangle()
                            .stroke(obs.isISBN ? Color.yellow : Color.green,
                                    lineWidth: 1.5)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
