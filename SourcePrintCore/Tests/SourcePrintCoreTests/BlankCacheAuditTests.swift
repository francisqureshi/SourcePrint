import XCTest
@testable import SourcePrintCore

final class BlankCacheAuditTests: XCTestCase {
    func testReopenedCacheRejectsChangedDeletedAndInvalidEntries() async throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Opt-in hardware generation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let plan = try RenderPlan(parent: parent)
        let original = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        _ = try await original.ranges(for: [0..<2, 10..<12, 20..<22], progress: nil)
        let manifest = original.directory.appendingPathComponent("ranges.json")
        var entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: manifest))
        let survivor = entries[2]
        try Data([0]).write(to: original.directory.appendingPathComponent(entries[0].file))
        try FileManager.default.removeItem(at: original.directory.appendingPathComponent(entries[1].file))
        // Invalid bounds and path traversal must not be used even with a matching fingerprint.
        entries.append(.init(start: -1, end: 1000, file: survivor.file, fingerprint: survivor.fingerprint))
        entries.append(.init(start: 0, end: 1001, file: survivor.file, fingerprint: survivor.fingerprint))
        entries.append(.init(start: 0, end: 1000, file: "../" + survivor.file, fingerprint: survivor.fingerprint))
        try JSONEncoder().encode(entries).write(to: manifest)
        let reopened = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        let ranges = try await reopened.ranges(for: [0..<2, 10..<12, 20..<22], progress: nil)
        XCTAssertEqual(ranges.map(\.frameCount), [2, 2, 2])
        XCTAssertEqual(reopened.generatedFrames, 4)
        XCTAssertEqual(reopened.reusedFrames, 2)
        XCTAssertEqual(ranges.last?.segment.url.lastPathComponent, survivor.file)
        XCTAssertEqual(RenderOutputFingerprint.capture(at: original.directory.appendingPathComponent(survivor.file)), survivor.fingerprint)
        let saved = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(saved.count, 3)
        for entry in saved { try await reopened.validate(url: reopened.directory.appendingPathComponent(entry.file), frames: entry.frames) }
    }

    func testManifestPublicationFailureRemovesNewFilesAndReleasesPermits() async throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Opt-in hardware generation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let cache = try BlankRangeCache(root: root, ocf: parent.ocf, plan: RenderPlan(parent: parent))
        let manifest = cache.directory.appendingPathComponent("ranges.json")
        // A nonempty directory cannot be atomically replaced by the manifest file.
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: true)
        try Data([1]).write(to: manifest.appendingPathComponent("keep"))
        do { _ = try await cache.ranges(for: 0..<2, progress: nil); XCTFail("Publication should fail") }
        catch { XCTAssertFalse(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path), ["ranges.json"])
        try FileManager.default.removeItem(at: manifest)
        let retry = try await cache.ranges(for: 0..<2, progress: nil)
        XCTAssertEqual(retry.map(\.frameCount), [2])
        XCTAssertEqual(cache.generatedFrames, 2)
    }
}
