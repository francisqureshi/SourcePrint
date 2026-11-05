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

    func testRenderInspectionReportsFramesWithoutChangingSavedMetadata() async throws {
        let url = try movie("Camera_grade.mov", seconds: 1)
        let saved = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .gradedSegment)
        _ = try movie("Camera_grade.mov", seconds: 3, timecode: "01:00:02:00")
        let changes = try await SourceMediaRefresh.changes(in: [saved, saved])
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(saved.durationInFrames, 24)
        XCTAssertEqual(saved.sourceTimecode, "01:00:00:00")
        XCTAssertTrue(changes[0].details.contains("Duration: 24 → 72 frames"))
        XCTAssertTrue(changes[0].details.contains("Start TC: 01:00:00:00 → 01:00:02:00"))
        XCTAssertFalse(changes[0].details.joined().contains("seconds"))
        let repeated = try await SourceMediaRefresh.changes(in: [saved])
        XCTAssertEqual(repeated.count, 1, "Cancelling inspection must leave the change pending")
        XCTAssertEqual(repeated[0].refreshed.analyzedFingerprint, changes[0].refreshed.analyzedFingerprint)
        _ = try movie("Camera_grade.mov", seconds: 2)
        let changedAgain = try await SourceMediaRefresh.changes(in: [saved])
        XCTAssertNotEqual(changedAgain[0].refreshed.analyzedFingerprint, changes[0].refreshed.analyzedFingerprint)
        let refreshed = try await SourceMediaRefresh.refresh(saved)
        let unchanged = try await SourceMediaRefresh.changes(in: [refreshed])
        XCTAssertTrue(unchanged.isEmpty)
    }

    func testInspectionCollectsMissingUnreadableAndChangedClipsTogether() async throws {
        let names = ["MissingA.mov", "MissingB.mov", "Unreadable.mov", "Changed.mov"]
        var saved: [MediaFileInfo] = []
        for name in names {
            let url = try movie(name, seconds: 1)
            saved.append(try await MediaAnalyzer().analyzeMediaFile(at: url, type: .gradedSegment))
        }
        try FileManager.default.removeItem(at: saved[0].url)
        try FileManager.default.removeItem(at: saved[1].url)
        try Data("not a video".utf8).write(to: saved[2].url)
        _ = try movie("Changed.mov", seconds: 3)
        let result = try await SourceMediaRefresh.inspect(saved)
        XCTAssertFalse(result.canRender)
        XCTAssertEqual(result.unavailable.count, 3)
        XCTAssertEqual(result.unavailable.filter { $0.status == "Missing / offline" }.count, 2)
        XCTAssertEqual(result.unavailable.filter { $0.status == "Unreadable" }.count, 1)
        XCTAssertEqual(result.changes.count, 1)
        XCTAssertEqual(result.changes[0].refreshed.durationInFrames, 72)
        XCTAssertEqual(saved[3].durationInFrames, 24)
        for name in names.prefix(3) { _ = try movie(name, seconds: 1) }
        let recovered = try await SourceMediaRefresh.inspect(saved)
        XCTAssertTrue(recovered.canRender)
        XCTAssertTrue(recovered.unavailable.isEmpty)
    }

    func testPathOverridesDistinguishSameNamedGradesAndSources() async throws {
        let analyzer = MediaAnalyzer()
        var grades: [MediaFileInfo] = []
        var sources: [MediaFileInfo] = []
        for folder in ["A", "B"] {
            let grade = try movie("Grades/\(folder)/Camera_grade.mov", seconds: 1)
            let source = try movie("Sources/\(folder)/Camera.mov")
            grades.append(try await analyzer.analyzeMediaFile(at: grade, type: .gradedSegment))
            sources.append(try await analyzer.analyzeMediaFile(at: source, type: .originalCameraFile))
        }
        let paths = [SegmentOCFLinker.fileKey(grades[0].url): SegmentOCFLinker.fileKey(sources[1].url),
                     SegmentOCFLinker.fileKey(grades[1].url): SegmentOCFLinker.fileKey(sources[0].url)]
        let result = SegmentOCFLinker().linkSegments(grades, withOCFParents: sources, manualPathOverrides: paths)
        XCTAssertEqual(result.ocfParents[0].children.first?.segment.url, grades[1].url)
        XCTAssertEqual(result.ocfParents[1].children.first?.segment.url, grades[0].url)
        XCTAssertTrue(result.ocfParents.flatMap(\.children).allSatisfy { $0.linkMethod == "manual" })
        let ambiguousLegacy = SegmentOCFLinker().linkSegments(grades, withOCFParents: sources,
            manualOverrides: ["Camera_grade.mov": "Camera.mov"])
        XCTAssertTrue(ambiguousLegacy.ocfParents.flatMap(\.children).allSatisfy { $0.linkConfidence == .low })
    }

    func testDefaultCandidateIsStableAndFavorsPreferredFolder() async throws {
        let analyzer = MediaAnalyzer()
        let gradeURL = try movie("Grades/Camera_grade.mov", seconds: 1)
        let grade = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        var sources: [MediaFileInfo] = []
        for folder in ["Preferred", "Preferred-other", "Backup"] {
            let url = try movie("Sources/\(folder)/Camera.mov")
            sources.append(try await analyzer.analyzeMediaFile(at: url, type: .originalCameraFile))
        }
        let wrongURL = try movie("Sources/Preferred/WrongTC/Camera.mov", timecode: "02:00:00:00")
        sources.append(try await analyzer.analyzeMediaFile(at: wrongURL, type: .originalCameraFile))
        let linker = SegmentOCFLinker()
        let folder = directory.appendingPathComponent("Sources/Preferred")
        XCTAssertEqual(linker.validCandidates(for: grade, in: sources).count, 3)
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources, folder: folder)?.url, sources[0].url)
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources.reversed(), folder: nil)?.url, sources[2].url)
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources, folder: directory)?.url, sources[2].url)
        let alias = directory.appendingPathComponent("PreferredAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources, folder: alias)?.url, sources[0].url)
        let duplicateURL = try movie("Sources/Preferred/Nested/Camera.mov")
        sources.append(try await analyzer.analyzeMediaFile(at: duplicateURL, type: .originalCameraFile))
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources.reversed(), folder: folder)?.url, sources[0].url)
        XCTAssertEqual(linker.preferredCandidate(for: grade, in: sources, folder: directory.appendingPathComponent("Absent"))?.url, sources[2].url)
        XCTAssertNil(linker.preferredCandidate(for: grade, in: [sources[3]], folder: folder))
        let invalidOverride = linker.linkSegments([grade], withOCFParents: sources,
            manualPathOverrides: [SegmentOCFLinker.fileKey(grade.url): SegmentOCFLinker.fileKey(wrongURL)])
        XCTAssertFalse(invalidOverride.ocfParents.flatMap(\.children).contains { $0.linkMethod == "manual" })
    }

    func testPathConfirmationPersistenceAndSafeLegacyMigration() async throws {
        let analyzer = MediaAnalyzer()
        let gradeURL = try movie("Camera_grade.mov", seconds: 1)
        let sourceURL = try movie("Originals/Camera.mov")
        let grade = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let source = try await analyzer.analyzeMediaFile(at: sourceURL, type: .originalCameraFile)
        var model = ProjectModel(name: "Paths", ocfFiles: [source], segments: [grade],
            manualLinkOverrides: [grade.fileName: source.fileName], outputDirectory: directory, blankRushDirectory: directory)
        let decode = { (model: ProjectModel) throws -> ProjectModel in
            try JSONDecoder().decode(ProjectModel.self, from: JSONEncoder().encode(model))
        }
        let migrated = try decode(model)
        XCTAssertEqual(migrated.manualLinkPaths[SegmentOCFLinker.fileKey(grade.url)], SegmentOCFLinker.fileKey(sourceURL))
        let secondURL = try movie("Backup/Camera.mov")
        let second = try await analyzer.analyzeMediaFile(at: secondURL, type: .originalCameraFile)
        model.ocfFiles.append(second)
        XCTAssertTrue(try decode(model).manualLinkPaths.isEmpty)
        model.manualLinkPaths = [SegmentOCFLinker.fileKey(grade.url): SegmentOCFLinker.fileKey(secondURL)]
        model.preferredOCFFolder = secondURL.deletingLastPathComponent()
        let restored = try decode(model)
        XCTAssertEqual(restored.manualLinkPaths, model.manualLinkPaths)
        XCTAssertEqual(restored.preferredOCFFolder, model.preferredOCFFolder)
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
