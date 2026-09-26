import XCTest
@testable import LiveBookAI

/// Probe: isolates whether the ReplayValidationTests failure is caused by the
/// test *content* (GroundTruthLoader/ValidationRunner) or by the class itself.
final class ReplayValidationProbeTests: XCTestCase {
    func testGroundTruthLoaderRuns() throws {
        let items = try GroundTruthLoader.load()
        print("PROBE loader ok: \(items.count) items")
        XCTAssertEqual(items.count, 50)
    }

    func testTrivialPasses() {
        XCTAssertTrue(true)
    }
}
