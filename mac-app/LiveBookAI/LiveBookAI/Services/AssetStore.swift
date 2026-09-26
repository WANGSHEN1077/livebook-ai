import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Persists captured images (raw + processed) to disk under an assets directory.
final class AssetStore {
    enum AssetStoreError: Error, LocalizedError {
        case failedToWrite
        var errorDescription: String? { "图片写入失败" }
    }

    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootURL = base.appendingPathComponent("LiveBookAI/assets", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
    }

    /// Saves a CGImage as JPEG; returns file URL.
    @discardableResult
    func save(image: CGImage, sessionID: UUID, kind: MediaAssetKind, timestamp: Double) -> URL? {
        let dir = rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fileName = String(format: "%@_%08.3f.jpg", kind.rawValue, timestamp)
        let url = dir.appendingPathComponent(fileName)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    /// Path of the session's folder.
    func sessionFolder(for sessionID: UUID) -> URL {
        rootURL.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }
}
