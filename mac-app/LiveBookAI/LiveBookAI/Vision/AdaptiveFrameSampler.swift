import Foundation

/// Adaptive frame sampler: decides when to run OCR based on scene change.
///
/// - Default: ~2 FPS
/// - Change above threshold: up to 5 FPS
/// - Sustained static scene: down to 0.5 FPS
struct AdaptiveFrameSampler: Sendable {
    /// Target intervals (seconds).
    let defaultInterval: Double       // 0.5s → 2 FPS
    let activeInterval: Double        // 0.2s → 5 FPS
    let staticInterval: Double        // 2.0s → 0.5 FPS
    /// Normalized (0...1) change thresholds.
    let changeThreshold: Double
    let staticThreshold: Double
    /// Number of consecutive low-change frames before dropping to static rate.
    let staticFramesNeeded: Int

    private(set) var lastOCRTime: Double = -.infinity
    private(set) var lastChange: Double = 0
    private(set) var staticFrames: Int = 0

    init(defaultInterval: Double = 0.5,
         activeInterval: Double = 0.2,
         staticInterval: Double = 2.0,
         changeThreshold: Double = 0.15,
         staticThreshold: Double = 0.03,
         staticFramesNeeded: Int = 5) {
        self.defaultInterval = defaultInterval
        self.activeInterval = activeInterval
        self.staticInterval = staticInterval
        self.changeThreshold = changeThreshold
        self.staticThreshold = staticThreshold
        self.staticFramesNeeded = staticFramesNeeded
    }

    /// Current effective interval based on recent change.
    var currentInterval: Double {
        if lastChange >= changeThreshold { return activeInterval }
        if staticFrames >= staticFramesNeeded { return staticInterval }
        return defaultInterval
    }

    /// Call for every captured frame with its media time and change score.
    /// Returns true when OCR should run now.
    mutating func considerFrame(at time: Double, change: Double) -> Bool {
        lastChange = change
        if change < staticThreshold {
            staticFrames += 1
        } else {
            staticFrames = 0
        }
        guard time - lastOCRTime + 1e-9 >= currentInterval else { return false }
        lastOCRTime = time
        return true
    }

    /// Reset sampling state (e.g. on seek).
    mutating func reset() {
        lastOCRTime = -.infinity
        lastChange = 0
        staticFrames = 0
    }
}
