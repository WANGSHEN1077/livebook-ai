import Foundation
import SwiftData

/// SwiftData persistence layer. Writes happen off the main thread.
final class DataStore {
    let container: ModelContainer
    private let context: ModelContext

    init() throws {
        let schema = Schema([
            CaptureSession.self,
            MediaAsset.self,
            PersistedBookCandidate.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        container = try ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    func createSession(sourceKind: String, sourceName: String) -> CaptureSession {
        let session = CaptureSession(sourceKind: sourceKind, sourceName: sourceName)
        context.insert(session)
        try? context.save()
        return session
    }

    func endSession(_ session: CaptureSession) {
        session.endedAt = .now
        try? context.save()
    }

    func recordMediaAsset(_ asset: MediaAsset, session: CaptureSession?) {
        if let session {
            asset.session = session
            session.itemCount += 1
        }
        context.insert(asset)
        try? context.save()
    }

    func recordBookCandidate(_ candidate: PersistedBookCandidate, session: CaptureSession?) {
        if let session {
            candidate.session = session
            session.itemCount += 1
        }
        context.insert(candidate)
        try? context.save()
    }

    func fetchSessions() -> [CaptureSession] {
        let descriptor = FetchDescriptor<CaptureSession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return (try? context.fetch(descriptor)) ?? []
    }
}
