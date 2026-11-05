import XCTest
@testable import SourcePrintCore

final class SourceRefreshAndDiscoveryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SourceRefresh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func movie(_ path: String, seconds: Int = 2, timecode: String = "01:00:00:00", size: String = "64x64", fps: Int = 24) throws -> URL {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i",
                             "color=c=blue:s=\(size):r=\(fps)", "-t", "\(seconds)", "-c:v", "mpeg4", "-timecode", timecode, url.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "Fixture creation requires ffmpeg on PATH")
        return url
    }

    func testReplacedGradeRefreshesDurationTimecodeResolutionAndPreservesVFX() async throws {
        let url = try movie("Camera_grade.mov")
        var original = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .gradedSegment)
        original.isVFXShot = true
        _ = try movie("Camera_grade.mov", seconds: 1, timecode: "02:00:00:00", size: "128x64", fps: 25)
        let refreshed = try await SourceMediaRefresh.refresh(original)
        XCTAssertEqual(refreshed.durationInFrames, 25)
        XCTAssertEqual(refreshed.sourceTimecode, "02:00:00:00")
        XCTAssertEqual(refreshed.resolution?.width, 128)
        XCTAssertEqual(refreshed.frameRate?.num, 25)
        XCTAssertEqual(refreshed.isVFXShot, true)
        XCTAssertNotEqual(refreshed.analyzedFingerprint, original.analyzedFingerprint)
        XCTAssertNotEqual(refreshed.endFrameNumber, original.endFrameNumber)
    }

    func testChangedQueuedGradeFailsBeforeWritingOutput() async throws {
        let ocfURL = try movie("Camera.mov", seconds: 4)
        let gradeURL = try movie("Camera_grade.mov")
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: ocfURL, type: .originalCameraFile)
        let grade = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let parent = try XCTUnwrap(SegmentOCFLinker().linkSegments([grade], withOCFParents: [ocf]).ocfParents.first)
        _ = try movie("Camera_grade.mov", seconds: 1)
        let output = directory.appendingPathComponent("Output")
        let service = RenderService(configuration: RenderConfiguration(blankRushDirectory: directory.appendingPathComponent("Blank"), outputDirectory: output))
        let result = await service.renderOCF(parent: parent)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.error?.contains("changed since linking") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        let refreshed = try await SourceMediaRefresh.refresh(grade)
        let relinked = SegmentOCFLinker().linkSegments([refreshed], withOCFParents: [ocf])
        XCTAssertEqual(relinked.ocfParents.first?.children.first?.segment.durationInFrames, 24)
        try await SourceMediaRefresh.validateQueuedParent(relinked.ocfParents[0])
    }

    func testLegacyFingerprintAndMissingSource() async throws {
        let url = try movie("Camera_grade.mov")
        var file = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .gradedSegment)
        file.analyzedFingerprint = nil
        let refreshed = try await SourceMediaRefresh.refresh(file)
        XCTAssertNotNil(refreshed.analyzedFingerprint)
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await SourceMediaRefresh.refresh(refreshed)
            XCTFail("Missing source must not retain trusted cached metadata")
        } catch { }
    }

    func testRecursiveDiscoveryKeepsDistinctPathsAndFlagsAmbiguity() async throws {
        let gradeURL = try movie("Grades/Camera_grade.mov", seconds: 1)
        _ = try movie("Footage/CardA/Camera.mov")
        _ = try movie("Footage/CardB/Camera.mov")
        _ = try movie("Footage/Unrelated.mov")
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let result = try await MatchingOCFDiscovery.search(folder: directory.appendingPathComponent("Footage"), segments: [grade], existingOCFs: [])
        XCTAssertEqual(result.matches.count, 2)
        XCTAssertEqual(Set(result.matches.map(\.url)).count, 2)
        let links = SegmentOCFLinker().linkSegments([grade], withOCFParents: result.matches)
        let child = try XCTUnwrap(links.ocfParents.flatMap(\.children).first)
        XCTAssertEqual(child.linkConfidence, .low)
        XCTAssertTrue(child.linkMethod.contains("ambiguous"))
        XCTAssertEqual(links.totalLinkedSegments, 1)
        let repeated = try await MatchingOCFDiscovery.search(folder: directory.appendingPathComponent("Footage"), segments: [grade], existingOCFs: result.matches)
        XCTAssertTrue(repeated.matches.isEmpty)
    }

    func testDiscoveryRejectsWrongResolutionFPSAndTimecodeIncludingZeroTCFallback() async throws {
        let gradeURL = try movie("Grades/Camera_grade.mov", seconds: 1)
        _ = try movie("Footage/Good/Camera.mov")
        _ = try movie("Footage/WrongResolution/Camera.mov", size: "128x64")
        _ = try movie("Footage/WrongFPS/Camera.mov", fps: 25)
        _ = try movie("Footage/WrongTC/Camera.mov", timecode: "02:00:00:00")
        _ = try movie("Footage/ZeroTC/Camera.mov", timecode: "00:00:00:00")
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let result = try await MatchingOCFDiscovery.search(folder: directory.appendingPathComponent("Footage"), segments: [grade], existingOCFs: [])
        XCTAssertEqual(result.matches.count, 1)
        XCTAssertEqual(result.matches.first?.url.deletingLastPathComponent().lastPathComponent, "Good")
    }

    func testChangedGradeOutsideOCFRangeBecomesUnmatched() async throws {
        let ocfURL = try movie("Camera.mov", seconds: 2)
        let gradeURL = try movie("Camera_grade.mov", seconds: 1)
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: ocfURL, type: .originalCameraFile)
        let grade = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        XCTAssertEqual(SegmentOCFLinker().linkSegments([grade], withOCFParents: [ocf]).totalLinkedSegments, 1)
        _ = try movie("Camera_grade.mov", seconds: 3)
        let refreshed = try await SourceMediaRefresh.refresh(grade)
        let result = SegmentOCFLinker().linkSegments([refreshed], withOCFParents: [ocf])
        XCTAssertEqual(result.totalLinkedSegments, 0)
        XCTAssertEqual(result.unmatchedSegments.count, 1)
    }

    func testDiscoveryDoesNotImportTheGradeItselfThroughDirectoryAlias() async throws {
        let gradeURL = try movie("Grades/Camera_grade.mov")
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let alias = directory.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: gradeURL.deletingLastPathComponent())
        let result = try await MatchingOCFDiscovery.search(folder: alias, segments: [grade], existingOCFs: [])
        XCTAssertTrue(result.matches.isEmpty)
    }

    func testInvalidatedRenderURLsPersistAndOlderProjectsStillDecode() throws {
        var model = ProjectModel(name: "Test", outputDirectory: directory, blankRushDirectory: directory)
        let url = directory.appendingPathComponent("Camera.mov")
        model.invalidatedRenderURLs.insert(url)
        let encoded = try JSONEncoder().encode(model)
        XCTAssertEqual(try JSONDecoder().decode(ProjectModel.self, from: encoded).invalidatedRenderURLs, [url])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "invalidatedRenderURLs")
        let oldData = try JSONSerialization.data(withJSONObject: old)
        XCTAssertTrue(try JSONDecoder().decode(ProjectModel.self, from: oldData).invalidatedRenderURLs.isEmpty)
    }

    func testAutoMatchRejectsOtherGradesOutsideDiscoveredOCFRange() async throws {
        let ocfURL = try movie("Camera.mov", timecode: "00:00:00:00")
        let zeroURL = try movie("Camera_zero.mov", seconds: 1, timecode: "00:00:00:00")
        let laterURL = try movie("Camera_later.mov", seconds: 1, timecode: "01:00:00:00")
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: ocfURL, type: .originalCameraFile)
        let zero = try await analyzer.analyzeMediaFile(at: zeroURL, type: .gradedSegment)
        let later = try await analyzer.analyzeMediaFile(at: laterURL, type: .gradedSegment)
        let result = SegmentOCFLinker().linkSegments([zero, later], withOCFParents: [ocf], requireTimecodeMatch: true)
        XCTAssertEqual(result.totalLinkedSegments, 1)
        XCTAssertEqual(result.unmatchedSegments.first?.url, laterURL)
    }

    func testSameFilenameRefreshDoesNotUseOtherPathsMetadata() async throws {
        let first = try movie("A/Camera_grade.mov", seconds: 1)
        let second = try movie("B/Camera_grade.mov", seconds: 3)
        let analyzer = MediaAnalyzer()
        let a = try await analyzer.analyzeMediaFile(at: first, type: .gradedSegment)
        let b = try await analyzer.analyzeMediaFile(at: second, type: .gradedSegment)
        _ = try movie("A/Camera_grade.mov", seconds: 2)
        let newA = try await SourceMediaRefresh.refresh(a)
        let newB = try await SourceMediaRefresh.refresh(b)
        XCTAssertEqual(newA.durationInFrames, 48)
        XCTAssertEqual(newB.durationInFrames, 72)
        XCTAssertEqual(newB.analyzedFingerprint, b.analyzedFingerprint)
    }
}
