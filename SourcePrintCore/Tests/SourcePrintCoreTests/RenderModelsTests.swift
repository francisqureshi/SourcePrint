import XCTest
@testable import SourcePrintCore

final class RenderModelsTests: XCTestCase {

    // MARK: - RenderStatus Tests

    func testRenderStatus_IsInProgress() {
        XCTAssertFalse(RenderStatus.pending.isInProgress)
        XCTAssertTrue(RenderStatus.generatingBlankRush.isInProgress)
        XCTAssertTrue(RenderStatus.compositing.isInProgress)
        XCTAssertFalse(RenderStatus.completed.isInProgress)
        XCTAssertFalse(RenderStatus.failed.isInProgress)
    }

    func testRenderStatus_IsFinished() {
        XCTAssertFalse(RenderStatus.pending.isFinished)
        XCTAssertFalse(RenderStatus.generatingBlankRush.isFinished)
        XCTAssertFalse(RenderStatus.compositing.isFinished)
        XCTAssertTrue(RenderStatus.completed.isFinished)
        XCTAssertTrue(RenderStatus.failed.isFinished)
    }

    // MARK: - RuntimeRenderQueueItem Tests

    func testRuntimeRenderQueueItem_Initialization() {
        let ocfParent = createMockOCFParent(fileName: "OCF001.mov")
        let item = RuntimeRenderQueueItem(
            ocfFileName: "OCF001.mov",
            ocfParent: ocfParent,
            status: .pending,
            progress: "Waiting..."
        )

        XCTAssertEqual(item.ocfFileName, "OCF001.mov")
        XCTAssertEqual(item.status, .pending)
        XCTAssertEqual(item.progress, "Waiting...")
        XCTAssertNil(item.startTime)
        XCTAssertNil(item.completionTime)
        XCTAssertNil(item.duration)
    }

    func testRuntimeRenderQueueItem_DurationCalculation() {
        let ocfParent = createMockOCFParent(fileName: "OCF001.mov")
        let startTime = Date()
        let completionTime = startTime.addingTimeInterval(10.5)

        let item = RuntimeRenderQueueItem(
            ocfFileName: "OCF001.mov",
            ocfParent: ocfParent,
            status: .completed,
            progress: "Done",
            startTime: startTime,
            completionTime: completionTime
        )

        XCTAssertNotNil(item.duration)
        XCTAssertEqual(item.duration!, 10.5, accuracy: 0.01)
    }

    func testRuntimeRenderQueueItem_DurationWhileInProgress() {
        let ocfParent = createMockOCFParent(fileName: "OCF001.mov")
        let startTime = Date().addingTimeInterval(-5) // Started 5 seconds ago

        let item = RuntimeRenderQueueItem(
            ocfFileName: "OCF001.mov",
            ocfParent: ocfParent,
            status: .compositing,
            progress: "Processing...",
            startTime: startTime
        )

        // Duration should be calculated from startTime to now
        XCTAssertNotNil(item.duration)
        XCTAssertGreaterThan(item.duration!, 4.0) // At least 4 seconds
        XCTAssertLessThan(item.duration!, 6.0)    // Less than 6 seconds
    }

    func testRuntimeRenderQueueItem_Equality() {
        let ocfParent = createMockOCFParent(fileName: "OCF001.mov")
        let id = UUID()

        let item1 = RuntimeRenderQueueItem(id: id, ocfFileName: "OCF001.mov", ocfParent: ocfParent, status: .pending)
        let item2 = RuntimeRenderQueueItem(id: id, ocfFileName: "OCF001.mov", ocfParent: ocfParent, status: .pending)
        let item3 = RuntimeRenderQueueItem(id: UUID(), ocfFileName: "OCF001.mov", ocfParent: ocfParent, status: .pending)

        XCTAssertEqual(item1, item2) // Same id and status
        XCTAssertNotEqual(item1, item3) // Different id
    }

    // MARK: - RenderProgress Tests

    func testRenderProgress_Initialization() {
        let progress = RenderProgress(
            ocfFileName: "OCF001.mov",
            status: .compositing,
            message: "Processing frame 100/200",
            percentage: 50.0,
            elapsedTime: 12.5
        )

        XCTAssertEqual(progress.ocfFileName, "OCF001.mov")
        XCTAssertEqual(progress.status, .compositing)
        XCTAssertEqual(progress.message, "Processing frame 100/200")
        XCTAssertEqual(progress.percentage, 50.0)
        XCTAssertEqual(progress.elapsedTime, 12.5)
    }

    func testRenderProgress_OptionalFields() {
        let progress = RenderProgress(
            ocfFileName: "OCF001.mov",
            status: .pending,
            message: "Waiting..."
        )

        XCTAssertNil(progress.percentage)
        XCTAssertNil(progress.elapsedTime)
    }

    // MARK: - RenderResult Tests

    func testRenderResult_Success() {
        let outputURL = URL(fileURLWithPath: "/tmp/output.mov")
        let result = RenderResult(
            ocfFileName: "OCF001.mov",
            success: true,
            outputURL: outputURL,
            error: nil,
            duration: 45.3,
            segmentCount: 5
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.outputURL, outputURL)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.duration, 45.3)
        XCTAssertEqual(result.segmentCount, 5)
    }

    func testRenderResult_Failure() {
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

    func testRenderResult_Equality() {
        let url = URL(fileURLWithPath: "/tmp/output.mov")
        let result1 = RenderResult(ocfFileName: "OCF001.mov", success: true, outputURL: url, duration: 10.0, segmentCount: 3)
        let result2 = RenderResult(ocfFileName: "OCF001.mov", success: true, outputURL: url, duration: 10.0, segmentCount: 3)
        let result3 = RenderResult(ocfFileName: "OCF002.mov", success: true, outputURL: url, duration: 10.0, segmentCount: 3)

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3) // Different OCF name
    }

    // MARK: - RenderConfiguration Tests

    func testRenderConfiguration_Initialization() {
        let blankRushDir = URL(fileURLWithPath: "/tmp/blank_rushes")
        let outputDir = URL(fileURLWithPath: "/tmp/output")

        let config = RenderConfiguration(
            blankRushDirectory: blankRushDir,
            outputDirectory: outputDir,
            proResProfile: "4"
        )

        XCTAssertEqual(config.blankRushDirectory, blankRushDir)
        XCTAssertEqual(config.outputDirectory, outputDir)
        XCTAssertEqual(config.proResProfile, "4")
    }

    func testRenderConfiguration_DefaultProResProfile() {
        let blankRushDir = URL(fileURLWithPath: "/tmp/blank_rushes")
        let outputDir = URL(fileURLWithPath: "/tmp/output")

        let config = RenderConfiguration(
            blankRushDirectory: blankRushDir,
            outputDirectory: outputDir
        )

        XCTAssertEqual(config.proResProfile, "4") // Default should be "4"
    }

    // MARK: - RenderQueueStatus Tests

    func testRenderQueueStatus_Empty() {
        let status = RenderQueueStatus(
            totalItems: 0,
            completedItems: 0,
            failedItems: 0,
            isProcessing: false
        )

        XCTAssertEqual(status.totalItems, 0)
        XCTAssertEqual(status.remainingItems, 0)
        XCTAssertEqual(status.successfulItems, 0)
        XCTAssertEqual(status.progressPercentage, 0.0)
    }

    func testRenderQueueStatus_InProgress() {
        let ocfParent = createMockOCFParent(fileName: "OCF001.mov")
        let currentItem = RuntimeRenderQueueItem(ocfFileName: "OCF001.mov", ocfParent: ocfParent, status: .compositing)

        let status = RenderQueueStatus(
            totalItems: 10,
            completedItems: 3,
            failedItems: 1,
            isProcessing: true,
            currentItem: currentItem
        )

        XCTAssertEqual(status.totalItems, 10)
        XCTAssertEqual(status.completedItems, 3)
        XCTAssertEqual(status.failedItems, 1)
        XCTAssertEqual(status.remainingItems, 6) // 10 - 3 - 1 = 6
        XCTAssertEqual(status.successfulItems, 2) // 3 - 1 = 2
        XCTAssertEqual(status.progressPercentage, 0.4, accuracy: 0.01) // 4/10 = 0.4
        XCTAssertTrue(status.isProcessing)
        XCTAssertNotNil(status.currentItem)
    }

    func testRenderQueueStatus_Completed() {
        let status = RenderQueueStatus(
            totalItems: 5,
            completedItems: 5,
            failedItems: 0,
            isProcessing: false
        )

        XCTAssertEqual(status.remainingItems, 0)
        XCTAssertEqual(status.successfulItems, 5)
        XCTAssertEqual(status.progressPercentage, 1.0)
        XCTAssertFalse(status.isProcessing)
    }

    func testRenderQueueStatus_PartialFailures() {
        let status = RenderQueueStatus(
            totalItems: 10,
            completedItems: 7, // 7 successful completions
            failedItems: 3,     // 3 failed
            isProcessing: false
        )

        XCTAssertEqual(status.successfulItems, 4) // 7 completed - 3 failed = 4 successful (if failed counted in completed)
        XCTAssertEqual(status.progressPercentage, 1.0) // All processed: (7 + 3) / 10 = 100%
    }

    // MARK: - Helper Methods

    private func createMockOCFParent(fileName: String) -> OCFParent {
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

        return OCFParent(ocf: ocf, children: [])
    }
}
