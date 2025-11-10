import XCTest
@testable import SourcePrintCore

final class WatchFolderServiceTests: XCTestCase {

    var testDirectory: URL!
    var gradeFolder: URL!
    var vfxFolder: URL!

    override func setUp() async throws {
        // Create temporary test directories
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchFolderTests_\(UUID().uuidString)")
        gradeFolder = testDirectory.appendingPathComponent("Grade")
        vfxFolder = testDirectory.appendingPathComponent("VFX")

        try FileManager.default.createDirectory(at: gradeFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vfxFolder, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        // Clean up test directories
        try? FileManager.default.removeItem(at: testDirectory)
    }

    // MARK: - Helper Methods

    /// Create a test video file with specific size
    private func createTestFile(at url: URL, sizeInBytes: Int = 1024) throws {
        let data = Data(repeating: 0, count: sizeInBytes)
        try data.write(to: url)
    }

    /// Create a mock MediaFileInfo for testing
    private func mockSegment(fileName: String, url: URL) -> MediaFileInfo {
        return MediaFileInfo(
            fileName: fileName,
            url: url,
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24, den: 1),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:00:02:00",
            durationInFrames: 48,
            isDropFrame: false,
            reelName: nil,
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .gradedSegment,
            isVFXShot: false
        )
    }

    // MARK: - detectChangesOnStartup Tests

    func testDetectChangesOnStartup_NoChanges() throws {
        // Setup: Create files and segments
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        let file2 = gradeFolder.appendingPathComponent("clip2.mov")

        try createTestFile(at: file1, sizeInBytes: 1000)
        try createTestFile(at: file2, sizeInBytes: 2000)

        let segments = [
            mockSegment(fileName: "clip1.mov", url: file1),
            mockSegment(fileName: "clip2.mov", url: file2)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000,
            "clip2.mov": 2000
        ]

        // Execute
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)
        let changes = service.detectChangesOnStartup(knownSegments: segments, trackedSizes: trackedSizes)

        // Assert
        XCTAssertFalse(changes.hasChanges, "Should detect no changes")
        XCTAssertEqual(changes.modifiedFiles.count, 0)
        XCTAssertEqual(changes.deletedFiles.count, 0)
    }

    func testDetectChangesOnStartup_FileModified() throws {
        // Setup: Create file and segment
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        try createTestFile(at: file1, sizeInBytes: 2000) // Different size than tracked

        let segments = [
            mockSegment(fileName: "clip1.mov", url: file1)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000 // Old size
        ]

        // Execute
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)
        let changes = service.detectChangesOnStartup(knownSegments: segments, trackedSizes: trackedSizes)

        // Assert
        XCTAssertTrue(changes.hasChanges, "Should detect changes")
        XCTAssertEqual(changes.modifiedFiles.count, 1)
        XCTAssertEqual(changes.modifiedFiles.first, "clip1.mov")
        XCTAssertEqual(changes.sizeChanges["clip1.mov"]?.old, 1000)
        XCTAssertEqual(changes.sizeChanges["clip1.mov"]?.new, 2000)
    }

    func testDetectChangesOnStartup_FileDeleted() throws {
        // Setup: Create segment for file that doesn't exist
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        // Don't create the file - simulate deletion

        let segments = [
            mockSegment(fileName: "clip1.mov", url: file1)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000
        ]

        // Execute
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)
        let changes = service.detectChangesOnStartup(knownSegments: segments, trackedSizes: trackedSizes)

        // Assert
        XCTAssertTrue(changes.hasChanges, "Should detect deletion")
        XCTAssertEqual(changes.deletedFiles.count, 1)
        XCTAssertEqual(changes.deletedFiles.first, "clip1.mov")
    }

    func testDetectChangesOnStartup_MixedChanges() throws {
        // Setup: Create some files, modify one, delete one
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        let file2 = gradeFolder.appendingPathComponent("clip2.mov")
        let file3 = gradeFolder.appendingPathComponent("clip3.mov")

        try createTestFile(at: file1, sizeInBytes: 1000) // Unchanged
        try createTestFile(at: file2, sizeInBytes: 3000) // Modified (was 2000)
        // file3 deleted (not created)

        let segments = [
            mockSegment(fileName: "clip1.mov", url: file1),
            mockSegment(fileName: "clip2.mov", url: file2),
            mockSegment(fileName: "clip3.mov", url: file3)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000,
            "clip2.mov": 2000,
            "clip3.mov": 5000
        ]

        // Execute
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)
        let changes = service.detectChangesOnStartup(knownSegments: segments, trackedSizes: trackedSizes)

        // Assert
        XCTAssertTrue(changes.hasChanges)
        XCTAssertEqual(changes.totalChanges, 2)
        XCTAssertEqual(changes.modifiedFiles.count, 1)
        XCTAssertEqual(changes.modifiedFiles.first, "clip2.mov")
        XCTAssertEqual(changes.deletedFiles.count, 1)
        XCTAssertEqual(changes.deletedFiles.first, "clip3.mov")
    }

    func testDetectChangesOnStartup_IgnoresFilesOutsideWatchFolder() throws {
        // Setup: Create file outside watch folder
        let outsideFolder = testDirectory.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outsideFolder, withIntermediateDirectories: true)

        let outsideFile = outsideFolder.appendingPathComponent("clip1.mov")
        try createTestFile(at: outsideFile, sizeInBytes: 2000)

        let segments = [
            mockSegment(fileName: "clip1.mov", url: outsideFile)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000
        ]

        // Execute
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)
        let changes = service.detectChangesOnStartup(knownSegments: segments, trackedSizes: trackedSizes)

        // Assert: Should ignore file outside watch folder
        XCTAssertFalse(changes.hasChanges, "Should ignore files outside watch folder")
    }

    // MARK: - scanForNewFiles Tests

    func testScanForNewFiles_EmptyFolder() async throws {
        // Setup: Empty folders, no known segments
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Execute
        let newFiles = await service.scanForNewFiles(knownSegments: [])

        // Assert
        XCTAssertEqual(newFiles.gradeFiles.count, 0)
        XCTAssertEqual(newFiles.vfxFiles.count, 0)
    }

    func testScanForNewFiles_AllFilesNew() async throws {
        // Setup: Create files in grade folder
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        let file2 = gradeFolder.appendingPathComponent("clip2.mov")

        try createTestFile(at: file1)
        try createTestFile(at: file2)

        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Execute: No known segments
        let newFiles = await service.scanForNewFiles(knownSegments: [])

        // Assert
        XCTAssertEqual(newFiles.gradeFiles.count, 2)
        XCTAssertTrue(newFiles.gradeFiles.contains(file1))
        XCTAssertTrue(newFiles.gradeFiles.contains(file2))
    }

    func testScanForNewFiles_FilterKnownFiles() async throws {
        // Setup: Create 3 files, 1 already known
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        let file2 = gradeFolder.appendingPathComponent("clip2.mov")
        let file3 = gradeFolder.appendingPathComponent("clip3.mov")

        try createTestFile(at: file1)
        try createTestFile(at: file2)
        try createTestFile(at: file3)

        let knownSegments = [
            mockSegment(fileName: "clip2.mov", url: file2) // Already imported
        ]

        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Execute
        let newFiles = await service.scanForNewFiles(knownSegments: knownSegments)

        // Assert: Should only find clip1 and clip3 (not clip2)
        XCTAssertEqual(newFiles.gradeFiles.count, 2)
        XCTAssertTrue(newFiles.gradeFiles.contains(file1))
        XCTAssertTrue(newFiles.gradeFiles.contains(file3))
        XCTAssertFalse(newFiles.gradeFiles.contains(file2))
    }

    func testScanForNewFiles_BothGradeAndVFX() async throws {
        // Setup: Create files in both folders
        let gradeFile = gradeFolder.appendingPathComponent("grade1.mov")
        let vfxFile = vfxFolder.appendingPathComponent("vfx1.mov")

        try createTestFile(at: gradeFile)
        try createTestFile(at: vfxFile)

        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: vfxFolder.path)

        // Execute
        let newFiles = await service.scanForNewFiles(knownSegments: [])

        // Assert
        XCTAssertEqual(newFiles.gradeFiles.count, 1)
        XCTAssertEqual(newFiles.vfxFiles.count, 1)
        XCTAssertTrue(newFiles.gradeFiles.contains(gradeFile))
        XCTAssertTrue(newFiles.vfxFiles.contains(vfxFile))
    }

    func testScanForNewFiles_IgnoresHiddenFiles() async throws {
        // Setup: Create visible and hidden files
        let visibleFile = gradeFolder.appendingPathComponent("clip1.mov")
        let hiddenFile = gradeFolder.appendingPathComponent(".hidden.mov")

        try createTestFile(at: visibleFile)
        try createTestFile(at: hiddenFile)

        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Execute
        let newFiles = await service.scanForNewFiles(knownSegments: [])

        // Assert: Should only find visible file
        XCTAssertEqual(newFiles.gradeFiles.count, 1)
        XCTAssertTrue(newFiles.gradeFiles.contains(visibleFile))
        XCTAssertFalse(newFiles.gradeFiles.contains(hiddenFile))
    }

    func testScanForNewFiles_IgnoresNonVideoFiles() async throws {
        // Setup: Create video and non-video files
        let videoFile = gradeFolder.appendingPathComponent("clip1.mov")
        let textFile = gradeFolder.appendingPathComponent("notes.txt")
        let imageFile = gradeFolder.appendingPathComponent("poster.jpg")

        try createTestFile(at: videoFile)
        try createTestFile(at: textFile)
        try createTestFile(at: imageFile)

        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Execute
        let newFiles = await service.scanForNewFiles(knownSegments: [])

        // Assert: Should only find video file
        XCTAssertEqual(newFiles.gradeFiles.count, 1)
        XCTAssertTrue(newFiles.gradeFiles.contains(videoFile))
    }

    // MARK: - Integration Tests

    func testCompleteStartupFlow() async throws {
        // Setup: Simulate a complete startup scenario

        // Step 1: Create initial files and "import" them
        let file1 = gradeFolder.appendingPathComponent("clip1.mov")
        let file2 = gradeFolder.appendingPathComponent("clip2.mov")

        try createTestFile(at: file1, sizeInBytes: 1000)
        try createTestFile(at: file2, sizeInBytes: 2000)

        let knownSegments = [
            mockSegment(fileName: "clip1.mov", url: file1),
            mockSegment(fileName: "clip2.mov", url: file2)
        ]

        let trackedSizes: [String: Int64] = [
            "clip1.mov": 1000,
            "clip2.mov": 2000
        ]

        // Step 2: Simulate changes while app was closed
        // - Delete clip2
        try FileManager.default.removeItem(at: file2)

        // - Modify clip1 (change size)
        try createTestFile(at: file1, sizeInBytes: 1500)

        // - Add new clip3
        let file3 = gradeFolder.appendingPathComponent("clip3.mov")
        try createTestFile(at: file3, sizeInBytes: 3000)

        // Step 3: Run startup detection
        let service = WatchFolderService(gradePath: gradeFolder.path, vfxPath: nil)

        // Phase 1: Detect changes to known files
        let changes = service.detectChangesOnStartup(knownSegments: knownSegments, trackedSizes: trackedSizes)

        // Phase 2: Scan for new files
        let newFiles = await service.scanForNewFiles(knownSegments: knownSegments)

        // Step 4: Verify results

        // Should detect clip1 modification
        XCTAssertEqual(changes.modifiedFiles.count, 1)
        XCTAssertEqual(changes.modifiedFiles.first, "clip1.mov")
        XCTAssertEqual(changes.sizeChanges["clip1.mov"]?.old, 1000)
        XCTAssertEqual(changes.sizeChanges["clip1.mov"]?.new, 1500)

        // Should detect clip2 deletion
        XCTAssertEqual(changes.deletedFiles.count, 1)
        XCTAssertEqual(changes.deletedFiles.first, "clip2.mov")

        // Should find clip3 as new
        XCTAssertEqual(newFiles.gradeFiles.count, 1)
        XCTAssertTrue(newFiles.gradeFiles.contains(file3))
    }
}
