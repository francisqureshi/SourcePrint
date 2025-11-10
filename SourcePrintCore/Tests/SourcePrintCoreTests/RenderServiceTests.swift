import XCTest
@testable import SourcePrintCore

@MainActor
final class RenderServiceTests: XCTestCase {

    var service: RenderService!
    var delegate: MockRenderProgressDelegate!
    var configuration: RenderConfiguration!
    var testDirectory: URL!

    override func setUp() async throws {
        // Create temporary test directories
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenderServiceTests_\(UUID().uuidString)")

        let blankRushDir = testDirectory.appendingPathComponent("BlankRushes")
        let outputDir = testDirectory.appendingPathComponent("Output")

        try FileManager.default.createDirectory(at: blankRushDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        configuration = RenderConfiguration(
            blankRushDirectory: blankRushDir,
            outputDirectory: outputDir,
            proResProfile: "4"
        )

        service = RenderService(configuration: configuration)
        delegate = MockRenderProgressDelegate()
        service.delegate = delegate
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: testDirectory)
        service = nil
        delegate = nil
        configuration = nil
    }

    // MARK: - Initialization Tests

    func testServiceInitialization() {
        XCTAssertNotNil(service)
        XCTAssertEqual(configuration.proResProfile, "4")
    }

    func testConfigurationInitialization() {
        XCTAssertEqual(configuration.blankRushDirectory.lastPathComponent, "BlankRushes")
        XCTAssertEqual(configuration.outputDirectory.lastPathComponent, "Output")
        XCTAssertEqual(configuration.proResProfile, "4")
    }

    func testConfigurationDefaultProResProfile() {
        let config = RenderConfiguration(
            blankRushDirectory: testDirectory,
            outputDirectory: testDirectory
        )

        XCTAssertEqual(config.proResProfile, "4")
    }

    // MARK: - Delegate Tests

    func testDelegateAssignment() {
        XCTAssertNotNil(service.delegate)
    }

    // MARK: - OCFParent Helper Tests

    func testCreateMockOCFParent() {
        let parent = createMockOCFParent(fileName: "OCF001.mov", childCount: 3)

        XCTAssertEqual(parent.ocf.fileName, "OCF001.mov")
        XCTAssertEqual(parent.children.count, 3)
        XCTAssertTrue(parent.hasChildren)
    }

    func testCreateMockOCFParent_NoChildren() {
        let parent = createMockOCFParent(fileName: "OCF001.mov", childCount: 0)

        XCTAssertEqual(parent.ocf.fileName, "OCF001.mov")
        XCTAssertEqual(parent.children.count, 0)
        XCTAssertFalse(parent.hasChildren)
    }

    // MARK: - Render Result Tests

    func testRenderResultSuccess() {
        let outputURL = testDirectory.appendingPathComponent("output.mov")

        let result = RenderResult(
            ocfFileName: "OCF001.mov",
            success: true,
            outputURL: outputURL,
            error: nil,
            duration: 45.3,
            segmentCount: 5,
            blankRushURL: testDirectory.appendingPathComponent("blank.mov")
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.ocfFileName, "OCF001.mov")
        XCTAssertNotNil(result.outputURL)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.duration, 45.3)
        XCTAssertEqual(result.segmentCount, 5)
        XCTAssertNotNil(result.blankRushURL)
    }

    func testRenderResultFailure() {
        let result = RenderResult(
            ocfFileName: "OCF001.mov",
            success: false,
            outputURL: nil,
            error: "Blank rush creation failed",
            duration: 5.2,
            segmentCount: 0
        )

        XCTAssertFalse(result.success)
        XCTAssertNil(result.outputURL)
        XCTAssertEqual(result.error, "Blank rush creation failed")
    }

    // MARK: - Configuration Validation Tests

    func testConfigurationDirectoriesExist() {
        let blankRushExists = FileManager.default.fileExists(atPath: configuration.blankRushDirectory.path)
        let outputExists = FileManager.default.fileExists(atPath: configuration.outputDirectory.path)

        XCTAssertTrue(blankRushExists)
        XCTAssertTrue(outputExists)
    }

    // MARK: - Progress Tests

    func testProgressDelegateCallback() async {
        // Create a mock OCF parent
        _ = createMockOCFParent(fileName: "OCF001.mov", childCount: 2)

        // Note: Full render test would require actual video files
        // This test verifies the service structure is correct
        XCTAssertNotNil(service)
        XCTAssertNotNil(delegate)
    }

    // MARK: - Integration Test Structure

    func testRenderServiceWorkflow_Structure() async {
        // This test verifies the service is properly structured for rendering
        let parent = createMockOCFParent(fileName: "OCF001.mov", childCount: 3)

        // Verify parent has required fields
        XCTAssertNotNil(parent.ocf.sourceTimecode)
        XCTAssertNotNil(parent.ocf.frameRate)
        XCTAssertNotNil(parent.ocf.durationInFrames)

        // Verify children have required fields
        for child in parent.children {
            XCTAssertNotNil(child.segment.sourceTimecode)
            XCTAssertNotNil(child.segment.frameRate)
            XCTAssertNotNil(child.segment.durationInFrames)
        }
    }

    // MARK: - Error Handling Tests

    func testRenderResultWithError() {
        let result = RenderResult(
            ocfFileName: "OCF001.mov",
            success: false,
            error: "Test error message",
            duration: 1.5,
            segmentCount: 0
        )

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Test error message")
    }

    // MARK: - Helper Methods

    private func createMockOCFParent(fileName: String, childCount: Int) -> OCFParent {
        let ocf = MediaFileInfo(
            fileName: fileName,
            url: URL(fileURLWithPath: "/tmp/\(fileName)"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24, den: 1),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:00:10:00",
            durationInFrames: 240,
            isDropFrame: false,
            reelName: nil,
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .originalCameraFile,
            isVFXShot: false
        )

        // Create mock children
        var children: [LinkedSegment] = []
        for i in 0..<childCount {
            let segment = MediaFileInfo(
                fileName: "segment_\(i).mov",
                url: URL(fileURLWithPath: "/tmp/segment_\(i).mov"),
                resolution: Resolution(width: 1920, height: 1080),
                displayResolution: Resolution(width: 1920, height: 1080),
                sampleAspectRatio: "1:1",
                frameRate: AVRational(num: 24, den: 1),
                sourceTimecode: "01:00:0\(i):00",
                endTimecode: "01:00:0\(i):24",
                durationInFrames: 24,
                isDropFrame: false,
                reelName: nil,
                isInterlaced: false,
                fieldOrder: nil,
                mediaType: .gradedSegment,
                isVFXShot: false
            )

            let linkedSegment = LinkedSegment(
                segment: segment,
                linkConfidence: .high,
                linkMethod: "timecode_range"
            )

            children.append(linkedSegment)
        }

        return OCFParent(ocf: ocf, children: children)
    }
}

// MARK: - Mock Delegate

@MainActor
class MockRenderProgressDelegate: RenderProgressDelegate {
    var progressUpdates: [RenderProgress] = []
    var didReceiveProgress = false

    func renderService(_ service: RenderService, didUpdateProgress progress: RenderProgress) {
        didReceiveProgress = true
        progressUpdates.append(progress)
    }
}
