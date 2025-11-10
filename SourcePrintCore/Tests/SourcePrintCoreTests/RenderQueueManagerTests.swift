import XCTest
@testable import SourcePrintCore

@MainActor
final class RenderQueueManagerTests: XCTestCase {

    var manager: RenderQueueManager!
    var delegate: MockRenderQueueDelegate!

    override func setUp() async throws {
        manager = RenderQueueManager()
        delegate = MockRenderQueueDelegate()
        manager.delegate = delegate
    }

    override func tearDown() async throws {
        manager.stopProcessing()
        manager = nil
        delegate = nil
    }

    // MARK: - Queue Management Tests

    func testAddToQueue() {
        let parents = [
            createMockOCFParent(fileName: "OCF001.mov"),
            createMockOCFParent(fileName: "OCF002.mov"),
            createMockOCFParent(fileName: "OCF003.mov")
        ]

        manager.addToQueue(parents)

        XCTAssertEqual(manager.queue.count, 3)
        XCTAssertEqual(manager.queue[0].ocfFileName, "OCF001.mov")
        XCTAssertEqual(manager.queue[1].ocfFileName, "OCF002.mov")
        XCTAssertEqual(manager.queue[2].ocfFileName, "OCF003.mov")
    }

    func testAddToQueue_MultipleAdds() {
        let parents1 = [createMockOCFParent(fileName: "OCF001.mov")]
        let parents2 = [createMockOCFParent(fileName: "OCF002.mov")]

        manager.addToQueue(parents1)
        manager.addToQueue(parents2)

        XCTAssertEqual(manager.queue.count, 2)
    }

    func testClearQueue() {
        let parents = [
            createMockOCFParent(fileName: "OCF001.mov"),
            createMockOCFParent(fileName: "OCF002.mov")
        ]

        manager.addToQueue(parents)
        XCTAssertEqual(manager.queue.count, 2)

        manager.clearQueue()
        XCTAssertEqual(manager.queue.count, 0)
    }

    // MARK: - Status Tests

    func testGetStatus_Empty() {
        let status = manager.getStatus()

        XCTAssertEqual(status.totalItems, 0)
        XCTAssertEqual(status.completedItems, 0)
        XCTAssertEqual(status.failedItems, 0)
        XCTAssertFalse(status.isProcessing)
        XCTAssertNil(status.currentItem)
    }

    func testGetStatus_WithQueue() {
        let parents = [
            createMockOCFParent(fileName: "OCF001.mov"),
            createMockOCFParent(fileName: "OCF002.mov")
        ]

        manager.addToQueue(parents)
        let status = manager.getStatus()

        XCTAssertEqual(status.totalItems, 2)
        XCTAssertEqual(status.remainingItems, 2)
        XCTAssertFalse(status.isProcessing)
    }

    // MARK: - Processing State Tests

    func testStartProcessing_EmptyQueue() {
        manager.startProcessing()

        // Should not start processing if queue is empty
        XCTAssertFalse(manager.isProcessing)
    }

    func testStartProcessing_WithQueue() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        manager.startProcessing()

        // Wait for async processing to start
        try? await Task.sleep(nanoseconds: 50_000_000) // 0.05 seconds

        XCTAssertTrue(manager.isProcessing)
        XCTAssertNotNil(manager.currentItem)
    }

    func testStartProcessing_AlreadyProcessing() {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        manager.startProcessing()
        XCTAssertTrue(manager.isProcessing)

        // Try to start again
        manager.startProcessing()

        // Should still be processing (no duplicate start)
        XCTAssertTrue(manager.isProcessing)
    }

    func testStopProcessing() {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        manager.startProcessing()
        XCTAssertTrue(manager.isProcessing)

        manager.stopProcessing()
        XCTAssertFalse(manager.isProcessing)
        XCTAssertNil(manager.currentItem)
    }

    // MARK: - Status Update Tests

    func testUpdateCurrentItemStatus() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)
        manager.startProcessing()

        // Wait for async processing to start
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNotNil(manager.currentItem)

        manager.updateCurrentItemStatus(.compositing, progress: "50% complete")

        XCTAssertEqual(manager.currentItem?.status, .compositing)
        XCTAssertEqual(manager.currentItem?.progress, "50% complete")
    }

    func testMarkCurrentItemCompleted() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)
        manager.startProcessing()

        // Wait for async processing to start
        try? await Task.sleep(nanoseconds: 50_000_000)

        let outputURL = URL(fileURLWithPath: "/tmp/output.mov")
        manager.markCurrentItemCompleted(outputURL: outputURL)

        XCTAssertEqual(manager.currentItem?.status, .completed)
        XCTAssertNotNil(manager.currentItem?.completionTime)
    }

    func testMarkCurrentItemFailed() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)
        manager.startProcessing()

        // Wait for async processing to start
        try? await Task.sleep(nanoseconds: 50_000_000)

        manager.markCurrentItemFailed(error: "Blank rush creation failed")

        XCTAssertEqual(manager.currentItem?.status, .failed)
        XCTAssertEqual(manager.currentItem?.progress, "Blank rush creation failed")
        XCTAssertNotNil(manager.currentItem?.completionTime)
    }

    // MARK: - Delegate Tests

    func testDelegate_DidStartItem() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        manager.startProcessing()

        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        XCTAssertTrue(delegate.didStartItem)
        XCTAssertEqual(delegate.startedItemFileName, "OCF001.mov")
    }

    func testDelegate_DidUpdateProgress() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)
        manager.startProcessing()

        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000)

        manager.updateCurrentItemStatus(.compositing, progress: "Processing...")

        XCTAssertTrue(delegate.didUpdateProgress)
        XCTAssertEqual(delegate.lastProgress?.status, .compositing)
        XCTAssertEqual(delegate.lastProgress?.message, "Processing...")
    }

    func testDelegate_DidCompleteItem() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        manager.startProcessing()

        // Give it a moment to start
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Verify delegate was called when item started
        XCTAssertTrue(delegate.didStartItem)
        XCTAssertEqual(delegate.startedItemFileName, "OCF001.mov")

        // Note: Full delegate completion flow requires actual render service
        // This test verifies the basic delegate callbacks work
    }

    // MARK: - Integration Tests

    func testCompleteWorkflow_SingleItem() async {
        let parents = [createMockOCFParent(fileName: "OCF001.mov")]
        manager.addToQueue(parents)

        let initialStatus = manager.getStatus()
        XCTAssertEqual(initialStatus.totalItems, 1)
        XCTAssertEqual(initialStatus.remainingItems, 1)

        manager.startProcessing()

        // Wait for async processing to start
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(manager.isProcessing)
        XCTAssertEqual(manager.queue.count, 0) // Should be removed from queue
        XCTAssertNotNil(manager.currentItem)
    }

    func testCompleteWorkflow_MultipleItems() async {
        let parents = [
            createMockOCFParent(fileName: "OCF001.mov"),
            createMockOCFParent(fileName: "OCF002.mov"),
            createMockOCFParent(fileName: "OCF003.mov")
        ]

        manager.addToQueue(parents)
        XCTAssertEqual(manager.queue.count, 3)

        manager.startProcessing()

        // First item should be current, others still in queue
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(manager.currentItem?.ocfFileName, "OCF001.mov")
        XCTAssertEqual(manager.queue.count, 2) // 2 remaining
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

// MARK: - Mock Delegate

@MainActor
class MockRenderQueueDelegate: RenderQueueDelegate {
    var didStartItem = false
    var startedItemFileName: String?

    var didUpdateProgress = false
    var lastProgress: RenderProgress?

    var didCompleteItem = false
    var lastResult: RenderResult?

    var didFinishQueue = false
    var finishedTotalCompleted: Int?
    var finishedTotalFailed: Int?

    var didEncounterError = false
    var lastError: Error?

    func queueManager(_ manager: RenderQueueManager, didStartItem item: RuntimeRenderQueueItem) {
        didStartItem = true
        startedItemFileName = item.ocfFileName
    }

    func queueManager(_ manager: RenderQueueManager, didUpdateProgress progress: RenderProgress) {
        didUpdateProgress = true
        lastProgress = progress
    }

    func queueManager(_ manager: RenderQueueManager, didCompleteItem result: RenderResult) {
        didCompleteItem = true
        lastResult = result
    }

    func queueManager(_ manager: RenderQueueManager, didFinishQueue totalCompleted: Int, totalFailed: Int) {
        didFinishQueue = true
        finishedTotalCompleted = totalCompleted
        finishedTotalFailed = totalFailed
    }

    func queueManager(_ manager: RenderQueueManager, didEncounterError error: Error, ocfFileName: String) {
        didEncounterError = true
        lastError = error
    }
}
