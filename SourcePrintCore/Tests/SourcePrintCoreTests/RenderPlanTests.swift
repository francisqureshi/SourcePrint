import XCTest
import SwiftFFmpeg
@testable import SourcePrintCore

final class RenderPlanTests: XCTestCase {
    func file(_ name: String, start: Int, frames: Int, fps: AVRational = AVRational(num: 25, den: 1), vfx: Bool = false) -> MediaFileInfo {
        let smpte = SMPTE(fps: Double(fps.num) / Double(fps.den), dropFrame: false)
        return MediaFileInfo(fileName: name, url: URL(fileURLWithPath: "/test/" + name),
            resolution: Resolution(width: 4096, height: 2160), displayResolution: nil, sampleAspectRatio: "1:1",
            frameRate: fps, sourceTimecode: smpte.getTC(frames: start), endTimecode: smpte.getTC(frames: start + frames),
            durationInFrames: Int64(frames), isDropFrame: false, reelName: nil, isInterlaced: false,
            fieldOrder: "progressive", mediaType: .gradedSegment, isVFXShot: vfx,
            startFrameNumber: start, endFrameNumber: start + frames, frameRateFloat: Float(fps.num) / Float(fps.den))
    }
    func parent(_ files: [MediaFileInfo], fps: AVRational = AVRational(num: 25, den: 1)) -> OCFParent {
        OCFParent(ocf: file("OCF.mov", start: 90000, frames: 1000, fps: fps),
            children: files.map { LinkedSegment(segment: $0, linkConfidence: .high, linkMethod: "test") })
    }
    func testExactFullGradeCopiesButMultipleGradesAssemble() throws {
        let full = file("full.mov", start: 90000, frames: 1000)
        XCTAssertEqual(try RenderPlan(parent: parent([full])).copySource, full.url)
        let plan = try RenderPlan(parent: parent([file("a.mov", start: 90000, frames: 400), file("b.mov", start: 90400, frames: 600)]))
        XCTAssertNil(plan.copySource)
        XCTAssertEqual(plan.gaps, [])
        XCTAssertEqual(plan.grades.map(\.frameCount), [400, 600])
    }
    func testGapsAndOverlapsKeepExistingVFXPriority() throws {
        let plan = try RenderPlan(parent: parent([file("grade.mov", start: 90100, frames: 800), file("vfx.mov", start: 90400, frames: 100, vfx: true)]))
        XCTAssertEqual(plan.gaps, [0..<100, 900..<1000])
        XCTAssertEqual(plan.grades.map(\.frameCount), [300, 100, 400])
        XCTAssertEqual(plan.grades.map(\.segmentStartOffset), [0, 0, 400])
    }
    func testOneFrameGapAndFractionalRateStayExact() throws {
        let fps = AVRational(num: 24000, den: 1001)
        let plan = try RenderPlan(parent: parent([file("a.mov", start: 90000, frames: 499, fps: fps), file("b.mov", start: 90500, frames: 500, fps: fps)], fps: fps))
        XCTAssertEqual(plan.gaps, [499..<500])
        XCTAssertEqual(plan.grades.map(\.frameCount), [499, 500])
    }
    func testOutOfRangeOrWrongFPSFailsBeforeProcessing() {
        XCTAssertThrowsError(try RenderPlan(parent: parent([file("bad.mov", start: 89999, frames: 100)])))
        XCTAssertThrowsError(try RenderPlan(parent: parent([file("bad.mov", start: 90999, frames: 2)])))
        XCTAssertThrowsError(try RenderPlan(parent: parent([file("bad.mov", start: 90000, frames: 10, fps: AVRational(num: 24, den: 1))])))
    }
}

final class BlankRangeCacheTests: XCTestCase {
    func testContainedAndAdjacentCacheRangesAreReusedWithExactOffsets() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let plan = try RenderPlan(parent: parent)
        let cache = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        var entries: [BlankRangeCache.Entry] = []
        for interval in [0..<200, 200..<400, 600..<1000] {
            let url = cache.directory.appendingPathComponent("\(interval.lowerBound).mov")
            try Data([1, 2, 3]).write(to: url)
            entries.append(.init(start: interval.lowerBound, end: interval.upperBound,
                file: url.lastPathComponent, fingerprint: RenderOutputFingerprint.capture(at: url)!))
        }
        try JSONEncoder().encode(entries).write(to: cache.directory.appendingPathComponent("ranges.json"))
        let warmed = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        let ranges = try await warmed.ranges(for: 50..<350, progress: nil)
        XCTAssertEqual(ranges.map(\.frameCount), [150, 150])
        XCTAssertEqual(ranges.map(\.segmentStartOffset), [50, 0])
        XCTAssertEqual(warmed.generatedFrames, 0)
        XCTAssertEqual(warmed.reusedFrames, 300)
        // Grade revisions do not change the cache identity.
        let revised = helper.parent([helper.file("revised.mov", start: 90300, frames: 400)])
        let revisionCache = try BlankRangeCache(root: root, ocf: revised.ocf, plan: RenderPlan(parent: revised))
        XCTAssertEqual(revisionCache.directory, cache.directory)
    }

    func testSameNamedOCFsInDifferentLocationsNeverShareCacheIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let plan = try RenderPlan(parent: parent)
        let first = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(parent.ocf)) as! [String: Any]
        object["url"] = "file:///another/OCF.mov"
        let other = try JSONDecoder().decode(MediaFileInfo.self, from: JSONSerialization.data(withJSONObject: object))
        let second = try BlankRangeCache(root: root, ocf: other, plan: plan)
        XCTAssertNotEqual(first.directory, second.directory)
    }
}

final class RenderFingerprintTests: XCTestCase {
    func testSnapshotTracksWritesAndHardLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.mov")
        let alias = root.appendingPathComponent("alias.mov")
        try Data([1, 2, 3]).write(to: source)
        try FileManager.default.linkItem(at: source, to: alias)
        let before = try RenderOutputFingerprint.fileSnapshot(at: source)
        let linked = try RenderOutputFingerprint.fileSnapshot(at: alias)
        XCTAssertEqual(before.fingerprint.size, 3)
        XCTAssertEqual(before.fingerprint, linked.fingerprint)
        XCTAssertEqual(before.device, linked.device)
        XCTAssertEqual(before.fingerprint.modifiedTime, Date().timeIntervalSince1970, accuracy: 5)
        try Data([4, 5, 6, 7]).write(to: source)
        XCTAssertNotEqual(RenderOutputFingerprint.capture(at: source), before.fingerprint)
    }

    func testMissingFilePreservesOfflineError() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertNil(RenderOutputFingerprint.capture(at: missing))
        XCTAssertThrowsError(try RenderOutputFingerprint.fileSnapshot(at: missing)) { error in
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
            XCTAssertEqual((error as NSError).code, NSFileReadNoSuchFileError)
        }
    }
}
