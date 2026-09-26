import Foundation
import SwiftData

@Model
final class CaptureSession {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var sourceKind: String   // "replay" | "screen"
    var sourceName: String
    var itemCount: Int
    @Relationship(deleteRule: .cascade, inverse: \MediaAsset.session)
    var mediaAssets: [MediaAsset] = []
    @Relationship(deleteRule: .cascade, inverse: \PersistedBookCandidate.session)
    var books: [PersistedBookCandidate] = []

    init(id: UUID = UUID(), startedAt: Date = .now, sourceKind: String, sourceName: String) {
        self.id = id
        self.startedAt = startedAt
        self.sourceKind = sourceKind
        self.sourceName = sourceName
        self.itemCount = 0
    }
}

@Model
final class MediaAsset {
    var id: UUID
    var createdAt: Date
    var kind: String          // MediaAssetKind.rawValue
    var filePath: String
    var width: Int
    var height: Int
    var sharpness: Double
    var ocrConfidence: Float
    var ocrText: String
    var timestamp: Double
    var session: CaptureSession?

    init(id: UUID = UUID(),
         createdAt: Date = .now,
         kind: String,
         filePath: String,
         width: Int,
         height: Int,
         sharpness: Double,
         ocrConfidence: Float,
         ocrText: String,
         timestamp: Double,
         session: CaptureSession? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.filePath = filePath
        self.width = width
        self.height = height
        self.sharpness = sharpness
        self.ocrConfidence = ocrConfidence
        self.ocrText = ocrText
        self.timestamp = timestamp
        self.session = session
    }
}

@Model
final class PersistedBookCandidate {
    var id: UUID
    var timestamp: Double
    var title: String?
    var isbn: String?
    var isbnType: String?
    var confidence: Float
    var ocrText: String
    var session: CaptureSession?

    init(id: UUID = UUID(),
         timestamp: Double,
         title: String?,
         isbn: String?,
         isbnType: String?,
         confidence: Float,
         ocrText: String,
         session: CaptureSession? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.title = title
        self.isbn = isbn
        self.isbnType = isbnType
        self.confidence = confidence
        self.ocrText = ocrText
        self.session = session
    }
}
