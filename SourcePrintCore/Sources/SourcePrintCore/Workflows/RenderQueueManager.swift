import Foundation
import Combine

// MARK: - Segment Progress

/// Segment-level progress for real-time UI updates
public struct SegmentProgress: Equatable {
    public let current: Int
    public let total: Int

    public init(current: Int, total: Int) {
        self.current = current
        self.total = total
    }
}

// MARK: - Render Queue Delegate

/// Delegate protocol for render queue events
@MainActor
public protocol RenderQueueDelegate: AnyObject {
    /// Called when a render item starts processing
    func queueManager(_ manager: RenderQueueManager, didStartItem item: RenderQueueItem)

    /// Called when progress updates occur
    func queueManager(_ manager: RenderQueueManager, didUpdateProgress progress: RenderProgress)

    /// Called when a render item completes (success or failure)
    func queueManager(_ manager: RenderQueueManager, didCompleteItem result: RenderResult)

    /// Called when the entire queue finishes processing
    func queueManager(_ manager: RenderQueueManager, didFinishQueue totalCompleted: Int, totalFailed: Int)

    /// Called when an error occurs
    func queueManager(_ manager: RenderQueueManager, didEncounterError error: Error, ocfFileName: String)
}

// MARK: - Render Queue Manager

/// Manages sequential processing of render queue items
@MainActor
public class RenderQueueManager: ObservableObject, RenderProgressDelegate {

    // MARK: - Properties

    public weak var delegate: RenderQueueDelegate?

    /// Current queue of items to process
    @Published public private(set) var queue: [RenderQueueItem] = []

    /// Whether the queue is currently processing
    @Published public private(set) var isProcessing: Bool = false

    /// Current item being processed
    @Published public private(set) var currentItem: RenderQueueItem?

    /// Total items completed successfully
    @Published public private(set) var completedCount: Int = 0

    /// Total items that failed
    @Published public private(set) var failedCount: Int = 0

    /// Last completed result (for UI observation)
    @Published public private(set) var lastCompletedResult: RenderResult?

    /// Total items at the start of processing (remains constant during the batch)
    @Published public private(set) var initialTotalItems: Int = 0

    /// Current segment progress (separate published property for real-time UI updates)
    @Published public private(set) var currentSegmentProgress: SegmentProgress? = nil

    /// Total frames across all items in queue (for frame-based progress)
    @Published public private(set) var totalFramesInQueue: Int64 = 0

    /// Cumulative frames completed so far (for frame-based progress)
    @Published public private(set) var cumulativeCompletedFrames: Int64 = 0

    /// Frames processed within current item (for incremental progress bar)
    @Published public private(set) var currentItemFramesProcessed: Int64 = 0

    /// Task handle for the current processing loop
    private var processingTask: Task<Void, Never>?

    /// Maximum time to wait for a single render (in seconds)
    public var timeoutPerItem: TimeInterval = 300 // 5 minutes

    /// Render service for performing actual rendering work
    private var renderService: RenderService?

    /// Configuration for rendering
    private var renderConfiguration: RenderConfiguration?

    // MARK: - Initialization

    public init() {}

    /// Configure with render service
    public func configure(with configuration: RenderConfiguration) {
        self.renderConfiguration = configuration
        let service = RenderService(configuration: configuration)
        service.delegate = self
        self.renderService = service
    }

    // MARK: - Public API

    /// Add items to the queue
    public func addToQueue(_ parents: [OCFParent]) {
        let newItems = parents.map { parent in
            RenderQueueItem(
                ocfFileName: parent.ocf.fileName,
                ocfParent: parent,
                status: .pending,
                progress: "Waiting in queue..."
            )
        }

        queue.append(contentsOf: newItems)

        NSLog("📋 Added \(newItems.count) items to render queue (total: \(queue.count))")
    }

    /// Start processing the queue
    public func startProcessing() {
        guard !isProcessing else {
            NSLog("⚠️ Queue is already processing")
            return
        }

        guard !queue.isEmpty else {
            NSLog("⚠️ Queue is empty - nothing to process")
            return
        }

        NSLog("🚀 Starting render queue processing (\(queue.count) items)")

        isProcessing = true
        completedCount = 0
        failedCount = 0
        initialTotalItems = queue.count

        // Calculate total frames for frame-based progress
        cumulativeCompletedFrames = 0
        totalFramesInQueue = queue.reduce(0) { total, item in
            if let frames = item.ocfParent.ocf.durationInFrames {
                return total + frames
            }
            return total
        }

        if totalFramesInQueue > 0 {
            NSLog("📊 Total frames to process: \(totalFramesInQueue)")
        } else {
            NSLog("⚠️ No frame count data available, using item-based progress")
        }

        // Start processing loop
        processingTask = Task { @MainActor in
            await processQueue()
        }
    }

    /// Stop processing the queue
    public func stopProcessing() {
        guard isProcessing else { return }

        NSLog("⏸️ Stopping render queue processing")

        processingTask?.cancel()
        processingTask = nil
        isProcessing = false
        currentItem = nil
    }

    /// Clear the queue (removes all pending items)
    public func clearQueue() {
        NSLog("🗑️ Clearing render queue (\(queue.count) items removed)")
        queue.removeAll()

        if !isProcessing {
            completedCount = 0
            failedCount = 0
            initialTotalItems = 0
        }
    }

    /// Get current queue status
    public func getStatus() -> RenderQueueStatus {
        return RenderQueueStatus(
            totalItems: queue.count + completedCount + failedCount,
            completedItems: completedCount,
            failedItems: failedCount,
            isProcessing: isProcessing,
            currentItem: currentItem
        )
    }

    // MARK: - Internal Processing

    /// Process the queue sequentially
    private func processQueue() async {
        while !queue.isEmpty && !Task.isCancelled {
            // Get next item
            var item = queue.removeFirst()
            currentItem = item

            // Reset progress tracking for new item
            currentSegmentProgress = nil
            currentItemFramesProcessed = 0

            // Update status to generatingBlankRush
            item.status = .generatingBlankRush
            item.startTime = Date()
            currentItem = item

            NSLog("📤 Processing: \(item.ocfFileName) (\(queue.count) remaining)")

            // Notify delegate
            delegate?.queueManager(self, didStartItem: item)

            // Wait for render to complete (with timeout)
            let result = await waitForRenderCompletion(item: item)

            // Update counters and publish result
            if result.success {
                completedCount += 1
            } else {
                failedCount += 1
            }

            // Publish result for UI observation
            lastCompletedResult = result

            // Notify delegate of completion
            delegate?.queueManager(self, didCompleteItem: result)

            // Small delay between items
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        }

        // Queue finished
        NSLog("✅ Render queue completed! Success: \(completedCount), Failed: \(failedCount)")

        isProcessing = false
        currentItem = nil

        delegate?.queueManager(self, didFinishQueue: completedCount, totalFailed: failedCount)
    }

    /// Wait for a render to complete (with timeout)
    private func waitForRenderCompletion(item: RenderQueueItem) async -> RenderResult {
        guard let service = renderService else {
            NSLog("❌ RenderService not configured!")
            return RenderResult(
                ocfFileName: item.ocfFileName,
                success: false,
                error: "RenderService not configured",
                duration: 0,
                segmentCount: item.ocfParent.children.count
            )
        }

        // Actually perform the rendering using RenderService
        let result = await service.renderOCF(parent: item.ocfParent)

        // Update current item status based on result
        if result.success {
            updateCurrentItemStatus(.completed, progress: "Render completed")
        } else {
            updateCurrentItemStatus(.failed, progress: result.error ?? "Unknown error")
        }

        // Update cumulative frame count (whether success or failure)
        if let frames = item.ocfParent.ocf.durationInFrames {
            cumulativeCompletedFrames += frames
            NSLog("📊 Completed frames: \(cumulativeCompletedFrames)/\(totalFramesInQueue)")
        }

        return result
    }

    // MARK: - Status Updates (Called by Render Service)

    /// Update current item status (called by render service)
    public func updateCurrentItemStatus(_ status: RenderStatus, progress: String) {
        guard var item = currentItem else { return }

        item.status = status
        item.progress = progress
        currentItem = item

        // Notify delegate of progress
        let progressUpdate = RenderProgress(
            ocfFileName: item.ocfFileName,
            status: status,
            message: progress,
            percentage: nil,
            elapsedTime: item.duration
        )

        delegate?.queueManager(self, didUpdateProgress: progressUpdate)
    }

    /// Mark current item as completed (called by render service)
    public func markCurrentItemCompleted(outputURL: URL) {
        guard var item = currentItem else { return }

        item.status = .completed
        item.completionTime = Date()
        currentItem = item

        NSLog("✅ Completed: \(item.ocfFileName)")
    }

    /// Mark current item as failed (called by render service)
    public func markCurrentItemFailed(error: String) {
        guard var item = currentItem else { return }

        item.status = .failed
        item.progress = error
        item.completionTime = Date()
        currentItem = item

        NSLog("❌ Failed: \(item.ocfFileName) - \(error)")
    }

    // MARK: - RenderProgressDelegate

    /// Handle progress updates from RenderService
    public func renderService(_ service: RenderService, didUpdateProgress progress: RenderProgress) {
        // Update current item with progress details and segment data
        if var item = currentItem {
            item.progress = progress.message
            item.currentSegment = progress.currentSegment
            item.totalSegments = progress.totalSegments
            currentItem = item
        }

        // Update current item frame progress for incremental progress bar
        if let framesProcessed = progress.currentItemFramesProcessed {
            currentItemFramesProcessed = framesProcessed
        }

        // Publish segment progress separately for real-time UI updates
        if let currentSeg = progress.currentSegment, let totalSeg = progress.totalSegments {
            currentSegmentProgress = SegmentProgress(current: currentSeg, total: totalSeg)
        }

        updateCurrentItemStatus(progress.status, progress: progress.message)

        // Forward segment-level progress to delegate
        delegate?.queueManager(self, didUpdateProgress: progress)
    }
}
