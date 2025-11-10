import Foundation

/// Cross-platform project file container (no SwiftUI dependencies)
/// This struct mirrors ProjectViewModel's structure but is pure Swift/Foundation
/// enabling Linux CLI tools to load and work with .w2 project files
///
/// The macOS app's ProjectViewModel wraps this container and adds @Published
/// properties for UI reactivity, but both encode/decode the same .w2 format.
public struct ProjectContainer: Codable {

    // MARK: - File Format Version

    /// File format version for future migrations
    /// Current version: 1
    public var fileFormatVersion: Int

    // MARK: - Core Data Model

    /// Core project data (100% cross-platform)
    public var model: ProjectModel

    // MARK: - UI State (Cross-Platform Compatible)

    /// Render queue items for batch processing
    /// Note: This is the Codable version for persistence
    /// At runtime, the app uses RuntimeRenderQueueItem which includes OCFParent references
    public var renderQueue: [RenderQueueItem]

    /// OCF card expansion state in UI
    public var ocfCardExpansionState: [String: Bool]

    /// Watch folder settings
    public var watchFolderSettings: WatchFolderSettings

    // MARK: - Initialization

    public init(
        fileFormatVersion: Int = 1,
        model: ProjectModel,
        renderQueue: [RenderQueueItem] = [],
        ocfCardExpansionState: [String: Bool] = [:],
        watchFolderSettings: WatchFolderSettings = WatchFolderSettings()
    ) {
        self.fileFormatVersion = fileFormatVersion
        self.model = model
        self.renderQueue = renderQueue
        self.ocfCardExpansionState = ocfCardExpansionState
        self.watchFolderSettings = watchFolderSettings
    }

    // MARK: - Codable Keys

    private enum CodingKeys: String, CodingKey {
        case fileFormatVersion
        case model
        case renderQueue
        case ocfCardExpansionState
        case watchFolderSettings
    }

    // MARK: - Codable Implementation (with backward compatibility)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // fileFormatVersion is optional for backward compatibility with old .w2 files
        // If missing, assume version 1 (the first versioned format)
        self.fileFormatVersion = try container.decodeIfPresent(Int.self, forKey: .fileFormatVersion) ?? 1

        self.model = try container.decode(ProjectModel.self, forKey: .model)
        self.renderQueue = try container.decode([RenderQueueItem].self, forKey: .renderQueue)
        self.ocfCardExpansionState = try container.decode([String: Bool].self, forKey: .ocfCardExpansionState)
        self.watchFolderSettings = try container.decode(WatchFolderSettings.self, forKey: .watchFolderSettings)
    }

    // MARK: - File I/O

    /// Load project container from .w2 file
    public static func load(from url: URL) throws -> ProjectContainer {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProjectContainer.self, from: data)
    }

    /// Save project container to .w2 file
    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted

        let data = try encoder.encode(self)

        // Atomic write: write to temp file first, then replace
        let tempDirectory = url.deletingLastPathComponent()
        let tempURL = tempDirectory.appendingPathComponent(".tmp_\(UUID().uuidString).w2")

        try data.write(to: tempURL, options: .atomic)

        // Replace the original file atomically
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: url)
        }
    }
}

// MARK: - RenderQueueItem (Codable Version)

/// Codable version of render queue item for persistence
/// This is separate from RuntimeRenderQueueItem which includes OCFParent references
public struct RenderQueueItem: Codable, Identifiable {
    public let id: UUID
    public let ocfFileName: String
    public let addedDate: Date
    public var status: PersistentRenderStatus

    public init(
        id: UUID = UUID(),
        ocfFileName: String,
        addedDate: Date = Date(),
        status: PersistentRenderStatus = .queued
    ) {
        self.id = id
        self.ocfFileName = ocfFileName
        self.addedDate = addedDate
        self.status = status
    }
}

/// Status of a render queue item (for persistence)
/// Note: This is different from RenderQueueStatus which is a struct for overall queue status
public enum PersistentRenderStatus: String, Codable, CaseIterable {
    case queued = "queued"
    case rendering = "rendering"
    case completed = "completed"
    case failed = "failed"
}
