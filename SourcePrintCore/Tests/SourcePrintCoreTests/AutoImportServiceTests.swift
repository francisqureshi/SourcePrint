import XCTest
@testable import SourcePrintCore

final class AutoImportServiceTests: XCTestCase {

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

    func createTestSegment(fileName: String, fileSize: Int64 = 1000) -> MediaFileInfo {
        let url = testDirectory.appendingPathComponent(fileName)

        // Create actual file for tests that need it
        let data = Data(count: Int(fileSize))
        FileManager.default.createFile(atPath: url.path, contents: data, attributes: nil)

        return MediaFileInfo(
            fileName: fileName,
            url: url,
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
            mediaType: .gradedSegment,
            isVFXShot: false
        )
    }

    func createTestOCF(fileName: String) -> MediaFileInfo {
        let url = testDirectory.appendingPathComponent(fileName)

        return MediaFileInfo(
            fileName: fileName,
            url: url,
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

    func createTestLinkingResult(segments: [MediaFileInfo]) -> LinkingResult {
        let ocf = createTestOCF(fileName: "OCF001.mov")

        let linkedSegments = segments.map { segment in
            LinkedSegment(segment: segment, linkConfidence: .high, linkMethod: "test")
        }

        let ocfParent = OCFParent(ocf: ocf, children: linkedSegments)

        return LinkingResult(
            ocfParents: [ocfParent],
            unmatchedSegments: [],
            unmatchedOCFs: []
        )
    }

    // MARK: - processDetectedFiles Tests

    func testProcessDetectedFiles_AutoImportDisabled() {
        let files = [testDirectory.appendingPathComponent("new_file.mov")]

        let result = AutoImportService.processDetectedFiles(
            files: files,
            isVFX: false,
            existingSegments: [],
            offlineFiles: [],
            offlineMetadata: [:],
            trackedSizes: [:],
            linkingResult: nil,
            autoImportEnabled: false
        )

        XCTAssertTrue(result.filesToImport.isEmpty, "Should not import when auto-import is disabled")
    }

    func testProcessDetectedFiles_NewFiles() {
        let newFile = testDirectory.appendingPathComponent("new_file.mov")
        FileManager.default.createFile(atPath: newFile.path, contents: Data(), attributes: nil)

        let result = AutoImportService.processDetectedFiles(
            files: [newFile],
            isVFX: false,
            existingSegments: [],
            offlineFiles: [],
            offlineMetadata: [:],
            trackedSizes: [:],
            linkingResult: nil,
            autoImportEnabled: true
        )

        XCTAssertEqual(result.filesToImport.count, 1, "Should identify new file for import")
        XCTAssertEqual(result.filesToImport.first?.lastPathComponent, "new_file.mov")
    }

    func testProcessDetectedFiles_ReturningUnchanged() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)

        // Mark as offline
        let offlineFiles: Set<String> = ["segment.mov"]
        let offlineMetadata: [String: OfflineFileMetadata] = [
            "segment.mov": OfflineFileMetadata(
                fileName: "segment.mov",
                fileSize: 1000,
                offlineDate: Date(),
                partialHash: nil
            )
        ]
        let trackedSizes: [String: Int64] = ["segment.mov": 1000]

        let result = AutoImportService.processDetectedFiles(
            files: [segment.url],
            isVFX: false,
            existingSegments: [segment],
            offlineFiles: offlineFiles,
            offlineMetadata: offlineMetadata,
            trackedSizes: trackedSizes,
            linkingResult: nil,
            autoImportEnabled: true
        )

        XCTAssertTrue(result.returningUnchanged.contains("segment.mov"), "Should identify returning unchanged file")
        XCTAssertTrue(result.filesToImport.isEmpty, "Should not import returning unchanged files")
    }

    func testProcessDetectedFiles_ReturningChanged() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 2000) // Different size

        // Mark as offline with different size
        let offlineFiles: Set<String> = ["segment.mov"]
        let offlineMetadata: [String: OfflineFileMetadata] = [
            "segment.mov": OfflineFileMetadata(
                fileName: "segment.mov",
                fileSize: 1000,  // Old size
                offlineDate: Date(),
                partialHash: nil
            )
        ]
        let trackedSizes: [String: Int64] = ["segment.mov": 1000]

        let result = AutoImportService.processDetectedFiles(
            files: [segment.url],
            isVFX: false,
            existingSegments: [segment],
            offlineFiles: offlineFiles,
            offlineMetadata: offlineMetadata,
            trackedSizes: trackedSizes,
            linkingResult: nil,
            autoImportEnabled: true
        )

        XCTAssertTrue(result.modifiedFiles.contains("segment.mov"), "Should mark returning changed file as modified")
        XCTAssertNotNil(result.modificationDates["segment.mov"], "Should set modification date")
        XCTAssertTrue(result.filesToImport.isEmpty, "Should not import returning changed files (already imported)")
    }

    func testProcessDetectedFiles_MarksOCFsForReprint() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 2000)
        let linkingResult = createTestLinkingResult(segments: [segment])

        // Mark as offline with different size
        let offlineFiles: Set<String> = ["segment.mov"]
        let offlineMetadata: [String: OfflineFileMetadata] = [
            "segment.mov": OfflineFileMetadata(
                fileName: "segment.mov",
                fileSize: 1000,
                offlineDate: Date(),
                partialHash: nil
            )
        ]
        let trackedSizes: [String: Int64] = ["segment.mov": 1000]

        let result = AutoImportService.processDetectedFiles(
            files: [segment.url],
            isVFX: false,
            existingSegments: [segment],
            offlineFiles: offlineFiles,
            offlineMetadata: offlineMetadata,
            trackedSizes: trackedSizes,
            linkingResult: linkingResult,
            autoImportEnabled: true
        )

        XCTAssertTrue(result.ocfsNeedingReprint.contains("OCF001.mov"), "Should mark OCF for reprint")
        XCTAssertNotNil(result.printStatusUpdates["OCF001.mov"], "Should have print status update")
        XCTAssertEqual(result.printStatusUpdates["OCF001.mov"]?.reason, "segmentModified")
    }

    // MARK: - processDeletedFiles Tests

    func testProcessDeletedFiles_MarkAsOffline() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)
        let trackedSizes: [String: Int64] = ["segment.mov": 1000]

        let result = AutoImportService.processDeletedFiles(
            fileNames: ["segment.mov"],
            isVFX: false,
            existingSegments: [segment],
            trackedSizes: trackedSizes,
            linkingResult: nil
        )

        XCTAssertTrue(result.offlineFiles.contains("segment.mov"), "Should mark file as offline")
        XCTAssertNotNil(result.offlineMetadata["segment.mov"], "Should create offline metadata")
        XCTAssertEqual(result.offlineMetadata["segment.mov"]?.fileSize, 1000)
    }

    func testProcessDeletedFiles_MarksOCFsForReprint() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)
        let linkingResult = createTestLinkingResult(segments: [segment])
        let trackedSizes: [String: Int64] = ["segment.mov": 1000]

        let result = AutoImportService.processDeletedFiles(
            fileNames: ["segment.mov"],
            isVFX: false,
            existingSegments: [segment],
            trackedSizes: trackedSizes,
            linkingResult: linkingResult
        )

        XCTAssertTrue(result.ocfsNeedingReprint.contains("OCF001.mov"), "Should mark OCF for reprint")
        XCTAssertNotNil(result.printStatusUpdates["OCF001.mov"], "Should have print status update")
        XCTAssertEqual(result.printStatusUpdates["OCF001.mov"]?.reason, "segmentOffline")
    }

    func testProcessDeletedFiles_NoTrackedSize() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)

        let result = AutoImportService.processDeletedFiles(
            fileNames: ["segment.mov"],
            isVFX: false,
            existingSegments: [segment],
            trackedSizes: [:],  // No tracked size
            linkingResult: nil
        )

        XCTAssertTrue(result.offlineFiles.contains("segment.mov"), "Should still mark as offline")
        XCTAssertNil(result.offlineMetadata["segment.mov"], "Should not create metadata without size")
    }

    func testProcessDeletedFiles_UnknownFile() {
        let result = AutoImportService.processDeletedFiles(
            fileNames: ["unknown.mov"],
            isVFX: false,
            existingSegments: [],
            trackedSizes: [:],
            linkingResult: nil
        )

        XCTAssertTrue(result.offlineFiles.isEmpty, "Should not mark unknown file as offline")
    }

    // MARK: - processModifiedFiles Tests

    func testProcessModifiedFiles_UpdatesModificationDate() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)

        let result = AutoImportService.processModifiedFiles(
            fileNames: ["segment.mov"],
            isVFX: false,
            existingSegments: [segment],
            linkingResult: nil
        )

        XCTAssertTrue(result.modifiedFiles.contains("segment.mov"), "Should mark file as modified")
        XCTAssertNotNil(result.modificationDates["segment.mov"], "Should set modification date")
        XCTAssertNotNil(result.updatedFileSizes["segment.mov"], "Should update file size")
    }

    func testProcessModifiedFiles_MarksOCFsForReprint() {
        let segment = createTestSegment(fileName: "segment.mov", fileSize: 1000)
        let linkingResult = createTestLinkingResult(segments: [segment])

        let result = AutoImportService.processModifiedFiles(
            fileNames: ["segment.mov"],
            isVFX: false,
            existingSegments: [segment],
            linkingResult: linkingResult
        )

        XCTAssertTrue(result.ocfsNeedingReprint.contains("OCF001.mov"), "Should mark OCF for reprint")
        XCTAssertNotNil(result.printStatusUpdates["OCF001.mov"], "Should have print status update")
        XCTAssertEqual(result.printStatusUpdates["OCF001.mov"]?.reason, "segmentModified")
    }

    func testProcessModifiedFiles_UnknownFile() {
        let result = AutoImportService.processModifiedFiles(
            fileNames: ["unknown.mov"],
            isVFX: false,
            existingSegments: [],
            linkingResult: nil
        )

        XCTAssertTrue(result.modifiedFiles.isEmpty, "Should not mark unknown file as modified")
    }

    func testProcessModifiedFiles_MultipleFiles() {
        let segment1 = createTestSegment(fileName: "segment1.mov", fileSize: 1000)
        let segment2 = createTestSegment(fileName: "segment2.mov", fileSize: 2000)

        let result = AutoImportService.processModifiedFiles(
            fileNames: ["segment1.mov", "segment2.mov"],
            isVFX: false,
            existingSegments: [segment1, segment2],
            linkingResult: nil
        )

        XCTAssertEqual(result.modifiedFiles.count, 2, "Should mark both files as modified")
        XCTAssertTrue(result.modifiedFiles.contains("segment1.mov"))
        XCTAssertTrue(result.modifiedFiles.contains("segment2.mov"))
    }

    // MARK: - AutoImportResult Tests

    func testAutoImportResult_DefaultInit() {
        let result = AutoImportResult()

        XCTAssertTrue(result.filesToImport.isEmpty)
        XCTAssertTrue(result.offlineFiles.isEmpty)
        XCTAssertTrue(result.offlineMetadata.isEmpty)
        XCTAssertTrue(result.modifiedFiles.isEmpty)
        XCTAssertTrue(result.modificationDates.isEmpty)
        XCTAssertTrue(result.updatedFileSizes.isEmpty)
        XCTAssertTrue(result.ocfsNeedingReprint.isEmpty)
        XCTAssertTrue(result.printStatusUpdates.isEmpty)
        XCTAssertTrue(result.returningUnchanged.isEmpty)
    }
}
