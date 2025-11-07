import Foundation

// MARK: - Render Status

/// Status of a render operation
public enum RenderStatus: String, Codable, Equatable {
    case pending = "pending"
    case generatingBlankRush = "generating_blank_rush"
    case compositing = "compositing"
    case completed = "completed"
    case failed = "failed"

    public var isInProgress: Bool {
        self == .generatingBlankRush || self == .compositing
    }

    public var isFinished: Bool {
        self == .completed || self == .failed
    }
}

// MARK: - Render Queue Item

/// Represents a single item in the render queue
public struct RenderQueueItem: Identifiable, Equatable {
    public let id: UUID
    public let ocfFileName: String
    public let ocfParent: OCFParent
    public var status: RenderStatus
    public var progress: String
    public var startTime: Date?
    public var completionTime: Date?

    // Segment-level progress for linear progress bars
    public var currentSegment: Int?
    public var totalSegments: Int?

    public init(
        id: UUID = UUID(),
        ocfFileName: String,
        ocfParent: OCFParent,
        status: RenderStatus = .pending,
        progress: String = "",
        startTime: Date? = nil,
        completionTime: Date? = nil,
        currentSegment: Int? = nil,
        totalSegments: Int? = nil
    ) {
        self.id = id
        self.ocfFileName = ocfFileName
        self.ocfParent = ocfParent
        self.status = status
        self.progress = progress
        self.startTime = startTime
        self.completionTime = completionTime
        self.currentSegment = currentSegment
        self.totalSegments = totalSegments
    }

    public var duration: TimeInterval? {
        guard let start = startTime else { return nil }
        let end = completionTime ?? Date()
        return end.timeIntervalSince(start)
    }

    public static func == (lhs: RenderQueueItem, rhs: RenderQueueItem) -> Bool {
        lhs.id == rhs.id &&
        lhs.ocfFileName == rhs.ocfFileName &&
        lhs.status == rhs.status
    }
}

// MARK: - Render Progress

/// Progress update for a render operation
public struct RenderProgress: Equatable {
    public let ocfFileName: String
    public let status: RenderStatus
    public let message: String
    public let percentage: Double?
    public let elapsedTime: TimeInterval?

    // Segment-level progress (for detailed tracking)
    public let currentSegment: Int?
    public let totalSegments: Int?
    public let segmentName: String?

    public init(
        ocfFileName: String,
        status: RenderStatus,
        message: String,
        percentage: Double? = nil,
        elapsedTime: TimeInterval? = nil,
        currentSegment: Int? = nil,
        totalSegments: Int? = nil,
        segmentName: String? = nil
    ) {
        self.ocfFileName = ocfFileName
        self.status = status
        self.message = message
        self.percentage = percentage
        self.elapsedTime = elapsedTime
        self.currentSegment = currentSegment
        self.totalSegments = totalSegments
        self.segmentName = segmentName
    }
}

// MARK: - Render Result

/// Result of a render operation
public struct RenderResult: Equatable {
    public let ocfFileName: String
    public let success: Bool
    public let outputURL: URL?
    public let error: String?
    public let duration: TimeInterval
    public let segmentCount: Int
    public let blankRushURL: URL?

    public init(
        ocfFileName: String,
        success: Bool,
        outputURL: URL? = nil,
        error: String? = nil,
        duration: TimeInterval,
        segmentCount: Int,
        blankRushURL: URL? = nil
    ) {
        self.ocfFileName = ocfFileName
        self.success = success
        self.outputURL = outputURL
        self.error = error
        self.duration = duration
        self.segmentCount = segmentCount
        self.blankRushURL = blankRushURL
    }

    public static func == (lhs: RenderResult, rhs: RenderResult) -> Bool {
        lhs.ocfFileName == rhs.ocfFileName &&
        lhs.success == rhs.success &&
        lhs.outputURL == rhs.outputURL &&
        lhs.error == rhs.error
    }
}

// MARK: - Render Configuration

/// Configuration for a render operation
public struct RenderConfiguration: Equatable {
    public let blankRushDirectory: URL
    public let outputDirectory: URL
    public let proResProfile: String

    public init(
        blankRushDirectory: URL,
        outputDirectory: URL,
        proResProfile: String = "4"
    ) {
        self.blankRushDirectory = blankRushDirectory
        self.outputDirectory = outputDirectory
        self.proResProfile = proResProfile
    }
}

// MARK: - Render Queue Status

/// Overall status of the render queue
public struct RenderQueueStatus: Equatable {
    public let totalItems: Int
    public let completedItems: Int
    public let failedItems: Int
    public let isProcessing: Bool
    public let currentItem: RenderQueueItem?

    public init(
        totalItems: Int,
        completedItems: Int,
        failedItems: Int,
        isProcessing: Bool,
        currentItem: RenderQueueItem? = nil
    ) {
        self.totalItems = totalItems
        self.completedItems = completedItems
        self.failedItems = failedItems
        self.isProcessing = isProcessing
        self.currentItem = currentItem
    }

    public var remainingItems: Int {
        totalItems - completedItems - failedItems
    }

    public var successfulItems: Int {
        completedItems - failedItems
    }

    public var progressPercentage: Double {
        guard totalItems > 0 else { return 0 }
        return Double(completedItems + failedItems) / Double(totalItems)
    }
}
