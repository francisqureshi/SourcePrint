import XCTest
import AVFoundation
@testable import SourcePrintCore

final class PortraitOrientationTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PortraitOrientation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func ffmpeg(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-v", "error", "-y"] + arguments
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
    private func movie(_ name: String, size: String = "320x180", frames: Int = 4, codec: String = "libx264") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try ffmpeg(["-f", "lavfi", "-i", "color=blue:size=\(size):rate=25", "-frames:v", "\(frames)", "-c:v", codec,
                    "-timecode", "01:00:00:00", url.path])
        return url
    }
    private func rotated(_ source: URL, degrees: Int) throws -> URL {
        let url = directory.appendingPathComponent("Camera_\(degrees).mov")
        try ffmpeg(["-display_rotation", "\(degrees)", "-i", source.path, "-c", "copy", url.path])
        return url
    }
    func testDisplayMatrixKeepsCodedPixelsAndOrientsDisplayDimensions() async throws {
        let source = try movie("landscape.mov")
        for angle in [0, 90, -90, 180] {
            let info = try await MediaAnalyzer().analyzeMediaFile(at: rotated(source, degrees: angle), type: .originalCameraFile)
            XCTAssertEqual(info.resolution, Resolution(width: 320, height: 180))
            XCTAssertEqual(info.effectiveDisplayResolution, abs(angle) == 90 ? Resolution(width: 180, height: 320) : Resolution(width: 320, height: 180), "Rotation: \(angle)")
            XCTAssertEqual(info.durationInFrames, 4)
            XCTAssertEqual(info.sourceTimecode, "01:00:00:00")
        }
    }
    func testTransformAppliesAfterSARAndIgnoresTranslation() {
        let sarCorrected = Resolution(width: 1920, height: 1080)
        let transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        XCTAssertEqual(MediaAnalyzer.orientedResolution(sarCorrected, transform: transform), Resolution(width: 1080, height: 1920))
        XCTAssertEqual(MediaAnalyzer.orientedResolution(sarCorrected, transform: .identity), sarCorrected)
    }
    func testPortraitGradeMatchesAndRenderReplacesLandscapeBlank() async throws {
        let source = try movie("landscape.mov")
        let ocf = try await MediaAnalyzer().analyzeMediaFile(at: rotated(source, degrees: -90), type: .originalCameraFile)
        let gradeURL = try movie("Camera_-90_grade.mov", size: "180x320", frames: 2, codec: "prores_ks")
        let grade = try await MediaAnalyzer().analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        let result = SegmentOCFLinker().linkSegments([grade], withOCFParents: [ocf])
        let parent = try XCTUnwrap(result.ocfParents.first)
        XCTAssertEqual(parent.children.count, 1)
        let blankDirectory = directory.appendingPathComponent("Blanks")
        try FileManager.default.createDirectory(at: blankDirectory, withIntermediateDirectories: true)
        let staleBlank = blankDirectory.appendingPathComponent("Camera_-90_blankRush.mov")
        try FileManager.default.copyItem(at: source, to: staleBlank)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Output"), withIntermediateDirectories: true)
        let service = RenderService(configuration: RenderConfiguration(blankRushDirectory: blankDirectory, outputDirectory: directory.appendingPathComponent("Output")))
        let render = await service.renderOCF(parent: parent)
        XCTAssertTrue(render.success, render.error ?? "")
        let output = try await MediaAnalyzer().analyzeMediaFile(at: XCTUnwrap(render.outputURL), type: .originalCameraFile)
        let blank = try await MediaAnalyzer().analyzeMediaFile(at: staleBlank, type: .originalCameraFile)
        XCTAssertEqual(blank.resolution, Resolution(width: 180, height: 320))
        XCTAssertEqual(output.resolution, Resolution(width: 180, height: 320))
        XCTAssertEqual(output.durationInFrames, ocf.durationInFrames)
        XCTAssertEqual(output.sourceTimecode, ocf.sourceTimecode)
    }
    func testRealIPhoneSampleWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_IPHONE_SAMPLE"] else { throw XCTSkip("Set SOURCEPRINT_IPHONE_SAMPLE for real-media verification") }
        let info = try await MediaAnalyzer().analyzeMediaFile(at: URL(fileURLWithPath: path), type: .originalCameraFile)
        let width = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_IPHONE_WIDTH"] ?? "3840")!
        let height = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_IPHONE_HEIGHT"] ?? "2160")!
        XCTAssertEqual(info.resolution, Resolution(width: width, height: height))
        XCTAssertEqual(info.effectiveDisplayResolution, Resolution(width: height, height: width))
    }
}
