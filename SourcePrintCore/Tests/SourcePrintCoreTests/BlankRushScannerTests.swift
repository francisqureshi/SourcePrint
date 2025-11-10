import XCTest
@testable import SourcePrintCore

final class BlankRushScannerTests: XCTestCase {

    var testDirectory: URL!

    override func setUp() {
        super.setUp()
        // Create temporary test directory
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Clean up test directory
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }

    // MARK: - Helper Methods

    func createTestOCF(fileName: String) -> MediaFileInfo {
        return MediaFileInfo(
            fileName: fileName,
            url: URL(fileURLWithPath: "/test/\(fileName)"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1001),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:00:04:03",
            durationInFrames: 100,
            isDropFrame: false,
            reelName: nil,
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .originalCameraFile,
            isVFXShot: false
        )
    }

    func createTestLinkingResult(ocfNames: [String]) -> LinkingResult {
        let ocfParents = ocfNames.map { fileName -> OCFParent in
            let ocf = createTestOCF(fileName: fileName)
            // Create a dummy segment child so parent.hasChildren == true
            let segment = createTestOCF(fileName: "segment_\(fileName)")
            let linkedSegment = LinkedSegment(segment: segment, linkConfidence: .high, linkMethod: "test")
            return OCFParent(ocf: ocf, children: [linkedSegment])
        }

        return LinkingResult(
            ocfParents: ocfParents,
            unmatchedSegments: [],
            unmatchedOCFs: []
        )
    }

    func createBlankRushFile(ocfFileName: String) {
        let baseName = (ocfFileName as NSString).deletingPathExtension
        let blankRushFileName = "\(baseName)_blankRush.mov"
        let blankRushURL = testDirectory.appendingPathComponent(blankRushFileName)

        // Create empty file
        FileManager.default.createFile(atPath: blankRushURL.path, contents: Data(), attributes: nil)
    }

    // MARK: - Tests

    func testScanForExistingBlankRushes_NoFiles() {
        let linkingResult = createTestLinkingResult(ocfNames: ["OCF001.mov", "OCF002.mov"])

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: testDirectory
        )

        XCTAssertTrue(found.isEmpty, "Should find no blank rushes when none exist")
    }

    func testScanForExistingBlankRushes_SomeFiles() {
        let linkingResult = createTestLinkingResult(ocfNames: ["OCF001.mov", "OCF002.mov", "OCF003.mov"])

        // Create blank rushes for OCF001 and OCF002 only
        createBlankRushFile(ocfFileName: "OCF001.mov")
        createBlankRushFile(ocfFileName: "OCF002.mov")

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: testDirectory
        )

        XCTAssertEqual(found.count, 2, "Should find 2 blank rushes")
        XCTAssertNotNil(found["OCF001.mov"], "Should find OCF001 blank rush")
        XCTAssertNotNil(found["OCF002.mov"], "Should find OCF002 blank rush")
        XCTAssertNil(found["OCF003.mov"], "Should not find OCF003 blank rush")
    }

    func testScanForExistingBlankRushes_AllFiles() {
        let linkingResult = createTestLinkingResult(ocfNames: ["OCF001.mov", "OCF002.mov"])

        // Create all blank rushes
        createBlankRushFile(ocfFileName: "OCF001.mov")
        createBlankRushFile(ocfFileName: "OCF002.mov")

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: testDirectory
        )

        XCTAssertEqual(found.count, 2, "Should find all blank rushes")
        XCTAssertEqual(found["OCF001.mov"]?.lastPathComponent, "OCF001_blankRush.mov")
        XCTAssertEqual(found["OCF002.mov"]?.lastPathComponent, "OCF002_blankRush.mov")
    }

    func testBlankRushExists_FileExists() {
        createBlankRushFile(ocfFileName: "OCF001.mov")

        let exists = BlankRushScanner.blankRushExists(
            for: "OCF001.mov",
            in: testDirectory
        )

        XCTAssertTrue(exists, "Should return true when blank rush exists")
    }

    func testBlankRushExists_FileDoesNotExist() {
        let exists = BlankRushScanner.blankRushExists(
            for: "OCF001.mov",
            in: testDirectory
        )

        XCTAssertFalse(exists, "Should return false when blank rush doesn't exist")
    }

    func testBlankRushURL_ReturnsCorrectPath() {
        let url = BlankRushScanner.blankRushURL(
            for: "OCF001.mov",
            in: testDirectory
        )

        XCTAssertEqual(url.lastPathComponent, "OCF001_blankRush.mov", "Should return correct filename")
        XCTAssertTrue(url.path.hasPrefix(testDirectory.path), "Should be in correct directory")
    }

    func testBlankRushURL_HandlesExtensions() {
        // Test with various extensions
        let url1 = BlankRushScanner.blankRushURL(for: "OCF001.mov", in: testDirectory)
        let url2 = BlankRushScanner.blankRushURL(for: "OCF001.mxf", in: testDirectory)
        let url3 = BlankRushScanner.blankRushURL(for: "OCF001", in: testDirectory)

        XCTAssertEqual(url1.lastPathComponent, "OCF001_blankRush.mov")
        XCTAssertEqual(url2.lastPathComponent, "OCF001_blankRush.mov")
        XCTAssertEqual(url3.lastPathComponent, "OCF001_blankRush.mov")
    }

    func testScanForExistingBlankRushes_EmptyLinkingResult() {
        let linkingResult = createTestLinkingResult(ocfNames: [])

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: testDirectory
        )

        XCTAssertTrue(found.isEmpty, "Should return empty dictionary for empty linking result")
    }

    func testBlankRushExists_NonexistentDirectory() {
        let nonexistentDir = testDirectory.appendingPathComponent("nonexistent")

        let exists = BlankRushScanner.blankRushExists(
            for: "OCF001.mov",
            in: nonexistentDir
        )

        XCTAssertFalse(exists, "Should return false for nonexistent directory")
    }
}
