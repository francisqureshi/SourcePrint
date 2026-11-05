import Foundation

/// Pure data model for a SourcePrint project (no SwiftUI dependencies)
public struct ProjectModel: Codable, Identifiable {

    // MARK: - Basic Project Info
    public let id: UUID
    public var name: String
    public var createdDate: Date
    public var lastModified: Date

    // MARK: - Core Data
    public var ocfFiles: [MediaFileInfo]
    public var segments: [MediaFileInfo]
    public var linkingResult: LinkingResult?

    // MARK: - Status Tracking
    public var blankRushStatus: [String: BlankRushStatus]
    public var segmentModificationDates: [String: Date]
    public var segmentFileSizes: [String: Int64]
    public var offlineMediaFiles: Set<String>
    public var offlineFileMetadata: [String: OfflineFileMetadata]
    public var lastPrintDate: Date?
    public var printHistory: [PrintRecord]
    public var printStatus: [String: PrintStatus]
    public var invalidatedRenderURLs: Set<URL> = []

    // MARK: - Manual Link Overrides
    /// Manual user overrides for low confidence matches
    /// Maps segment fileName -> OCF fileName
    public var manualLinkOverrides: [String: String]
    /// Standardized segment path -> standardized OCF path.
    public var manualLinkPaths: [String: String] = [:]
    public var preferredOCFFolder: URL?

    // MARK: - Project Settings
    public var publishDirectory: URL?
    public var publishHistory: [PublishRecord] = []
    public var outputDirectory: URL
    public var blankRushDirectory: URL
    public var fileURL: URL?

    // MARK: - Initialization

    public init(
        id: UUID = UUID(),
        name: String,
        createdDate: Date = Date(),
        lastModified: Date = Date(),
        ocfFiles: [MediaFileInfo] = [],
        segments: [MediaFileInfo] = [],
        linkingResult: LinkingResult? = nil,
        blankRushStatus: [String: BlankRushStatus] = [:],
        segmentModificationDates: [String: Date] = [:],
        segmentFileSizes: [String: Int64] = [:],
        offlineMediaFiles: Set<String> = [],
        offlineFileMetadata: [String: OfflineFileMetadata] = [:],
        lastPrintDate: Date? = nil,
        printHistory: [PrintRecord] = [],
        printStatus: [String: PrintStatus] = [:],
        manualLinkOverrides: [String: String] = [:],
        outputDirectory: URL,
        blankRushDirectory: URL,
        fileURL: URL? = nil
    ) {
        self.id = id
        self.name = name
        self.createdDate = createdDate
        self.lastModified = lastModified
        self.ocfFiles = ocfFiles
        self.segments = segments
        self.linkingResult = linkingResult
        self.blankRushStatus = blankRushStatus
        self.segmentModificationDates = segmentModificationDates
        self.segmentFileSizes = segmentFileSizes
        self.offlineMediaFiles = offlineMediaFiles
        self.offlineFileMetadata = offlineFileMetadata
        self.lastPrintDate = lastPrintDate
        self.printHistory = printHistory
        self.printStatus = printStatus
        self.manualLinkOverrides = manualLinkOverrides
        self.outputDirectory = outputDirectory
        self.blankRushDirectory = blankRushDirectory
        self.fileURL = fileURL
    }

    // MARK: - Computed Properties

    public var hasLinkedMedia: Bool {
        linkingResult?.totalLinkedSegments ?? 0 > 0
    }

    public var readyForBlankRush: Bool {
        linkingResult?.parentsWithChildren.isEmpty == false
    }

    public var blankRushProgress: (completed: Int, total: Int) {
        let total = linkingResult?.parentsWithChildren.count ?? 0
        let completed = blankRushStatus.values.compactMap {
            if case .completed = $0 { return 1 } else { return nil }
        }.count
        return (completed, total)
    }

    /// Check if any segments have been modified since tracked date
    public var hasModifiedSegments: Bool {
        guard let linkingResult = linkingResult else { return false }

        for parent in linkingResult.parentsWithChildren {
            for child in parent.children {
                let segmentFileName = child.segment.fileName

                // Get file modification date
                if case .success(let fileModDate) = FileSystemOperations.getModificationDate(for: child.segment.url),
                    let trackedModDate = segmentModificationDates[segmentFileName]
                {
                    // If file is newer than our tracked date, it's been modified
                    if fileModDate > trackedModDate {
                        return true
                    }
                }
            }
        }

        return false
    }

    /// Get list of modified segments with their details
    public var modifiedSegments: [(fileName: String, fileModDate: Date, trackedModDate: Date)] {
        guard let linkingResult = linkingResult else { return [] }

        var modified: [(String, Date, Date)] = []

        for parent in linkingResult.parentsWithChildren {
            for child in parent.children {
                let segmentFileName = child.segment.fileName

                if case .success(let fileModDate) = FileSystemOperations.getModificationDate(for: child.segment.url),
                    let trackedModDate = segmentModificationDates[segmentFileName]
                {
                    if fileModDate > trackedModDate {
                        modified.append((segmentFileName, fileModDate, trackedModDate))
                    }
                }
            }
        }

        return modified
    }

    // MARK: - Mutating Operations

    public mutating func updateModified() {
        lastModified = Date()
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case createdDate
        case lastModified
        case ocfFiles
        case segments
        case linkingResult
        case blankRushStatus
        case segmentModificationDates
        case segmentFileSizes
        case offlineMediaFiles
        case offlineFileMetadata
        case lastPrintDate
        case printHistory
        case printStatus
        case invalidatedRenderURLs
        case manualLinkOverrides
        case manualLinkPaths
        case preferredOCFFolder
        case publishDirectory
        case publishHistory
        case outputDirectory
        case blankRushDirectory
        case fileURL
    }

    // Custom decoder for backwards compatibility
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        ocfFiles = try container.decode([MediaFileInfo].self, forKey: .ocfFiles)
        segments = try container.decode([MediaFileInfo].self, forKey: .segments)
        linkingResult = try container.decodeIfPresent(LinkingResult.self, forKey: .linkingResult)
        // Old projects can cache the same render work more than once. Require a fresh link.
        if let result = linkingResult {
            let children = result.ocfParents.flatMap { $0.children.map { $0.segment } }
            if ProjectOperations.uniqueMediaFiles(children).count != children.count ||
                ProjectOperations.uniqueMediaFiles(result.ocfParents.map(\.ocf)).count != result.ocfParents.count {
                linkingResult = nil
            }
        }
        blankRushStatus = try container.decode([String: BlankRushStatus].self, forKey: .blankRushStatus)
        segmentModificationDates = try container.decode([String: Date].self, forKey: .segmentModificationDates)
        segmentFileSizes = try container.decode([String: Int64].self, forKey: .segmentFileSizes)
        offlineMediaFiles = try container.decode(Set<String>.self, forKey: .offlineMediaFiles)
        offlineFileMetadata = try container.decode([String: OfflineFileMetadata].self, forKey: .offlineFileMetadata)
        lastPrintDate = try container.decodeIfPresent(Date.self, forKey: .lastPrintDate)
        printHistory = try container.decode([PrintRecord].self, forKey: .printHistory)
        printStatus = try container.decode([String: PrintStatus].self, forKey: .printStatus)
        invalidatedRenderURLs = try container.decodeIfPresent(Set<URL>.self, forKey: .invalidatedRenderURLs) ?? []
        // Decode manual link overrides with default for old files
        manualLinkOverrides = try container.decodeIfPresent([String: String].self, forKey: .manualLinkOverrides) ?? [:]
        manualLinkPaths = try container.decodeIfPresent([String: String].self, forKey: .manualLinkPaths) ?? [:]
        preferredOCFFolder = try container.decodeIfPresent(URL.self, forKey: .preferredOCFFolder)
        // Migrate filename confirmations only when their identity is unambiguous.
        for (segmentName, ocfName) in manualLinkOverrides {
            let grades = segments.filter { $0.fileName == segmentName }
            let originals = ocfFiles.filter { $0.fileName == ocfName }
            if grades.count == 1, originals.count == 1 {
                let key = SegmentOCFLinker.fileKey(grades[0].url)
                if manualLinkPaths[key] == nil { manualLinkPaths[key] = SegmentOCFLinker.fileKey(originals[0].url) }
            }
        }
        if linkingResult != nil, !manualLinkOverrides.isEmpty || !manualLinkPaths.isEmpty {
            linkingResult = SegmentOCFLinker().linkSegments(segments, withOCFParents: ocfFiles, manualPathOverrides: manualLinkPaths)
        }
        publishDirectory = try container.decodeIfPresent(URL.self, forKey: .publishDirectory)
        publishHistory = try container.decodeIfPresent([PublishRecord].self, forKey: .publishHistory) ?? []
        outputDirectory = try container.decode(URL.self, forKey: .outputDirectory)
        blankRushDirectory = try container.decode(URL.self, forKey: .blankRushDirectory)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
    }
}

// MARK: - BlankRushStatus

public enum BlankRushStatus: Codable, Equatable {
    case notCreated
    case inProgress
    case completed(date: Date, url: URL)
    case failed(error: String)

    public var statusIcon: String {
        switch self {
        case .notCreated: return "⚫️"
        case .inProgress: return "🟡"
        case .completed: return "🟢"
        case .failed: return "🔴"
        }
    }

    public var description: String {
        switch self {
        case .notCreated: return "Not Created"
        case .inProgress: return "In Progress"
        case .completed(let date, _):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return "Completed \(formatter.string(from: date))"
        case .failed(let error): return "Failed: \(error)"
        }
    }
}

// MARK: - PrintRecord

public struct PrintRecord: Codable, Identifiable {
    public let batch: RenderBatch?
    public let errorMessage: String?
    public let cancelled: Bool?
    public let outputFingerprint: RenderOutputFingerprint?
    public let id: UUID
    public let date: Date
    public let ocfURL: URL?
    public let ocfFileName: String
    public let outputURL: URL
    public let segmentCount: Int
    public let duration: TimeInterval
    public let success: Bool

    public init(id: UUID = UUID(), date: Date, ocfFileName: String, ocfURL: URL? = nil, outputURL: URL, segmentCount: Int = 0, duration: TimeInterval, success: Bool = true, errorMessage: String? = nil, cancelled: Bool? = nil, outputFingerprint: RenderOutputFingerprint? = nil, batch: RenderBatch? = nil) {
        self.batch = batch
        self.errorMessage = errorMessage
        self.cancelled = cancelled
        self.outputFingerprint = outputFingerprint
        self.id = id
        self.date = date
        self.ocfURL = ocfURL
        self.ocfFileName = ocfFileName
        self.outputURL = outputURL
        self.segmentCount = segmentCount
        self.duration = duration
        self.success = success
    }
}

// MARK: - PrintStatus

public enum PrintStatus: Codable {
    case notPrinted
    case printed(date: Date, outputURL: URL)
    case needsReprint(lastPrintDate: Date, reason: ReprintReason)

    public var displayName: String {
        switch self {
        case .notPrinted:
            return "Not Printed"
        case .printed(let date, _):
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .none
            return "Printed \(formatter.string(from: date))"
        case .needsReprint(_, let reason):
            // For offline segments, show "Incomplete" instead of "Needs Re-print"
            if reason == .segmentOffline {
                return "Incomplete (\(reason.displayName))"
            } else {
                return "Needs Re-print (\(reason.displayName))"
            }
        }
    }

    public var statusIcon: String {
        switch self {
        case .notPrinted:
            return "⚫️"
        case .printed:
            return "🟢"
        case .needsReprint:
            return "🟡"
        }
    }

    public var isPrinted: Bool {
        if case .printed = self {
            return true
        }
        return false
    }

    public var needsReprint: Bool {
        if case .needsReprint = self {
            return true
        }
        return false
    }
}

// MARK: - ReprintReason

public enum ReprintReason: String, Codable {
    case segmentModified = "segment_modified"
    case segmentOffline = "segment_offline"
    case manualRequest = "manual_request"
    case previousFailed = "previous_failed"

    public var displayName: String {
        switch self {
        case .segmentModified: return "Segment Modified"
        case .segmentOffline: return "Missing Segment"
        case .manualRequest: return "Manual Request"
        case .previousFailed: return "Previous Failed"
        }
    }
}
