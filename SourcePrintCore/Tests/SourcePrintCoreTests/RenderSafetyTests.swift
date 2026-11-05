import XCTest
@testable import SourcePrintCore

final class RenderSafetyTests: XCTestCase {
    func testFullBlankReuseAndCorruptGapRecovery() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Requires explicitly prepared local benchmark copies")
        }
        let root = URL(fileURLWithPath: path)
        let fixtures = try JSONDecoder().decode(RenderBenchmarkTests.Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let scenario = try XCTUnwrap(fixtures.cases.first { $0.name == "coverage-99" })
        let ocf = try await MediaAnalyzer().analyzeMediaFile(at: URL(fileURLWithPath: scenario.ocf), type: .originalCameraFile)
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: URL(fileURLWithPath: scenario.grades[0]), type: .gradedSegment)
        let parent = OCFParent(ocf: ocf, children: [.init(segment: grade, linkConfidence: .high, linkMethod: "test")])
        let temporary = root.appendingPathComponent("CacheSafety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let cacheRoot = temporary.appendingPathComponent("Cache")
        let output = temporary.appendingPathComponent("Output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let service = RenderService(configuration: .init(blankRushDirectory: cacheRoot, outputDirectory: output))
        let legacy = await service.renderLegacyOCF(parent: parent)
        XCTAssertTrue(legacy.success, legacy.error ?? "")
        let full = try XCTUnwrap(legacy.blankRushURL)
        let fingerprint = RenderOutputFingerprint.capture(at: full)
        let reused = await service.renderOCF(parent: parent)
        XCTAssertTrue(reused.success, reused.error ?? "")
        XCTAssertEqual(reused.blankRushURL, full)
        XCTAssertEqual(RenderOutputFingerprint.capture(at: full), fingerprint)
        // An invalid full blank is ignored, without deleting the user's existing file.
        try Data("invalid".utf8).write(to: full)
        let partial = await service.renderOCF(parent: parent)
        XCTAssertTrue(partial.success, partial.error ?? "")
        XCTAssertNil(partial.blankRushURL)
        let cache = try BlankRangeCache(root: cacheRoot, ocf: ocf, plan: RenderPlan(parent: parent))
        let manifest = cache.directory.appendingPathComponent("ranges.json")
        let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(entries.reduce(0) { $0 + $1.frames.count }, 2)
        let invalid = try XCTUnwrap(entries.first)
        try Data("corrupt".utf8).write(to: cache.directory.appendingPathComponent(invalid.file))
        let recovered = await service.renderOCF(parent: parent)
        XCTAssertTrue(recovered.success, recovered.error ?? "")
        let valid = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: manifest))
        XCTAssertEqual(valid.reduce(0) { $0 + $1.frames.count }, 2)
        XCTAssertFalse(valid.contains { $0.file == invalid.file })
    }

    func testDropFrameGapStartsAtItsOCFPosition() async throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Requires opt-in hardware media tests")
        }
        let helper = RenderPlanTests()
        let template = helper.file("DropFrame.mov", start: 0, frames: 30)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(template)) as! [String: Any]
        object["frameRate"] = ["num": 30000, "den": 1001]
        object["frameRateFloat"] = 30000.0 / 1001.0
        object["sourceTimecode"] = "00:00:59;28"
        object["isDropFrame"] = true
        let ocf = try JSONDecoder().decode(MediaFileInfo.self, from: JSONSerialization.data(withJSONObject: object))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("gap.mov")
        try BlankRushIntermediate(projectDirectory: folder.path).generateGap(ocf: ocf, frames: 2..<5,
            outputURL: output, progress: nil)
        let info = try await MediaAnalyzer().analyzeMediaFile(at: output, type: .originalCameraFile)
        XCTAssertEqual(info.durationInFrames, 3)
        XCTAssertEqual(info.sourceTimecode, "00:01:00;02")
        XCTAssertEqual(info.frameRate?.num, 30000)
        XCTAssertEqual(info.frameRate?.den, 1001)
    }

    func testCopyCancellationAndSourceProtection() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Requires explicitly prepared local benchmark copies")
        }
        let root = URL(fileURLWithPath: path)
        let fixtures = try JSONDecoder().decode(RenderBenchmarkTests.Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let scenario = try XCTUnwrap(fixtures.cases.first { $0.name == "coverage-100" })
        let ocf = try await MediaAnalyzer().analyzeMediaFile(at: URL(fileURLWithPath: scenario.ocf), type: .originalCameraFile)
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: URL(fileURLWithPath: scenario.grades[0]), type: .gradedSegment)
        let parent = OCFParent(ocf: ocf, children: [.init(segment: grade, linkConfidence: .high, linkMethod: "test")])
        let temporary = root.appendingPathComponent("Safety-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let service = RenderService(configuration: .init(blankRushDirectory: temporary.appendingPathComponent("Cache"), outputDirectory: temporary.appendingPathComponent("Output")))
        let rendered = await service.renderOCF(parent: parent)
        XCTAssertTrue(rendered.success, rendered.error ?? "")
        XCTAssertNil(rendered.blankRushURL)
        let output = try XCTUnwrap(rendered.outputURL)
        XCTAssertEqual(RenderOutputFingerprint.capture(at: output)?.size, RenderOutputFingerprint.capture(at: grade.url)?.size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Cache").path))
        let fingerprint = RenderOutputFingerprint.capture(at: output)
        let cancelled = Task { () -> RenderResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.renderOCF(parent: parent)
        }
        let result = await cancelled.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(result.success)
        XCTAssertEqual(RenderOutputFingerprint.capture(at: output), fingerprint)
        // A subsequent successful copy atomically replaces an existing output.
        let repeated = await service.renderOCF(parent: parent)
        XCTAssertTrue(repeated.success, repeated.error ?? "")
        // Even a full-coverage copy cannot replace the OCF at the destination.
        let protected = RenderService(configuration: .init(blankRushDirectory: temporary, outputDirectory: ocf.url.deletingLastPathComponent()))
        let original = RenderOutputFingerprint.capture(at: ocf.url)
        let rejected = await protected.renderOCF(parent: parent)
        XCTAssertFalse(rejected.success)
        XCTAssertTrue(rejected.error?.contains("overwrite source") == true)
        XCTAssertEqual(RenderOutputFingerprint.capture(at: ocf.url), original)
    }
}
