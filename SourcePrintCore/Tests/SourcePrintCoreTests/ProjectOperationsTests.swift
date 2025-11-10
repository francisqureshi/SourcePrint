import XCTest
@testable import SourcePrintCore

final class ProjectOperationsTests: XCTestCase {

    var testDirectory: URL!

    override func setUp() {
        super.setUp()
        testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDirectory)
        super.tearDown()
    }

    // MARK: - Helper Methods

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

    func createTestSegment(fileName: String, fileSize: Int64 = 1000) -> MediaFileInfo {
        let url = testDirectory.appendingPathComponent(fileName)

        // Create actual file
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

    // MARK: - Add Operations Tests

    func testAddOCFFiles() {
        let existingOCF = createTestOCF(fileName: "OCF001.mov")
        let newOCF = createTestOCF(fileName: "OCF002.mov")

        let result = ProjectOperations.addOCFFiles(
            [newOCF],
            existingOCFs: [existingOCF]
        )

        XCTAssertEqual(result.ocfFiles?.count, 2, "Should have 2 OCFs after adding")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
        XCTAssertNotNil(result.ocfFiles?.first(where: { $0.fileName == "OCF002.mov" }))
    }

    func testAddSegments() {
        let existingSegment = createTestSegment(fileName: "segment1.mov", fileSize: 1000)
        let newSegment = createTestSegment(fileName: "segment2.mov", fileSize: 2000)

        let result = ProjectOperations.addSegments(
            [newSegment],
            existingSegments: [existingSegment],
            existingFileSizes: ["segment1.mov": 1000]
        )

        XCTAssertEqual(result.segments?.count, 2, "Should have 2 segments after adding")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
        XCTAssertEqual(result.segmentFileSizes?["segment2.mov"], 2000, "Should track file size for new segment")
    }

    func testAddSegments_TracksFileSizes() {
        let newSegment = createTestSegment(fileName: "segment.mov", fileSize: 5000)

        let result = ProjectOperations.addSegments(
            [newSegment],
            existingSegments: [],
            existingFileSizes: [:]
        )

        XCTAssertNotNil(result.segmentFileSizes?["segment.mov"], "Should track file size")
        XCTAssertEqual(result.segmentFileSizes?["segment.mov"], 5000)
    }

    // MARK: - Remove Operations Tests

    func testRemoveOCFFiles() {
        let ocf1 = createTestOCF(fileName: "OCF001.mov")
        let ocf2 = createTestOCF(fileName: "OCF002.mov")

        let result = ProjectOperations.removeOCFFiles(
            ["OCF001.mov"],
            existingOCFs: [ocf1, ocf2],
            existingBlankRushStatus: ["OCF001.mov": "completed", "OCF002.mov": "notCreated"]
        )

        XCTAssertEqual(result.ocfFiles?.count, 1, "Should have 1 OCF after removal")
        XCTAssertNil(result.ocfFiles?.first(where: { $0.fileName == "OCF001.mov" }), "Should not find removed OCF")
        XCTAssertNil(result.blankRushStatus?["OCF001.mov"], "Should remove blank rush status")
        XCTAssertTrue(result.shouldInvalidateLinking, "Should invalidate linking")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
    }

    func testRemoveSegments() {
        let segment1 = createTestSegment(fileName: "segment1.mov")
        let segment2 = createTestSegment(fileName: "segment2.mov")

        let result = ProjectOperations.removeSegments(
            ["segment1.mov"],
            existingSegments: [segment1, segment2],
            existingModDates: ["segment1.mov": Date(), "segment2.mov": Date()],
            existingFileSizes: ["segment1.mov": 1000, "segment2.mov": 2000],
            existingOfflineFiles: ["segment1.mov"]
        )

        XCTAssertEqual(result.segments?.count, 1, "Should have 1 segment after removal")
        XCTAssertNil(result.segments?.first(where: { $0.fileName == "segment1.mov" }))
        XCTAssertNil(result.segmentModificationDates?["segment1.mov"], "Should remove mod date")
        XCTAssertNil(result.segmentFileSizes?["segment1.mov"], "Should remove file size")
        XCTAssertFalse(result.offlineFiles?.contains("segment1.mov") ?? true, "Should remove from offline set")
        XCTAssertTrue(result.shouldInvalidateLinking, "Should invalidate linking")
    }

    func testRemoveOfflineMedia() {
        let segment1 = createTestSegment(fileName: "segment1.mov")
        let segment2 = createTestSegment(fileName: "segment2.mov")
        let ocf = createTestOCF(fileName: "OCF001.mov")

        let offlineFiles: Set<String> = ["segment1.mov", "OCF001.mov"]

        let result = ProjectOperations.removeOfflineMedia(
            offlineFiles: offlineFiles,
            existingOCFs: [ocf],
            existingSegments: [segment1, segment2],
            existingModDates: ["segment1.mov": Date()],
            existingFileSizes: ["segment1.mov": 1000],
            existingPrintStatus: ["OCF001.mov": "printed"],
            existingBlankRushStatus: ["OCF001.mov": "completed"],
            existingOfflineMetadata: ["segment1.mov": OfflineFileMetadata(
                fileName: "segment1.mov",
                fileSize: 1000,
                offlineDate: Date(),
                partialHash: nil
            )]
        )

        XCTAssertEqual(result.segments?.count, 1, "Should remove offline segment")
        XCTAssertEqual(result.ocfFiles?.count, 0, "Should remove offline OCF")
        XCTAssertTrue(result.offlineFiles?.isEmpty ?? false, "Should clear offline set")
        XCTAssertNil(result.printStatus?["OCF001.mov"], "Should remove print status")
        XCTAssertNil(result.blankRushStatus?["OCF001.mov"], "Should remove blank rush status")
        XCTAssertTrue(result.shouldInvalidateLinking, "Should invalidate linking")
    }

    func testRemoveOfflineMedia_EmptySet() {
        let segment = createTestSegment(fileName: "segment.mov")

        let result = ProjectOperations.removeOfflineMedia(
            offlineFiles: Set(),
            existingOCFs: [],
            existingSegments: [segment],
            existingModDates: [:],
            existingFileSizes: [:],
            existingPrintStatus: [:],
            existingBlankRushStatus: [:],
            existingOfflineMetadata: [:]
        )

        XCTAssertEqual(result.segments?.count, 1, "Should not remove any segments")
        XCTAssertFalse(result.shouldInvalidateLinking, "Should not invalidate linking when empty")
    }

    // MARK: - Toggle Operations Tests

    func testToggleOCFVFXStatus() {
        let ocf = createTestOCF(fileName: "OCF001.mov")

        let result = ProjectOperations.toggleOCFVFXStatus(
            "OCF001.mov",
            isVFX: true,
            existingOCFs: [ocf]
        )

        XCTAssertTrue(result.ocfFiles?.first?.isVFXShot ?? false, "Should set VFX status to true")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
    }

    func testToggleOCFVFXStatus_NonexistentFile() {
        let ocf = createTestOCF(fileName: "OCF001.mov")

        let result = ProjectOperations.toggleOCFVFXStatus(
            "OCF999.mov",
            isVFX: true,
            existingOCFs: [ocf]
        )

        XCTAssertNil(result.ocfFiles, "Should not return updated OCFs for nonexistent file")
        XCTAssertFalse(result.shouldUpdateModified, "Should not trigger modified update")
    }

    func testToggleSegmentVFXStatus() {
        let segment = createTestSegment(fileName: "segment.mov")

        let result = ProjectOperations.toggleSegmentVFXStatus(
            "segment.mov",
            isVFX: true,
            existingSegments: [segment]
        )

        XCTAssertTrue(result.segments?.first?.isVFXShot ?? false, "Should set VFX status to true")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
    }

    func testToggleSegmentVFXStatus_NonexistentFile() {
        let segment = createTestSegment(fileName: "segment.mov")

        let result = ProjectOperations.toggleSegmentVFXStatus(
            "nonexistent.mov",
            isVFX: true,
            existingSegments: [segment]
        )

        XCTAssertNil(result.segments, "Should not return updated segments for nonexistent file")
        XCTAssertFalse(result.shouldUpdateModified, "Should not trigger modified update")
    }

    // MARK: - Refresh Operations Tests

    func testRefreshSegmentModificationDates() {
        let segment = createTestSegment(fileName: "segment.mov")

        let result = ProjectOperations.refreshSegmentModificationDates(
            existingSegments: [segment],
            existingModDates: [:]
        )

        XCTAssertNotNil(result.segmentModificationDates?["segment.mov"], "Should set modification date")
        XCTAssertTrue(result.shouldUpdateModified, "Should trigger modified update")
    }

    // MARK: - Check Modified Segments Tests

    func testCheckForModifiedSegments_NoModifications() {
        let segment = createTestSegment(fileName: "segment.mov")

        // Set file date to past
        let pastDate = Date().addingTimeInterval(-3600)
        try? FileManager.default.setAttributes(
            [.modificationDate: pastDate],
            ofItemAtPath: segment.url.path
        )

        let ocf = createTestOCF(fileName: "OCF001.mov")
        let linkedSegment = LinkedSegment(segment: segment, linkConfidence: .high, linkMethod: "test")
        let ocfParent = OCFParent(ocf: ocf, children: [linkedSegment])
        let linkingResult = LinkingResult(ocfParents: [ocfParent], unmatchedSegments: [], unmatchedOCFs: [])

        let printStatus: [String: (Bool, Date?, URL?)] = [
            "OCF001.mov": (true, Date(), nil)
        ]

        let (needsReprint, statusChanged) = ProjectOperations.checkForModifiedSegments(
            linkingResult: linkingResult,
            existingPrintStatus: printStatus
        )

        XCTAssertTrue(needsReprint.isEmpty, "Should not need reprint")
        XCTAssertFalse(statusChanged, "Status should not change")
    }

    func testCheckForModifiedSegments_NoLinkingResult() {
        let printStatus: [String: (Bool, Date?, URL?)] = [:]

        let (needsReprint, statusChanged) = ProjectOperations.checkForModifiedSegments(
            linkingResult: nil,
            existingPrintStatus: printStatus
        )

        XCTAssertTrue(needsReprint.isEmpty, "Should not need reprint without linking")
        XCTAssertFalse(statusChanged, "Status should not change")
    }

    func testCheckForModifiedSegments_NotPrinted() {
        let segment = createTestSegment(fileName: "segment.mov")
        let ocf = createTestOCF(fileName: "OCF001.mov")
        let linkedSegment = LinkedSegment(segment: segment, linkConfidence: .high, linkMethod: "test")
        let ocfParent = OCFParent(ocf: ocf, children: [linkedSegment])
        let linkingResult = LinkingResult(ocfParents: [ocfParent], unmatchedSegments: [], unmatchedOCFs: [])

        let printStatus: [String: (Bool, Date?, URL?)] = [
            "OCF001.mov": (false, nil, nil)  // Not printed
        ]

        let (needsReprint, statusChanged) = ProjectOperations.checkForModifiedSegments(
            linkingResult: linkingResult,
            existingPrintStatus: printStatus
        )

        XCTAssertTrue(needsReprint.isEmpty, "Should not check unprinted OCFs")
        XCTAssertFalse(statusChanged, "Status should not change")
    }

    // MARK: - ProjectOperationResult Tests

    func testProjectOperationResult_DefaultInit() {
        let result = ProjectOperationResult()

        XCTAssertNil(result.ocfFiles)
        XCTAssertNil(result.segments)
        XCTAssertNil(result.segmentModificationDates)
        XCTAssertNil(result.segmentFileSizes)
        XCTAssertNil(result.offlineFiles)
        XCTAssertNil(result.offlineMetadata)
        XCTAssertNil(result.printStatus)
        XCTAssertNil(result.blankRushStatus)
        XCTAssertFalse(result.shouldInvalidateLinking)
        XCTAssertFalse(result.shouldUpdateModified)
    }
}
