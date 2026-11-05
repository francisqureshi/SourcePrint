# SourcePrint Refactoring Plan

**Project:** SourcePrint Architecture Refactoring
**Goal:** Move business logic from UI layer to SourcePrintCore
**Date:** 2025-10-28

This document provides a detailed, phased implementation plan for refactoring SourcePrint to achieve complete separation of business logic from the UI layer.

---

## Table of Contents

1. [Refactoring Phases Overview](#refactoring-phases-overview)
2. [Phase 1: File System Utilities](#phase-1-file-system-utilities)
3. [Phase 2: Watch Folder Service](#phase-2-watch-folder-service)
4. [Phase 3: Render Queue Manager](#phase-3-render-queue-manager)
5. [Phase 4: Project Model Refactoring](#phase-4-project-model-refactoring)
6. [Testing Strategy](#testing-strategy)
7. [Risk Mitigation](#risk-mitigation)
8. [Success Criteria](#success-criteria)

---

## Refactoring Phases Overview

The refactoring follows a **progressive risk-managed approach**:

| Phase | Duration | Risk Level | Value | Complexity |
|-------|----------|------------|-------|------------|
| Phase 1: File System Utilities | 1-2 weeks | **Low** | High | Low |
| Phase 2: Watch Folder Service | 2-3 weeks | **Medium** | High | Medium |
| Phase 3: Render Queue Manager | 3-4 weeks | **High** | Very High | High |
| Phase 4: Project Model Refactoring | 4-6 weeks | **Very High** | Critical | Very High |

**Total Timeline:** 10-15 weeks for complete refactoring

**Strategy:**
- Start with low-risk, high-value extractions
- Validate each phase with integration tests before proceeding
- Maintain backward compatibility during migration
- Enable feature flags for gradual rollout

---

## Phase 1: File System Utilities

**Duration:** 1-2 weeks
**Risk:** Low
**Priority:** High (foundational for other phases)

### Objectives

Extract all file system operations from UI layer into testable core utilities:
- File modification date retrieval
- File size calculation
- Partial hash calculation (SHA256 for large files)
- Video file discovery (recursive directory traversal)

### Target Files

**Creating in Core:**
- `SourcePrintCore/Utilities/FileSystemOperations.swift`
- `SourcePrintCore/Utilities/VideoFileDiscovery.swift`

**Refactoring in UI:**
- `Project.swift` (lines 432-494)
- `MediaImportTab.swift` (lines 183-211)

### Step-by-Step Implementation

#### Step 1.1: Create FileSystemOperations Utility (2 days)

**New File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Utilities/FileSystemOperations.swift`

```swift
import Foundation
import CryptoKit

/// File system utilities for media file operations
/// Pure functions with no UI dependencies
public class FileSystemOperations {

    // MARK: - File Metadata

    /// Get file modification date from file system
    /// - Parameter url: File URL to query
    /// - Returns: Modification date or nil if unavailable
    public static func getModificationDate(for url: URL) -> Result<Date, FileSystemError> {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = resourceValues.contentModificationDate else {
                return .failure(.metadataUnavailable(url: url, key: "contentModificationDate"))
            }
            return .success(date)
        } catch {
            return .failure(.accessError(url: url, underlyingError: error))
        }
    }

    /// Get file size in bytes
    /// - Parameter url: File URL to query
    /// - Returns: File size in bytes or error
    public static func getFileSize(for url: URL) -> Result<Int64, FileSystemError> {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let size = resourceValues.fileSize else {
                return .failure(.metadataUnavailable(url: url, key: "fileSize"))
            }
            return .success(Int64(size))
        } catch {
            return .failure(.accessError(url: url, underlyingError: error))
        }
    }

    // MARK: - Hash Calculation

    /// Calculate partial hash (first 1MB + last 1MB) for large file comparison
    /// This strategy provides fast comparison while maintaining uniqueness
    ///
    /// - Parameter url: File URL to hash
    /// - Returns: SHA256 hash string (hex format) or error
    public static func calculatePartialHash(for url: URL) -> Result<String, FileSystemError> {
        guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
            return .failure(.accessError(url: url, underlyingError: nil))
        }
        defer { try? fileHandle.close() }

        do {
            let chunkSize = 1024 * 1024  // 1MB
            var hasher = SHA256()

            // Get file size
            let fileSize = try fileHandle.seekToEnd()
            try fileHandle.seek(toOffset: 0)

            // Hash first chunk (or entire file if smaller)
            let firstChunkSize = min(UInt64(chunkSize), fileSize)
            if let firstData = try? fileHandle.read(upToCount: Int(firstChunkSize)) {
                hasher.update(data: firstData)
            } else {
                return .failure(.hashError(url: url, reason: "Failed to read first chunk"))
            }

            // Hash last chunk if file is large enough
            if fileSize > UInt64(chunkSize * 2) {
                try fileHandle.seek(toOffset: fileSize - UInt64(chunkSize))
                if let lastData = try? fileHandle.read(upToCount: chunkSize) {
                    hasher.update(data: lastData)
                } else {
                    return .failure(.hashError(url: url, reason: "Failed to read last chunk"))
                }
            }

            let digest = hasher.finalize()
            let hashString = digest.map { String(format: "%02x", $0) }.joined()
            return .success(hashString)
        } catch {
            return .failure(.hashError(url: url, reason: error.localizedDescription))
        }
    }

    // MARK: - File Validation

    /// Check if file exists at given URL
    public static func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Check if path is a directory
    public static func isDirectory(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return isDirectory.boolValue
    }
}

// MARK: - Error Types

public enum FileSystemError: Error, LocalizedError {
    case accessError(url: URL, underlyingError: Error?)
    case metadataUnavailable(url: URL, key: String)
    case hashError(url: URL, reason: String)

    public var errorDescription: String? {
        switch self {
        case .accessError(let url, let error):
            return "Cannot access file: \(url.lastPathComponent). \(error?.localizedDescription ?? "")"
        case .metadataUnavailable(let url, let key):
            return "Metadata '\(key)' unavailable for: \(url.lastPathComponent)"
        case .hashError(let url, let reason):
            return "Hash calculation failed for \(url.lastPathComponent): \(reason)"
        }
    }
}
```

**Testing:**
```swift
// SourcePrintCore/Tests/SourcePrintCoreTests/FileSystemOperationsTests.swift
import XCTest
@testable import SourcePrintCore

final class FileSystemOperationsTests: XCTestCase {

    func testGetModificationDate() throws {
        let testFile = createTemporaryFile(content: "test")
        defer { try? FileManager.default.removeItem(at: testFile) }

        let result = FileSystemOperations.getModificationDate(for: testFile)

        switch result {
        case .success(let date):
            XCTAssertLessThanOrEqual(date.timeIntervalSinceNow, 1.0, "Mod date should be recent")
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }
    }

    func testCalculatePartialHash() throws {
        let testFile = createLargeFile(sizeMB: 10)
        defer { try? FileManager.default.removeItem(at: testFile) }

        let result = FileSystemOperations.calculatePartialHash(for: testFile)

        switch result {
        case .success(let hash):
            XCTAssertEqual(hash.count, 64, "SHA256 hash should be 64 hex characters")
        case .failure(let error):
            XCTFail("Expected success, got error: \(error)")
        }
    }

    // Helper to create test files...
}
```

---

#### Step 1.2: Create VideoFileDiscovery Utility (1 day)

**New File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Utilities/VideoFileDiscovery.swift`

```swift
import Foundation

/// Video file discovery utility for recursive directory traversal
public class VideoFileDiscovery {

    // Supported video file extensions
    public static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "avi", "mkv"]

    /// Recursively discover all video files in a directory
    ///
    /// - Parameters:
    ///   - directoryURL: Root directory to scan
    ///   - skipHidden: Whether to skip hidden files (default: true)
    /// - Returns: Sorted array of video file URLs
    public static func discoverVideoFiles(
        in directoryURL: URL,
        skipHidden: Bool = true
    ) async throws -> [URL] {
        var videoFiles: [URL] = []

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: skipHidden ? [.skipsHiddenFiles, .skipsPackageDescendants] : [.skipsPackageDescendants]
        ) else {
            throw VideoFileDiscoveryError.directoryNotAccessible(directoryURL)
        }

        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])

                // Only process regular files (not directories)
                if resourceValues.isRegularFile == true && isVideoFile(fileURL) {
                    videoFiles.append(fileURL)
                }
            } catch {
                // Log error but continue processing other files
                print("⚠️ Error checking file \(fileURL.lastPathComponent): \(error)")
            }
        }

        return videoFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Check if file extension indicates a video file
    ///
    /// - Parameter url: File URL to check
    /// - Returns: True if file has video extension
    public static func isVideoFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }

    /// Discover video files in multiple directories
    ///
    /// - Parameter directoryURLs: Array of directory URLs to scan
    /// - Returns: Combined sorted array of video file URLs
    public static func discoverVideoFiles(
        in directoryURLs: [URL],
        skipHidden: Bool = true
    ) async throws -> [URL] {
        var allVideoFiles: [URL] = []

        for directoryURL in directoryURLs {
            let files = try await discoverVideoFiles(in: directoryURL, skipHidden: skipHidden)
            allVideoFiles.append(contentsOf: files)
        }

        return allVideoFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Error Types

public enum VideoFileDiscoveryError: Error, LocalizedError {
    case directoryNotAccessible(URL)
    case noVideoFilesFound(URL)

    public var errorDescription: String? {
        switch self {
        case .directoryNotAccessible(let url):
            return "Cannot access directory: \(url.path)"
        case .noVideoFilesFound(let url):
            return "No video files found in: \(url.path)"
        }
    }
}
```

**Testing:**
```swift
// SourcePrintCore/Tests/SourcePrintCoreTests/VideoFileDiscoveryTests.swift
final class VideoFileDiscoveryTests: XCTestCase {

    func testDiscoverVideoFiles() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            "video2.mp4",
            "document.txt",
            "subfolder/video3.mov"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 3, "Should find 3 video files")
        XCTAssertTrue(videoFiles.allSatisfy { VideoFileDiscovery.isVideoFile($0) })
    }

    func testIsVideoFile() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.mov")))
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.MP4")))
        XCTAssertFalse(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.txt")))
    }
}
```

---

#### Step 1.3: Refactor UI Layer to Use Utilities (2-3 days)

**Update Project.swift:**

```swift
// Before (lines 432-453):
private func getFileModificationDate(for url: URL) -> Date? {
    do {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return resourceValues.contentModificationDate
    } catch {
        print("⚠️ Could not get modification date for \(url.lastPathComponent): \(error)")
        return nil
    }
}

// After:
private func getFileModificationDate(for url: URL) -> Date? {
    switch FileSystemOperations.getModificationDate(for: url) {
    case .success(let date):
        return date
    case .failure(let error):
        print("⚠️ \(error.localizedDescription)")
        return nil
    }
}
```

**Update MediaImportTab.swift:**

```swift
// Before (lines 183-211):
private func getAllVideoFiles(from directoryURL: URL) async -> [URL] {
    var videoFiles: [URL] = []
    let videoExtensions = ["mov", "mp4", "m4v", "mxf"]

    guard let enumerator = FileManager.default.enumerator(...) { ... }
    // ... 30 lines of traversal logic
}

// After:
private func getAllVideoFiles(from directoryURL: URL) async -> [URL] {
    do {
        return try await VideoFileDiscovery.discoverVideoFiles(in: directoryURL)
    } catch {
        print("⚠️ Failed to discover video files: \(error)")
        return []
    }
}
```

---

### Phase 1 Testing & Validation

**Unit Tests:**
- FileSystemOperations: Test all file operations with temporary files
- VideoFileDiscovery: Test recursive traversal with mock directory structures

**Integration Tests:**
- Verify UI still works with new utilities
- Test import workflow end-to-end
- Verify hash-based file comparison still works

**Success Criteria:**
- All unit tests pass
- UI functionality unchanged
- No performance regression
- Code coverage >80% for new utilities

---

## Phase 2: Watch Folder Service

**Duration:** 2-3 weeks
**Risk:** Medium
**Priority:** High

### Objectives

Extract complete watch folder business logic from `Project.swift` into a reusable service:
- File monitoring lifecycle management
- File change detection algorithm
- Automatic import triggering
- Offline file detection and tracking

### Target Files

**Creating in Core:**
- `SourcePrintCore/Workflows/WatchFolderService.swift`
- `SourcePrintCore/Workflows/FileChangeDetector.swift`
- `SourcePrintCore/Workflows/AutoImportService.swift`
- `SourcePrintCore/Models/FileChangeSet.swift`

**Refactoring in UI:**
- `Project.swift` (lines 517-999) - 480+ lines to extract

### Step-by-Step Implementation

#### Step 2.1: Design Protocol-Based Architecture (2 days)

**Key Design Decisions:**
- Use protocol-based callbacks instead of closures to avoid UI coupling
- Separate file change detection logic from UI updates
- Make import triggering explicit rather than automatic

**New File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Workflows/WatchFolderService.swift`

```swift
import Foundation

/// Protocol for watch folder event notifications
public protocol WatchFolderDelegate: AnyObject {
    func watchFolder(_ service: WatchFolderService, didDetectNewFiles files: [URL], isVFX: Bool)
    func watchFolder(_ service: WatchFolderService, didDetectDeletedFiles fileNames: [String], isVFX: Bool)
    func watchFolder(_ service: WatchFolderService, didDetectModifiedFiles fileNames: [String], isVFX: Bool)
    func watchFolder(_ service: WatchFolderService, didEncounterError error: WatchFolderError)
}

/// Watch folder service for monitoring video file changes
/// Wraps FileMonitorWatchFolder with business logic layer
public class WatchFolderService {

    // MARK: - Properties

    public weak var delegate: WatchFolderDelegate?

    private var fileMonitor: FileMonitorWatchFolder?
    private let gradePath: String?
    private let vfxPath: String?
    private var isMonitoring: Bool = false

    // MARK: - Initialization

    public init(gradePath: String?, vfxPath: String?) {
        self.gradePath = gradePath
        self.vfxPath = vfxPath
    }

    // MARK: - Public API

    /// Start monitoring watch folders
    public func startMonitoring() {
        guard !isMonitoring else {
            print("⚠️ Watch folder already monitoring")
            return
        }

        guard gradePath != nil || vfxPath != nil else {
            delegate?.watchFolder(self, didEncounterError: .noPathsConfigured)
            return
        }

        print("🚀 Starting watch folder monitoring...")
        if let gradePath = gradePath { print("📁 Grade folder: \(gradePath)") }
        if let vfxPath = vfxPath { print("🎬 VFX folder: \(vfxPath)") }

        fileMonitor = FileMonitorWatchFolder()

        // Set up callbacks
        fileMonitor?.onVideoFilesDetected = { [weak self] videoFiles, isVFX in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.watchFolder(self, didDetectNewFiles: videoFiles, isVFX: isVFX)
            }
        }

        fileMonitor?.onVideoFilesDeleted = { [weak self] fileNames, isVFX in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.watchFolder(self, didDetectDeletedFiles: fileNames, isVFX: isVFX)
            }
        }

        fileMonitor?.onVideoFilesModified = { [weak self] fileNames, isVFX in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.delegate?.watchFolder(self, didDetectModifiedFiles: fileNames, isVFX: isVFX)
            }
        }

        fileMonitor?.startWatching(gradePath: gradePath, vfxPath: vfxPath)
        isMonitoring = true
    }

    /// Stop monitoring watch folders
    public func stopMonitoring() {
        print("🛑 Stopping watch folder monitoring")
        fileMonitor?.stopWatching()
        fileMonitor = nil
        isMonitoring = false
    }

    /// Detect changes that occurred while app was not monitoring
    /// Useful to call on app startup
    ///
    /// - Parameters:
    ///   - knownSegments: Segments already imported
    ///   - trackedSizes: Previously recorded file sizes
    /// - Returns: Set of detected changes
    public func detectChangesOnStartup(
        knownSegments: [MediaFileInfo],
        trackedSizes: [String: Int64]
    ) -> FileChangeSet {
        print("🔍 Checking for file changes that occurred while app was closed...")

        var modifiedFiles: [String] = []
        var deletedFiles: [String] = []
        var sizeChanges: [String: (old: Int64, new: Int64)] = [:]

        for segment in knownSegments {
            let fileName = segment.fileName
            let fileURL = segment.url

            // Check if this segment is in a watch folder
            let isInWatchFolder = isFileInWatchFolder(fileURL)
            guard isInWatchFolder else { continue }

            // Check if file still exists
            if FileSystemOperations.fileExists(at: fileURL) {
                // File exists - check if size changed
                if let storedSize = trackedSizes[fileName] {
                    switch FileSystemOperations.getFileSize(for: fileURL) {
                    case .success(let currentSize):
                        if currentSize != storedSize {
                            modifiedFiles.append(fileName)
                            sizeChanges[fileName] = (old: storedSize, new: currentSize)
                            print("⚠️ File changed while app was closed: \(fileName) (old: \(storedSize), new: \(currentSize) bytes)")
                        }
                    case .failure:
                        continue
                    }
                }
            } else {
                // File was deleted while app was closed
                deletedFiles.append(fileName)
                print("⚠️ File deleted while app was closed: \(fileName)")
            }
        }

        let changeCount = modifiedFiles.count + deletedFiles.count
        if changeCount > 0 {
            print("✅ Found \(changeCount) file(s) that changed while app was closed")
        } else {
            print("✅ No changes detected in watch folders")
        }

        return FileChangeSet(
            modifiedFiles: modifiedFiles,
            deletedFiles: deletedFiles,
            sizeChanges: sizeChanges
        )
    }

    // MARK: - Private Helpers

    private func isFileInWatchFolder(_ url: URL) -> Bool {
        let path = url.path
        if let gradePath = gradePath, path.hasPrefix(gradePath) {
            return true
        }
        if let vfxPath = vfxPath, path.hasPrefix(vfxPath) {
            return true
        }
        return false
    }
}

// MARK: - Error Types

public enum WatchFolderError: Error, LocalizedError {
    case noPathsConfigured
    case monitoringFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noPathsConfigured:
            return "No watch folder paths configured"
        case .monitoringFailed(let reason):
            return "Watch folder monitoring failed: \(reason)"
        }
    }
}
```

---

#### Step 2.2: Create FileChangeDetector (2 days)

**New File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Workflows/FileChangeDetector.swift`

```swift
import Foundation

/// Classifies detected files into categories based on their relationship to known files
public class FileChangeDetector {

    /// Classify detected video files into new, returning, or changed categories
    ///
    /// - Parameters:
    ///   - detectedFiles: Files detected by watch folder
    ///   - existingSegments: Segments already imported in project
    ///   - offlineFiles: Set of files marked as offline
    ///   - offlineMetadata: Metadata for offline files (size, hash)
    ///   - trackedSizes: Current file sizes for online segments
    /// - Returns: Classification of all detected files
    public static func classifyFiles(
        detectedFiles: [URL],
        existingSegments: [MediaFileInfo],
        offlineFiles: Set<String>,
        offlineMetadata: [String: OfflineFileMetadata],
        trackedSizes: [String: Int64]
    ) -> FileClassification {

        let existingFileNames = Set(existingSegments.map { $0.fileName })

        var newFiles: [URL] = []
        var returningUnchanged: [URL] = []
        var returningChanged: [URL] = []
        var existingModified: [URL] = []

        for url in detectedFiles {
            let fileName = url.lastPathComponent

            if offlineFiles.contains(fileName) {
                // File is returning from offline state
                let classification = classifyReturningFile(
                    url: url,
                    fileName: fileName,
                    metadata: offlineMetadata[fileName]
                )

                switch classification {
                case .unchanged:
                    returningUnchanged.append(url)
                case .changed:
                    returningChanged.append(url)
                }

            } else if existingFileNames.contains(fileName) {
                // File already exists and is online - check if changed
                if let storedSize = trackedSizes[fileName] {
                    switch FileSystemOperations.getFileSize(for: url) {
                    case .success(let currentSize):
                        if currentSize != storedSize {
                            existingModified.append(url)
                            print("⚠️ Online file changed: \(fileName) (old: \(storedSize), new: \(currentSize) bytes)")
                        }
                    case .failure:
                        // Can't determine size - ignore
                        break
                    }
                }
            } else {
                // Truly new file
                newFiles.append(url)
            }
        }

        return FileClassification(
            newFiles: newFiles,
            returningUnchanged: returningUnchanged,
            returningChanged: returningChanged,
            existingModified: existingModified
        )
    }

    /// Classify a returning offline file as unchanged or changed
    private static func classifyReturningFile(
        url: URL,
        fileName: String,
        metadata: OfflineFileMetadata?
    ) -> ReturningFileStatus {

        guard let metadata = metadata else {
            // No metadata - treat as changed
            print("🔄 Offline file returned (no metadata): \(fileName)")
            return .changed
        }

        // Try size comparison first (fastest)
        switch FileSystemOperations.getFileSize(for: url) {
        case .success(let currentSize):
            if currentSize == metadata.fileSize {
                // Same size - likely unchanged
                print("🔄 Offline file returned unchanged: \(fileName) (size: \(currentSize) bytes)")
                return .unchanged
            } else {
                print("⚠️ Offline file returned but size changed: \(fileName) (old: \(metadata.fileSize), new: \(currentSize) bytes)")
                return .changed
            }

        case .failure:
            // Can't get size - try hash fallback
            return classifyUsingHash(url: url, fileName: fileName, metadata: metadata)
        }
    }

    /// Use hash comparison as fallback when size comparison fails
    private static func classifyUsingHash(
        url: URL,
        fileName: String,
        metadata: OfflineFileMetadata
    ) -> ReturningFileStatus {

        guard let storedHash = metadata.partialHash else {
            print("🔐 No stored hash for \(fileName) - treating as changed")
            return .changed
        }

        switch FileSystemOperations.calculatePartialHash(for: url) {
        case .success(let currentHash):
            if currentHash == storedHash {
                print("🔄 Hash match - file unchanged: \(fileName)")
                return .unchanged
            } else {
                print("⚠️ Hash mismatch - file changed: \(fileName)")
                return .changed
            }

        case .failure:
            print("⚠️ Hash computation failed - treating as changed: \(fileName)")
            return .changed
        }
    }

    private enum ReturningFileStatus {
        case unchanged
        case changed
    }
}

// MARK: - Result Types

/// Classification of detected files
public struct FileClassification {
    public let newFiles: [URL]
    public let returningUnchanged: [URL]
    public let returningChanged: [URL]
    public let existingModified: [URL]

    public var hasChanges: Bool {
        !newFiles.isEmpty || !returningChanged.isEmpty || !existingModified.isEmpty
    }

    public var totalFiles: Int {
        newFiles.count + returningUnchanged.count + returningChanged.count + existingModified.count
    }
}

/// Set of detected file changes
public struct FileChangeSet {
    public let modifiedFiles: [String]
    public let deletedFiles: [String]
    public let sizeChanges: [String: (old: Int64, new: Int64)]

    public init(
        modifiedFiles: [String],
        deletedFiles: [String],
        sizeChanges: [String: (old: Int64, new: Int64)]
    ) {
        self.modifiedFiles = modifiedFiles
        self.deletedFiles = deletedFiles
        self.sizeChanges = sizeChanges
    }

    public var hasChanges: Bool {
        !modifiedFiles.isEmpty || !deletedFiles.isEmpty
    }
}

/// Metadata for offline files (moved from Project.swift)
public struct OfflineFileMetadata: Codable {
    public let fileName: String
    public let fileSize: Int64
    public let offlineDate: Date
    public let partialHash: String?  // Optional hash for fallback comparison

    public init(fileName: String, fileSize: Int64, offlineDate: Date, partialHash: String?) {
        self.fileName = fileName
        self.fileSize = fileSize
        self.offlineDate = offlineDate
        self.partialHash = partialHash
    }
}
```

---

#### Step 2.3: Create AutoImportService (3 days)

**Complexity:** This requires careful design to avoid circular dependencies with the UI layer.

*(Documentation continues with Phase 3 and 4 in similar detail...)*

---

**Due to length constraints, I'll summarize the remaining phases:**

## Phase 3: Render Queue Manager

**Key Components:**
- `RenderQueueManager.swift` - Queue state machine and orchestration
- `RenderService.swift` - Complete render workflow (blank rush + composition)
- `RenderWorkflowService.swift` - High-level render coordination

**Extracted From:**
- `LinkingResultsView.swift` (batch queue logic)
- `CompressorStyleOCFCard.swift` (render orchestration)

**Complexity:** High - Requires careful async coordination and state management

---

## Phase 4: Project Model Refactoring

**Key Components:**
- `ProjectModel.swift` - Pure data model (Codable, no business logic)
- `ProjectViewModel.swift` - SwiftUI reactive wrapper (@ObservableObject)
- `ProjectWorkflow.swift` - Import/Link/Render coordination

**Strategy:**
- Split Project.swift (1167 lines) into model + viewmodel
- Move all business operations to ProjectWorkflow
- Maintain SwiftUI reactivity through thin wrapper

**Complexity:** Very High - Requires careful state management refactoring

---

## Phase 5: Full ViewModel Split

**Duration:** 2-3 weeks
**Risk:** Very High
**Priority:** Medium (defer until other priorities addressed)

### Objectives

Complete the Model/ViewModel separation started in Phase 4D by creating a full SwiftUI-reactive wrapper around the Core ProjectModel:
- Create ProjectViewModel wrapper class in UI layer
- Update 20-30 view files to use ViewModel pattern
- Extensive UI testing to ensure reactivity maintained
- High risk due to deep SwiftUI coupling throughout views

### Key Components

**`ProjectViewModel.swift`** - SwiftUI reactive wrapper
- Wraps `ProjectModel` from SourcePrintCore
- Exposes `@Published private(set) var model: ProjectModel`
- Manages UI-specific state (renderQueue, ocfCardExpansionState, watchFolderSettings)
- Delegates all operations to Core services (ProjectOperations, AutoImportService, etc.)
- Implements WatchFolderDelegate and other UI protocols

### Strategy

1. **Create ViewModel Wrapper** (1 week)
   - ProjectViewModel class wrapping ProjectModel
   - Delegate all CRUD operations to Core services
   - Apply service results to wrapped model
   - Maintain UI-specific @Published properties

2. **Update View Files** (1-2 weeks)
   - Replace `@ObservedObject var project: Project` with `@ObservedObject var viewModel: ProjectViewModel`
   - Update property access from `project.name` to `viewModel.model.name`
   - Update method calls to go through viewModel
   - Files to update (~20-30 total):
     - ContentView.swift
     - LinkingResultsView.swift
     - MediaImportView.swift
     - OCFCard.swift, CompressorStyleOCFCard.swift
     - RenderQueueView.swift
     - OverviewView.swift
     - All other view files

3. **Testing & Validation** (3-5 days)
   - Manual testing of all UI functionality
   - Project save/load verification
   - Render queue workflow testing
   - Watch folder integration testing
   - Offline file tracking verification

### Complexity

Very High - Requires:
- Refactoring 20-30 view files with careful SwiftUI binding management
- Maintaining UI reactivity across all @Published properties
- Extensive manual testing (no UI unit tests currently)
- Risk of breaking SwiftUI state updates and bindings
- Potential performance impact from additional indirection

### Success Criteria

- ✅ ProjectViewModel successfully wraps ProjectModel from Core
- ✅ All views updated to use ViewModel pattern
- ✅ UI reactivity maintained (no SwiftUI update regressions)
- ✅ All functionality works (import, link, render, print, watch folder)
- ✅ Project save/load works correctly
- ✅ No performance degradation

### Notes

Phase 5 builds on Phase 4D foundation (ProjectModel already in Core). However, given the high risk and significant time investment required, this phase should be deferred until:
- Other high-priority features are completed
- Business case justifies the additional architectural purity
- Resources are available for extensive testing

**Alternative:** Keep current Project.swift architecture with thin service wrappers (achieved in Phases 4A-4C) and defer full ViewModel split indefinitely. The marginal benefit may not justify the complexity.

---

## Success Criteria

### Phase 1
- ✅ All file system operations testable without UI
- ✅ Zero business logic in UI for file operations
- ✅ <5% performance change

### Phase 2
- ✅ Watch folder service usable from CLI/daemon
- ✅ File change detection fully unit tested
- ✅ <480 lines removed from Project.swift

### Phase 3
- ✅ Render queue usable from CLI
- ✅ Complete render workflow tested without UI
- ✅ <600 lines removed from UI views

### Phase 4
- ✅ Project model has zero business logic
- ✅ All workflows in core library
- ✅ <2000 lines moved from UI to core

---

## Risk Mitigation

1. **Feature Flags:** Enable gradual rollout of each phase
2. **Parallel Implementation:** Keep old code until new code validated
3. **Integration Tests:** Comprehensive tests before removing old code
4. **Rollback Plan:** Git tags at each phase for easy rollback
5. **Code Review:** Architecture review after each phase

---

This refactoring plan provides a clear, actionable roadmap to achieve complete architectural separation while managing risk through phased implementation and validation.
