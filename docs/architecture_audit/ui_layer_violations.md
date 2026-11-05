# UI Layer Violations - Detailed Analysis

**Project:** SourcePrint Architecture Audit
**Date:** 2025-10-28

This document provides a comprehensive, file-by-file analysis of business logic found in the UI layer that violates architectural separation principles.

---

## Table of Contents

1. [Critical Violations](#critical-violations)
   - [Project.swift - 1000+ lines of business logic](#1-projectswift)
   - [LinkingResultsView.swift - Complete rendering implementation](#2-linkingresultsviewswift)
   - [CompressorStyleOCFCard.swift - Render orchestration in SwiftUI](#3-compressorstyleocfcardswift)
   - [ProjectManager.swift - Workflow coordination in UI](#4-projectmanagerswift)
2. [Medium Violations](#medium-violations)
   - [MediaImportTab.swift - Concurrent processing in view](#5-mediaimporttabswift)
   - [LinkingTab.swift - Processing plan generation in view](#6-linkingtabswift)
3. [Summary by Violation Type](#summary-by-violation-type)

---

## Critical Violations

### 1. Project.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Models/Project.swift`

**Total Lines:** 1,167 lines

**Violation Severity:** CRITICAL

**Why it belongs in core:** This is a data model marked with `@ObservableObject` for SwiftUI reactivity, but contains extensive business logic, file system operations, cryptographic hashing, watch folder integration, and media analysis orchestration. Should be a thin wrapper around a core model.

---

#### Violation 1.1: File System Operations

**Lines:** 432-453

**Code:**
```swift
// MARK: - File System Helpers

/// Get file modification date from file system
private func getFileModificationDate(for url: URL) -> Date? {
    do {
        let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
        return resourceValues.contentModificationDate
    } catch {
        print("⚠️ Could not get modification date for \(url.lastPathComponent): \(error)")
        return nil
    }
}

private func getFileSize(for url: URL) -> Int64? {
    do {
        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
        return resourceValues.fileSize.map { Int64($0) }
    } catch {
        print("⚠️ Could not get file size for \(url.lastPathComponent): \(error)")
        return nil
    }
}
```

**Why it's business logic:**
- File system operations are infrastructure concerns
- Should be in a `FileSystemOperations` utility in core
- UI models should receive this data, not fetch it

**Suggested refactoring:**
```swift
// SourcePrintCore/Utilities/FileSystemOperations.swift
public class FileSystemOperations {
    public static func getModificationDate(for url: URL) -> Date? { ... }
    public static func getFileSize(for url: URL) -> Int64? { ... }
    public static func calculatePartialHash(for url: URL) -> String? { ... }
}

// UI layer Project model just stores the data:
class Project: ObservableObject {
    @Published var segmentModificationDates: [String: Date]
    @Published var segmentFileSizes: [String: Int64]
    // No file system operations, just data storage
}
```

**Complexity:** Low - Pure utility functions, easy extraction

---

#### Violation 1.2: Cryptographic Hash Calculation

**Lines:** 455-494

**Code:**
```swift
/// Calculate partial hash (first 1MB + last 1MB) for file comparison
private func calculatePartialHash(for url: URL) -> String? {
    guard let fileHandle = try? FileHandle(forReadingFrom: url) else {
        NSLog("⚠️ Could not open file for hashing: %@", url.lastPathComponent)
        return nil
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
        }

        // Hash last chunk if file is large enough
        if fileSize > UInt64(chunkSize * 2) {
            try fileHandle.seek(toOffset: fileSize - UInt64(chunkSize))
            if let lastData = try? fileHandle.read(upToCount: chunkSize) {
                hasher.update(data: lastData)
            }
        }

        let digest = hasher.finalize()
        let hashString = digest.map { String(format: "%02x", $0) }.joined()
        return hashString
    } catch {
        NSLog("⚠️ Error calculating hash for %@: %@", url.lastPathComponent, error.localizedDescription)
        return nil
    }
}
```

**Why it's business logic:**
- Complex algorithm for file comparison and offline detection
- Uses CryptoKit for SHA256 hashing
- Implements specific business rule: hash first 1MB + last 1MB for performance
- Critical for detecting file changes and returns of offline media

**Suggested refactoring:**
```swift
// SourcePrintCore/Utilities/FileSystemOperations.swift
public class FileSystemOperations {
    /// Calculate partial hash for large file comparison
    /// Uses first 1MB + last 1MB strategy for performance
    public static func calculatePartialHash(for url: URL) -> String? {
        // Move implementation here with proper error handling
    }
}

// SourcePrintCore/Models/OfflineFileMetadata.swift
public struct OfflineFileMetadata: Codable {
    public let fileName: String
    public let fileSize: Int64
    public let offlineDate: Date
    public let partialHash: String?  // Optional hash for fallback comparison

    // Business rule: Use size comparison first, hash as fallback
    public func matchesFile(at url: URL, using fsOps: FileSystemOperations) -> FileMatchResult
}
```

**Complexity:** Low - Algorithm is self-contained, clear interface

---

#### Violation 1.3: Watch Folder Integration and File Monitoring

**Lines:** 517-667 (150+ lines)

**Code:**
```swift
// MARK: - Watch Folder Monitoring

private func updateWatchFolderMonitoring() {
    NSLog("🔄 Watch folder settings changed: enabled=%@", watchFolderSettings.isEnabled ? "true" : "false")

    if watchFolderSettings.isEnabled {
        startWatchFolderIfNeeded()
    } else {
        stopWatchFolder()
    }
}

private func startWatchFolderIfNeeded() {
    let gradePath = watchFolderSettings.primaryGradeFolder?.path
    let vfxPath = watchFolderSettings.vfxFolder?.path

    guard gradePath != nil || vfxPath != nil else {
        NSLog("⚠️ No watch folder paths specified")
        return
    }

    NSLog("🚀 Starting watch folder monitoring...")
    watchFolderService = FileMonitorWatchFolder()

    // Set up callback for when video files are detected
    watchFolderService?.onVideoFilesDetected = { [weak self] videoFiles, isVFX in
        DispatchQueue.main.async {
            self?.handleDetectedVideoFiles(videoFiles, isVFX: isVFX)
        }
    }

    // Set up callback for when video files are deleted
    watchFolderService?.onVideoFilesDeleted = { [weak self] fileNames, isVFX in
        DispatchQueue.main.async {
            self?.handleDeletedVideoFiles(fileNames, isVFX: isVFX)
        }
    }

    // Set up callback for when video files are modified
    watchFolderService?.onVideoFilesModified = { [weak self] fileNames, isVFX in
        DispatchQueue.main.async {
            self?.handleModifiedVideoFiles(fileNames, isVFX: isVFX)
        }
    }

    watchFolderService?.startWatching(gradePath: gradePath, vfxPath: vfxPath)

    // Check for files that changed while app was closed
    checkForChangedFilesOnStartup(gradePath: gradePath, vfxPath: vfxPath)
}

/// Check if any already-imported files in watch folders have changed while app was closed
private func checkForChangedFilesOnStartup(gradePath: String?, vfxPath: String?) {
    NSLog("🔍 Checking for file changes that occurred while app was closed...")

    var changedCount = 0

    for segment in segments {
        let fileName = segment.fileName
        let fileURL = segment.url

        // Check if this segment is in a watch folder
        var isInWatchFolder = false
        if let gradePath = gradePath, fileURL.path.hasPrefix(gradePath) {
            isInWatchFolder = true
        } else if let vfxPath = vfxPath, fileURL.path.hasPrefix(vfxPath) {
            isInWatchFolder = true
        }

        guard isInWatchFolder else { continue }

        // Check if file exists and compare size
        if let storedSize = segmentFileSizes[fileName],
            let currentSize = getFileSize(for: fileURL) {

            if currentSize != storedSize {
                // File size changed while app was closed
                NSLog("⚠️ File changed while app was closed: %@ (old: %lld, new: %lld bytes)",
                    fileName, storedSize, currentSize)

                // Update modification date and size
                segmentModificationDates[fileName] = Date()
                segmentFileSizes[fileName] = currentSize

                // Mark affected OCFs for re-print
                if let linkingResult = linkingResult {
                    for ocfParent in linkingResult.ocfParents {
                        for child in ocfParent.children {
                            if child.segment.fileName == fileName {
                                // Update print status...
                            }
                        }
                    }
                }

                changedCount += 1
            }
        } else if !FileManager.default.fileExists(atPath: fileURL.path) {
            // File was deleted while app was closed...
        }
    }
}
```

**Why it's business logic:**
- Watch folder lifecycle management (start/stop/callbacks)
- File change detection algorithm comparing sizes
- Business rule: detect changes that occurred while app was closed
- Automatic print status updates based on file changes
- Complex state management with print status and offline tracking

**Suggested refactoring:**
```swift
// SourcePrintCore/Workflows/WatchFolderService.swift
public protocol WatchFolderDelegate: AnyObject {
    func watchFolder(_ service: WatchFolderService, didDetectFiles files: [URL], isVFX: Bool)
    func watchFolder(_ service: WatchFolderService, didDetectDeletedFiles fileNames: [String], isVFX: Bool)
    func watchFolder(_ service: WatchFolderService, didDetectModifiedFiles fileNames: [String], isVFX: Bool)
}

public class WatchFolderService {
    public weak var delegate: WatchFolderDelegate?

    public func startMonitoring(gradePath: String?, vfxPath: String?)
    public func stopMonitoring()

    // Business logic for startup change detection
    public func detectChangesOnStartup(
        knownSegments: [MediaFileInfo],
        trackedSizes: [String: Int64]
    ) -> FileChangeSet
}

// SourcePrintCore/Models/FileChangeSet.swift
public struct FileChangeSet {
    public let modifiedFiles: [String]
    public let deletedFiles: [String]
    public let sizeChanges: [String: (old: Int64, new: Int64)]
}

// UI layer becomes thin observer:
class ProjectViewModel: ObservableObject {
    private let watchFolderService: WatchFolderService

    init(project: ProjectModel, watchFolderService: WatchFolderService) {
        self.watchFolderService = watchFolderService
        watchFolderService.delegate = self
    }
}

extension ProjectViewModel: WatchFolderDelegate {
    func watchFolder(_ service: WatchFolderService, didDetectFiles files: [URL], isVFX: Bool) {
        // Just update UI state, business logic in service
        detectingFiles = files
    }
}
```

**Complexity:** Medium - Requires careful callback redesign to avoid UI coupling

---

#### Violation 1.4: Video File Detection and Automatic Import

**Lines:** 669-842 (170+ lines)

**Code:**
```swift
/// Handle video files detected by the watch folder service
private func handleDetectedVideoFiles(_ videoFiles: [URL], isVFX: Bool) {
    guard watchFolderSettings.autoImportEnabled else {
        NSLog("⚠️ Auto-import disabled, ignoring detected files")
        return
    }

    // Check for returning offline files first
    var returningOfflineFiles: [URL] = []
    var changedOfflineFiles: [URL] = []
    var newVideoFiles: [URL] = []

    let existingFileNames = Set(segments.map { $0.fileName })

    for url in videoFiles {
        let fileName = url.lastPathComponent

        // Check if this is a returning offline file
        if offlineMediaFiles.contains(fileName) {
            if let metadata = offlineFileMetadata[fileName],
                let currentSize = getFileSize(for: url) {

                if currentSize == metadata.fileSize {
                    // Same size - treat as same file returning
                    returningOfflineFiles.append(url)
                    NSLog("🔄 Offline file returned unchanged: %@ (size: %lld bytes)", fileName, currentSize)
                } else {
                    // Different size - file has changed
                    changedOfflineFiles.append(url)
                    NSLog("⚠️ Offline file returned but CHANGED: %@ (old: %lld, new: %lld bytes)",
                        fileName, metadata.fileSize, currentSize)
                }
            } else if let currentSize = getFileSize(for: url) {
                // No metadata - use hash fallback
                NSLog("🔐 No metadata for %@ - computing hash for comparison", fileName)

                if let currentHash = calculatePartialHash(for: url) {
                    // Check if we have a stored hash to compare
                    if let metadata = offlineFileMetadata[fileName],
                        let storedHash = metadata.partialHash {
                        if currentHash == storedHash {
                            // Hash matches - same file
                            returningOfflineFiles.append(url)
                            NSLog("🔄 Hash match - file unchanged: %@", fileName)
                        } else {
                            // Hash different - file changed
                            changedOfflineFiles.append(url)
                            NSLog("⚠️ Hash mismatch - file changed: %@", fileName)
                        }
                    } else {
                        // No stored hash - treat as changed
                        changedOfflineFiles.append(url)
                    }
                }
            }
        } else if existingFileNames.contains(fileName) {
            // File already exists and is online - check if it has changed
            if let storedSize = segmentFileSizes[fileName],
                let currentSize = getFileSize(for: url) {

                if currentSize != storedSize {
                    // Size changed - file has been replaced
                    changedOfflineFiles.append(url)
                }
            }
        } else {
            // Truly new file
            newVideoFiles.append(url)
        }
    }

    // Handle returning offline files (same size - just remove offline status)
    for url in returningOfflineFiles {
        let fileName = url.lastPathComponent
        offlineMediaFiles.remove(fileName)
        offlineFileMetadata.removeValue(forKey: fileName)
        NSLog("✅ File %@ is back online", fileName)
    }

    // Handle changed offline files (different size - treat as modified)
    for url in changedOfflineFiles {
        let fileName = url.lastPathComponent
        offlineMediaFiles.remove(fileName)
        offlineFileMetadata.removeValue(forKey: fileName)
        segmentModificationDates[fileName] = Date()

        // Update file size metadata with new size
        if let newSize = getFileSize(for: url) {
            segmentFileSizes[fileName] = newSize
            NSLog("📊 Updated size for changed file: %@ (new size: %lld bytes)", fileName, newSize)
        }

        NSLog("✅ File %@ is back online and marked as modified", fileName)

        // Mark affected OCFs for re-print
        if let linkingResult = linkingResult {
            for ocfParent in linkingResult.ocfParents {
                for child in ocfParent.children {
                    if child.segment.fileName == fileName {
                        // Update print status...
                    }
                }
            }
        }
    }

    // Import truly new files
    guard !newVideoFiles.isEmpty else { return }

    NSLog("🎬 Auto-importing %d new %@ files...", newVideoFiles.count, isVFX ? "VFX" : "grade")

    // Import as segments with VFX flag
    Task {
        let mediaFiles = await analyzeDetectedFiles(urls: newVideoFiles, isVFX: isVFX)

        await MainActor.run {
            addSegments(mediaFiles)
            NSLog("✅ Auto-imported %d new %@ files from watch folder",
                mediaFiles.count, isVFX ? "VFX" : "grade")
        }
    }
}
```

**Why it's business logic:**
- Complex business rules for detecting file state (new, returning, changed)
- Size-based comparison with hash fallback strategy
- Automatic import triggering with VFX flag assignment
- Print status updates based on file changes
- Orchestrates multiple operations: file comparison, metadata updates, import, status updates

**Suggested refactoring:**
```swift
// SourcePrintCore/Workflows/FileChangeDetector.swift
public class FileChangeDetector {
    /// Classify detected files into new, returning, or changed
    public func classifyDetectedFiles(
        urls: [URL],
        existingSegments: [MediaFileInfo],
        offlineFiles: Set<String>,
        offlineMetadata: [String: OfflineFileMetadata],
        trackedSizes: [String: Int64],
        fsOps: FileSystemOperations
    ) -> FileClassification

    public struct FileClassification {
        let newFiles: [URL]
        let returningUnchanged: [URL]
        let returningChanged: [URL]
        let existingModified: [URL]
    }
}

// SourcePrintCore/Workflows/AutoImportService.swift
public class AutoImportService {
    public func handleDetectedFiles(
        _ classification: FileClassification,
        isVFX: Bool,
        mediaAnalyzer: MediaAnalyzer
    ) async -> AutoImportResult

    public struct AutoImportResult {
        let importedFiles: [MediaFileInfo]
        let offlineStatusUpdates: [String: OfflineStatus]
        let sizeUpdates: [String: Int64]
        let affectedOCFs: [String]  // OCFs that need re-print
    }
}

// UI layer just applies the result:
func applyAutoImportResult(_ result: AutoImportResult) {
    segments.append(contentsOf: result.importedFiles)
    offlineMediaFiles.subtract(result.offlineStatusUpdates.keys)
    segmentFileSizes.merge(result.sizeUpdates) { _, new in new }
    updatePrintStatusForOCFs(result.affectedOCFs)
}
```

**Complexity:** High - Complex business rules, multiple interdependent operations

---

#### Violation 1.5: Media Analysis Invocation

**Lines:** 844-878

**Code:**
```swift
/// Analyze detected video files for import
private func analyzeDetectedFiles(urls: [URL], isVFX: Bool) async -> [MediaFileInfo] {
    NSLog("🔍 Analyzing %d detected %@ files...", urls.count, isVFX ? "VFX" : "grade")

    // Process files serially to avoid potential MediaAnalyzer threading issues on M1
    var results: [MediaFileInfo] = []

    for url in urls {
        do {
            NSLog("📹 Analyzing: %@", url.lastPathComponent)
            let mediaFile = try await MediaAnalyzer().analyzeMediaFile(
                at: url,
                type: .gradedSegment
            )

            // Set VFX flag on the media file if it's from VFX folder
            if isVFX {
                var vfxMediaFile = mediaFile
                vfxMediaFile.isVFXShot = true
                results.append(vfxMediaFile)
            } else {
                results.append(mediaFile)
            }

            NSLog("✅ Analyzed: %@", url.lastPathComponent)
        } catch {
            NSLog("❌ Failed to analyze watch folder file %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    NSLog("✅ Analysis complete: %d/%d files analyzed successfully", results.count, urls.count)
    return results
}
```

**Why it's business logic:**
- Orchestrates media analysis with serial processing strategy
- Implements business rule: set VFX flag based on source folder
- Error handling and logging for import failures
- Should be in AutoImportService, not UI model

**Complexity:** Low - Straightforward extraction to AutoImportService

---

### 2. LinkingResultsView.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Features/Linking/LinkingResultsView.swift`

**Total Lines:** 931 lines

**Violation Severity:** CRITICAL

**Why it belongs in core:** This is a SwiftUI View that contains complete implementations of batch rendering queue, blank rush creation, FFmpeg video composition, and SMPTE timecode calculations. Views should delegate to services, not implement complex workflows.

---

#### Violation 2.1: Batch Render Queue Management

**Lines:** 136-238 (100+ lines)

**Code:**
```swift
// Batch render queue
@State private var batchRenderQueue: [String] = []
@State private var isProcessingBatchQueue = false
@State private var totalInBatch: Int = 0
@State private var currentlyRenderingOCF: String? = nil  // Track which OCF is currently rendering

private func renderAll() {
    let ocfsToRender = confidentlyLinkedParents.filter { parent in
        !project.offlineMediaFiles.contains(parent.ocf.fileName)
    }

    NSLog("🎬 Starting batch render for %d OCFs", ocfsToRender.count)

    batchRenderQueue = ocfsToRender.map { $0.ocf.fileName }
    totalInBatch = batchRenderQueue.count
    isProcessingBatchQueue = true

    // Start processing queue - each card will handle blank rush + print
    processBatchRenderQueue()
}

private func processBatchRenderQueue() {
    guard !batchRenderQueue.isEmpty else {
        isProcessingBatchQueue = false
        totalInBatch = 0
        NSLog("✅ Batch render queue completed!")
        return
    }

    let nextOCFFileName = batchRenderQueue.removeFirst()

    NSLog("📤 Processing batch queue: %@ (%d remaining)", nextOCFFileName, batchRenderQueue.count)

    // Find the parent for this OCF
    guard let parent = confidentlyLinkedParents.first(where: { $0.ocf.fileName == nextOCFFileName }) else {
        NSLog("⚠️ Could not find parent for %@, skipping", nextOCFFileName)
        processBatchRenderQueue()
        return
    }

    // Set the currently rendering OCF (prevents other cards from starting)
    currentlyRenderingOCF = nextOCFFileName

    // Post notification to trigger card's UI and rendering
    NotificationCenter.default.post(
        name: .renderOCF,
        object: nil,
        userInfo: ["ocfFileName": nextOCFFileName]
    )

    // Poll until this OCF completes or times out (5 minutes max per OCF)
    var pollCount = 0
    let maxPolls = 600 // 5 minutes at 0.5s intervals

    Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { timer in
        pollCount += 1

        if case .printed = project.printStatus[nextOCFFileName] {
            timer.invalidate()
            NSLog("✅ Completed %@ after %d polls, processing next in queue", nextOCFFileName, pollCount)

            // Clear currently rendering flag
            currentlyRenderingOCF = nil

            // Small delay then process next item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                processBatchRenderQueue()
            }
        } else if pollCount >= maxPolls {
            timer.invalidate()
            NSLog("⚠️ Timeout waiting for %@ after %d seconds, falling back to direct processing", nextOCFFileName, pollCount / 2)

            // Clear currently rendering flag before fallback
            currentlyRenderingOCF = nil

            // Fallback to direct processing if card doesn't respond
            Task {
                await processOCFInQueue(parent: parent)

                // Process next item
                await MainActor.run {
                    processBatchRenderQueue()
                }
            }
        } else if pollCount % 20 == 0 {
            // Log status every 10 seconds
            NSLog("   Still waiting for %@... (status: %@)", nextOCFFileName, String(describing: project.printStatus[nextOCFFileName]))
        }
    }
}
```

**Why it's business logic:**
- Complete queue state machine implementation
- Polling-based coordination between queue and individual renders
- Timeout handling with fallback strategy
- Business rules: skip offline files, process serially, limit concurrency to 1
- Should be in `RenderQueueManager` in core

**Suggested refactoring:**
```swift
// SourcePrintCore/Workflows/RenderQueueManager.swift
public protocol RenderQueueDelegate: AnyObject {
    func renderQueue(_ queue: RenderQueueManager, willStartRendering ocfFileName: String, index: Int, total: Int)
    func renderQueue(_ queue: RenderQueueManager, didCompleteRendering ocfFileName: String, result: Result<URL, Error>)
    func renderQueue(_ queue: RenderQueueManager, didTimeout ocfFileName: String)
}

public class RenderQueueManager {
    public weak var delegate: RenderQueueDelegate?

    private var queue: [String] = []
    private var currentlyRendering: String?
    private var completionTimeouts: [String: Int] = [:]

    public func enqueueAll(_ ocfFileNames: [String])
    public func enqueueModified(_ ocfFileNames: [String])
    public func processNext(using renderer: RenderService) async
    public func cancelAll()

    public var isProcessing: Bool { currentlyRendering != nil }
    public var progress: (completed: Int, total: Int)
}

// UI layer becomes thin observer:
struct LinkingResultsView: View {
    @StateObject private var renderQueueManager: RenderQueueManager

    var body: some View {
        // Just display queue state and buttons
        if renderQueueManager.isProcessing {
            Text("Rendering \(renderQueueManager.progress.completed)/\(renderQueueManager.progress.total)")
        }

        Button("Render All") {
            let ocfs = confidentlyLinkedParents.map { $0.ocf.fileName }
            renderQueueManager.enqueueAll(ocfs)
        }
    }
}
```

**Complexity:** High - State machine with polling, requires careful async coordination

---

#### Violation 2.2: Blank Rush Creation in View

**Lines:** 292-329

**Code:**
```swift
@MainActor
private func createBlankRushForOCF(parent: OCFParent) async -> URL? {
    let ocfFileName = parent.ocf.fileName

    // Mark as in progress
    project.blankRushStatus[ocfFileName] = .inProgress
    projectManager.saveProject(project)

    // Create single-file linking result for this OCF
    let singleOCFResult = LinkingResult(
        ocfParents: [parent],
        unmatchedSegments: [],
        unmatchedOCFs: []
    )

    let blankRushCreator = BlankRushIntermediate(projectDirectory: project.blankRushDirectory.path)

    // Create blank rush
    let results = await blankRushCreator.createBlankRushes(from: singleOCFResult)

    // Process result
    if let result = results.first {
        if result.success {
            project.blankRushStatus[result.originalOCF.fileName] = .completed(date: Date(), url: result.blankRushURL)
            projectManager.saveProject(project)
            NSLog("✅ Created blank rush for \(ocfFileName)")
            return result.blankRushURL
        } else {
            let errorMessage = result.error ?? "Unknown error"
            project.blankRushStatus[result.originalOCF.fileName] = .failed(error: errorMessage)
            projectManager.saveProject(project)
            NSLog("❌ Failed to create blank rush for \(ocfFileName): \(errorMessage)")
            return nil
        }
    }

    return nil
}
```

**Why it's business logic:**
- Workflow orchestration: status update → blank rush creation → status update → save
- Business rules for status state transitions (.inProgress → .completed/.failed)
- Direct invocation of BlankRushIntermediate from UI
- Should be in `RenderWorkflowService` in core

**Complexity:** Medium - Workflow orchestration, needs careful state management

---

#### Violation 2.3: Complete FFmpeg Rendering in View

**Lines:** 331-438 (100+ lines)

**Code:**
```swift
@MainActor
private func renderOCFInQueue(parent: OCFParent, blankRushURL: URL) async {
    let ocfFileName = parent.ocf.fileName
    NSLog("🎥 Rendering \(ocfFileName)")

    do {
        // Generate output filename
        let baseName = (ocfFileName as NSString).deletingPathExtension
        let outputFileName = "\(baseName).mov"
        let outputURL = project.outputDirectory.appendingPathComponent(outputFileName)

        // Create SwiftFFmpeg compositor
        let compositor = SwiftFFmpegProResCompositor()

        // Convert linked children to FFmpegGradedSegments
        var ffmpegGradedSegments: [FFmpegGradedSegment] = []
        for child in parent.children {
            let segmentInfo = child.segment

            if let segmentTC = segmentInfo.sourceTimecode,
               let baseTC = parent.ocf.sourceTimecode,
               let segmentFrameRate = segmentInfo.frameRate,
               let segmentFrameRateFloat = segmentInfo.frameRateFloat,
               let duration = segmentInfo.durationInFrames {

                let smpte = SMPTE(fps: Double(segmentFrameRateFloat), dropFrame: segmentInfo.isDropFrame ?? false)

                do {
                    let segmentFrames = try smpte.getFrames(tc: segmentTC)
                    let baseFrames = try smpte.getFrames(tc: baseTC)
                    let relativeFrames = segmentFrames - baseFrames

                    let startTime = CMTime(
                        value: CMTimeValue(relativeFrames),
                        timescale: CMTimeScale(segmentFrameRateFloat)
                    )

                    let segmentDuration = CMTime(
                        seconds: Double(duration) / Double(segmentFrameRateFloat),
                        preferredTimescale: CMTimeScale(segmentFrameRateFloat * 1000)
                    )

                    let ffmpegSegment = FFmpegGradedSegment(
                        url: segmentInfo.url,
                        startTime: startTime,
                        duration: segmentDuration,
                        sourceStartTime: .zero,
                        isVFXShot: segmentInfo.isVFXShot ?? false,
                        sourceTimecode: segmentInfo.sourceTimecode,
                        frameRate: segmentFrameRateFloat,
                        frameRateRational: segmentFrameRate,
                        isDropFrame: segmentInfo.isDropFrame
                    )
                    ffmpegGradedSegments.append(ffmpegSegment)
                } catch {
                    NSLog("⚠️ SMPTE calculation failed for \(segmentInfo.fileName): \(error.localizedDescription)")
                    continue
                }
            }
        }

        guard !ffmpegGradedSegments.isEmpty else {
            NSLog("❌ No valid FFmpeg graded segments for \(ocfFileName)")
            return
        }

        // Setup compositor settings
        let settings = FFmpegCompositorSettings(
            outputURL: outputURL,
            baseVideoURL: blankRushURL,
            gradedSegments: ffmpegGradedSegments,
            proResProfile: "4"
        )

        // Process composition
        let compositionStartTime = Date()
        let result = await withCheckedContinuation { continuation in
            compositor.completionHandler = { result in
                continuation.resume(returning: result)
            }
            compositor.composeVideo(with: settings)
        }

        let compositionDuration = Date().timeIntervalSince(compositionStartTime)

        switch result {
        case .success(let finalOutputURL):
            let printRecord = PrintRecord(
                date: Date(),
                outputURL: finalOutputURL,
                segmentCount: ffmpegGradedSegments.count,
                duration: compositionDuration,
                success: true
            )

            project.printStatus[ocfFileName] = .printed(date: Date(), outputURL: finalOutputURL)
            project.printHistory.append(printRecord)
            projectManager.saveProject(project)

            NSLog("✅ Successfully rendered \(ocfFileName) in %.1fs", compositionDuration)

        case .failure(let error):
            NSLog("❌ Failed to render \(ocfFileName): \(error.localizedDescription)")
        }
    } catch {
        NSLog("❌ Error rendering \(ocfFileName): \(error.localizedDescription)")
    }
}
```

**Why it's business logic:**
- Complete video composition workflow: segment conversion → SMPTE calculation → FFmpeg invocation
- Complex CMTime arithmetic for segment positioning
- SMPTE timecode-to-frame conversion (should use core's SMPTE utility)
- FFmpegGradedSegment construction with all metadata
- Print record creation and status updates
- Direct interaction with SwiftFFmpegProResCompositor

**This is the most egregious violation:** 100+ lines of video processing code inside a SwiftUI View

**Suggested refactoring:**
```swift
// SourcePrintCore/Workflows/RenderService.swift
public class RenderService {
    private let compositor: SwiftFFmpegProResCompositor
    private let smpteCalculator: SMPTECalculator

    public func render(
        ocfParent: OCFParent,
        blankRushURL: URL,
        outputDirectory: URL
    ) async -> RenderResult

    public struct RenderResult {
        let success: Bool
        let outputURL: URL?
        let segmentCount: Int
        let duration: TimeInterval
        let error: Error?
    }

    // Internal helper
    private func convertToFFmpegSegments(
        _ children: [LinkedSegment],
        baseTimecode: String,
        frameRate: Float
    ) throws -> [FFmpegGradedSegment]
}

// UI layer becomes simple:
Button("Render") {
    Task {
        let result = await renderService.render(
            ocfParent: parent,
            blankRushURL: blankRushURL,
            outputDirectory: project.outputDirectory
        )

        if result.success {
            // Update UI state only
            project.printStatus[parent.ocf.fileName] = .printed(date: Date(), outputURL: result.outputURL!)
        }
    }
}
```

**Complexity:** High - Complex workflow with timecode math, requires careful extraction

---

### 3. CompressorStyleOCFCard.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Features/Linking/Components/OCFCard/CompressorStyleOCFCard.swift`

**Violation Severity:** CRITICAL

**Why it belongs in core:** This SwiftUI card component contains render orchestration logic including blank rush generation, FFmpeg composition, and state management. Should delegate to RenderService.

---

#### Violation 3.1: Render Workflow Orchestration

**Lines:** 80-178 (100+ lines)

**Code:**
```swift
private func startRendering() {
    guard !isRendering else { return }

    // Check global rendering lock - only proceed if this card is the one that should render
    if let rendering = currentlyRenderingOCF, rendering != parent.ocf.fileName {
        NSLog("⏸️ Skipping %@ - another OCF is currently rendering (%@)", parent.ocf.fileName, rendering)
        return
    }

    // Check if blank rush exists
    let blankRushStatus = project.blankRushStatus[parent.ocf.fileName] ?? .notCreated

    switch blankRushStatus {
    case .completed(_, let blankRushURL):
        // Verify blank rush file actually exists on disk
        if FileManager.default.fileExists(atPath: blankRushURL.path) {
            // Blank rush exists - proceed directly to render
            beginRender(with: blankRushURL)
        } else {
            // Status says completed but file is missing - regenerate
            NSLog("⚠️ Blank rush file missing for \(parent.ocf.fileName) - regenerating")
            project.blankRushStatus[parent.ocf.fileName] = .notCreated
            startRendering() // Retry - will hit .notCreated case
        }

    case .notCreated:
        // No blank rush - create it first, then render
        NSLog("📝 No blank rush exists for \(parent.ocf.fileName) - creating automatically")
        isRendering = true
        renderStartTime = Date()
        elapsedTime = 0
        renderProgress = "Creating blank rush..."

        // Start timer
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            if let startTime = renderStartTime {
                elapsedTime = Date().timeIntervalSince(startTime)
            }
        }

        Task {
            if let blankRushURL = await generateBlankRushForOCF() {
                // Blank rush created successfully - proceed to render
                await MainActor.run {
                    renderProgress = "Blank rush ready - rendering..."
                }
                await renderOCF(blankRushURL: blankRushURL)
            } else {
                // Blank rush creation failed
                await MainActor.run {
                    stopRendering()
                    NSLog("❌ Failed to create blank rush for \(parent.ocf.fileName)")
                }
            }
        }

    case .inProgress:
        // Check if blank rush file exists from previous incomplete creation
        let expectedURL = project.blankRushDirectory.appendingPathComponent("\(parent.ocf.fileName)_blank.mov")

        if FileManager.default.fileExists(atPath: expectedURL.path) {
            // File exists - verify it's a valid video file using MediaAnalyzer
            NSLog("🔍 Validating stuck .inProgress blank rush for \(parent.ocf.fileName)...")
            Task {
                let isValid = await isValidBlankRush(at: expectedURL)

                await MainActor.run {
                    if isValid {
                        // File is valid - mark as completed and use it
                        NSLog("✅ Found valid blank rush file for stuck .inProgress status: \(parent.ocf.fileName)")
                        project.blankRushStatus[parent.ocf.fileName] = .completed(date: Date(), url: expectedURL)
                        beginRender(with: expectedURL)
                    } else {
                        // File is invalid/corrupted - reset and regenerate
                        NSLog("⚠️ Invalid blank rush file for .inProgress status - regenerating: \(parent.ocf.fileName)")
                        project.blankRushStatus[parent.ocf.fileName] = .notCreated
                        startRendering()
                    }
                }
            }
        } else {
            // Status is .inProgress but file doesn't exist - reset to .notCreated
            NSLog("⚠️ Blank rush stuck in .inProgress but file missing for \(parent.ocf.fileName) - resetting")
            project.blankRushStatus[parent.ocf.fileName] = .notCreated
            startRendering() // Retry - will hit .notCreated case
        }

    case .failed(let error):
        // Allow retry by resetting to .notCreated
        NSLog("⚠️ Previous blank rush creation failed for \(parent.ocf.fileName): \(error) - retrying")
        project.blankRushStatus[parent.ocf.fileName] = .notCreated
        startRendering()
    }
}

/// Validate that a blank rush file is actually a valid, readable video file
private func isValidBlankRush(at url: URL) async -> Bool {
    do {
        // Use MediaAnalyzer to verify it's a valid video file
        let _ = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .gradedSegment)
        return true
    } catch {
        NSLog("⚠️ Blank rush validation failed for \(url.lastPathComponent): \(error)")
        return false
    }
}
```

**Why it's business logic:**
- Complex state machine for blank rush status (.notCreated, .inProgress, .completed, .failed)
- Business rules: validate file existence, recover from stuck states, retry on failure
- Direct file system checks with FileManager
- Video file validation using MediaAnalyzer
- Orchestration: blank rush → validation → render workflow

**This is a UI component doing workflow orchestration** - should just display state and delegate actions

**Suggested refactoring:**
```swift
// SourcePrintCore/Workflows/RenderWorkflowService.swift
public class RenderWorkflowService {
    public func executeRenderWorkflow(
        for ocfParent: OCFParent,
        blankRushDirectory: URL,
        outputDirectory: URL
    ) async -> RenderWorkflowResult

    public struct RenderWorkflowResult {
        let blankRushURL: URL
        let renderResult: RenderResult
        let blankRushCreated: Bool
    }

    // Internal: Handle blank rush state machine
    private func resolveBlankRush(
        for ocfParent: OCFParent,
        currentStatus: BlankRushStatus,
        blankRushDirectory: URL
    ) async throws -> URL
}

// UI component becomes simple:
struct CompressorStyleOCFCard: View {
    @State private var renderWorkflowState: RenderWorkflowState = .idle

    var body: some View {
        Button("Render") {
            renderWorkflowState = .working(progress: "Starting...")

            Task {
                let result = await renderWorkflowService.executeRenderWorkflow(
                    for: parent,
                    blankRushDirectory: project.blankRushDirectory,
                    outputDirectory: project.outputDirectory
                )

                renderWorkflowState = result.success ? .completed : .failed(error: result.error)
            }
        }

        if case .working(let progress) = renderWorkflowState {
            ProgressView(progress)
        }
    }
}
```

**Complexity:** High - Complex state machine with validation and retry logic

---

### 4. ProjectManager.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Models/ProjectManager.swift`

**Total Lines:** 427 lines

**Violation Severity:** MEDIUM-HIGH

**Why it belongs in core:** ProjectManager is marked `@ObservableObject` for SwiftUI but contains workflow orchestration, import coordination, and linking execution. Should delegate to workflow services in core.

---

#### Violation 4.1: Import Process Orchestration

**Lines:** 338-367

**Code:**
```swift
// MARK: - Import Integration
func importOCFFiles(for project: Project, from directory: URL) async -> [MediaFileInfo] {
    let importProcess = ImportProcess()

    do {
        let files = try await importProcess.importOriginalCameraFiles(from: directory)
        project.addOCFFiles(files)
        saveProject(project)
        return files
    } catch {
        print("❌ Failed to import OCF files: \(error)")
        return []
    }
}

func importSegments(for project: Project, from directory: URL) async -> [MediaFileInfo] {
    let importProcess = ImportProcess()

    do {
        let files = try await importProcess.importGradedSegments(from: directory)
        project.addSegments(files)
        // Refresh print status after adding segments
        project.refreshPrintStatus()
        saveProject(project)
        return files
    } catch {
        print("❌ Failed to import segments: \(error)")
        return []
    }
}
```

**Why it's business logic:**
- Orchestrates import workflow: analysis → add to project → refresh status → save
- Business rule: refresh print status after segment import
- Should be in `ProjectWorkflow` service in core

**Complexity:** Low - Simple orchestration, easy extraction

---

#### Violation 4.2: Linking Execution with Business Rules

**Lines:** 369-397

**Code:**
```swift
func performLinking(for project: Project) {
    guard !project.ocfFiles.isEmpty && !project.segments.isEmpty else {
        print("⚠️ Need both OCF files and segments to perform linking")
        return
    }

    // Filter out offline segments before linking
    let onlineSegments = project.segments.filter { !project.offlineMediaFiles.contains($0.fileName) }
    let offlineCount = project.segments.count - onlineSegments.count

    if offlineCount > 0 {
        print("⚠️ Skipping \(offlineCount) offline segment(s) during linking")
    }

    guard !onlineSegments.isEmpty else {
        print("⚠️ No online segments available for linking")
        return
    }

    let linker = SegmentOCFLinker()
    let result = linker.linkSegments(onlineSegments, withOCFParents: project.ocfFiles)

    project.updateLinkingResult(result)
    // Refresh print status after linking (in case segment files changed)
    project.refreshPrintStatus()
    saveProject(project)

    print("✅ Linking completed: \(result.summary)")
}
```

**Why it's business logic:**
- Business rule: filter offline segments before linking
- Orchestration: validate → filter → link → update → refresh status → save
- Validation logic (check for empty files/segments)
- Should be in `ProjectWorkflow` service in core

**Complexity:** Low - Straightforward extraction

---

#### Violation 4.3: Blank Rush Generation Coordination

**Lines:** 399-426

**Code:**
```swift
func createBlankRushes(for project: Project) async {
    guard let linkingResult = project.linkingResult else { return }

    let blankRushIntermediate = BlankRushIntermediate(
        projectDirectory: project.blankRushDirectory.path
    )

    // Update status to in progress for all parents
    for parent in linkingResult.parentsWithChildren {
        project.updateBlankRushStatus(ocfFileName: parent.ocf.fileName, status: .inProgress)
    }
    saveProject(project)

    let results = await blankRushIntermediate.createBlankRushes(from: linkingResult)

    // Update statuses based on results
    for result in results {
        let status: BlankRushStatus
        if result.success {
            status = .completed(date: Date(), url: result.blankRushURL)
        } else {
            status = .failed(error: result.error ?? "Unknown error")
        }
        project.updateBlankRushStatus(ocfFileName: result.originalOCF.fileName, status: status)
    }

    saveProject(project)
}
```

**Why it's business logic:**
- Workflow orchestration: mark in progress → create blank rushes → update status → save
- Business rules for status transitions
- Should be in `ProjectWorkflow` service in core

**Complexity:** Low - Simple workflow orchestration

---

## Medium Violations

### 5. MediaImportTab.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Features/MediaImport/MediaImportTab.swift`

**Total Lines:** 345 lines (excluding WatchFolderSection)

**Violation Severity:** MEDIUM

**Why it belongs in core:** SwiftUI view contains recursive file discovery, concurrent processing strategy, and progress throttling logic.

---

#### Violation 5.1: Recursive File Discovery

**Lines:** 183-211

**Code:**
```swift
private func getAllVideoFiles(from directoryURL: URL) async -> [URL] {
    var videoFiles: [URL] = []
    let videoExtensions = ["mov", "mp4", "m4v", "mxf"]

    guard let enumerator = FileManager.default.enumerator(
        at: directoryURL,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else {
        return videoFiles
    }

    for case let fileURL as URL in enumerator {
        do {
            let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if resourceValues.isRegularFile == true {
                let fileExtension = fileURL.pathExtension.lowercased()
                if videoExtensions.contains(fileExtension) {
                    videoFiles.append(fileURL)
                }
            }
        } catch {
            print("Error processing file \(fileURL): \(error)")
        }
    }

    return videoFiles.sorted { $0.lastPathComponent < $1.lastPathComponent }
}
```

**Why it's business logic:**
- File system traversal algorithm
- Business rule: video file extension validation
- Sorting strategy
- Should be in `VideoFileDiscovery` utility in core

**Complexity:** Low - Self-contained utility function

---

#### Violation 5.2: Parallel Processing Strategy

**Lines:** 234-315 (80+ lines)

**Code:**
```swift
private func analyzeMediaFilesInParallel(urls: [URL], isOCF: Bool) async -> [MediaFileInfo] {
    // For I/O-bound tasks like media analysis, we can use much higher concurrency
    let maxConcurrentTasks = min(urls.count, 50)  // Increased from CPU core count to 50
    var completedCount = 0
    let totalCount = urls.count
    var lastUpdateTime = CFAbsoluteTimeGetCurrent()
    let updateInterval: CFTimeInterval = 0.5  // Update UI every 0.5 seconds

    return await withTaskGroup(of: (Int, MediaFileInfo?).self, returning: [MediaFileInfo].self) { taskGroup in
        var urlIndex = 0

        // Start initial batch of tasks
        for _ in 0..<min(maxConcurrentTasks, urls.count) {
            let index = urlIndex
            let url = urls[index]
            urlIndex += 1

            taskGroup.addTask {
                do {
                    let mediaFile = try await MediaAnalyzer().analyzeMediaFile(
                        at: url,
                        type: isOCF ? .originalCameraFile : .gradedSegment
                    )
                    return (index, mediaFile)
                } catch {
                    NSLog("❌ Failed to analyze \(url.lastPathComponent): \(error)")
                    return (index, nil)
                }
            }
        }

        // Collect results and maintain steady concurrency
        var results: [(Int, MediaFileInfo?)] = []
        results.reserveCapacity(totalCount)  // Pre-allocate array capacity

        for await result in taskGroup {
            results.append(result)
            completedCount += 1

            // Add next task if we have more URLs to process
            if urlIndex < urls.count {
                let index = urlIndex
                let url = urls[index]
                urlIndex += 1

                taskGroup.addTask {
                    do {
                        let mediaFile = try await MediaAnalyzer().analyzeMediaFile(
                            at: url,
                            type: isOCF ? .originalCameraFile : .gradedSegment
                        )
                        return (index, mediaFile)
                    } catch {
                        NSLog("❌ Failed to analyze \(url.lastPathComponent): \(error)")
                        return (index, nil)
                    }
                }
            }

            // Throttled UI updates
            let currentTime = CFAbsoluteTimeGetCurrent()
            if currentTime - lastUpdateTime >= updateInterval || completedCount == totalCount {
                lastUpdateTime = currentTime

                await MainActor.run {
                    let (_, mediaFile) = result
                    if let mediaFile = mediaFile {
                        analysisProgress = "Analyzing files... \(completedCount)/\(totalCount) completed - \(mediaFile.fileName)"
                    } else {
                        analysisProgress = "Analyzing files... \(completedCount)/\(totalCount) completed"
                    }
                }
            }
        }

        // Sort by original index and filter out failed analyses
        return results
            .sorted { $0.0 < $1.0 }
            .compactMap { $0.1 }
    }
}
```

**Why it's business logic:**
- Complex concurrent processing strategy with TaskGroup
- Business rule: maxConcurrentTasks = 50 for I/O-bound operations
- Progress throttling algorithm (0.5s interval)
- Result ordering and error handling
- Should be in `MediaImportParallelizer` service in core

**Complexity:** Medium - Complex concurrency patterns, requires careful extraction

---

### 6. LinkingTab.swift

**File Path:** `/Users/mac10/Projects/SourcePrint/SourcePrint/SourcePrint/Features/Linking/LinkingTab.swift`

**Total Lines:** 323 lines

**Violation Severity:** MEDIUM

**Why it belongs in core:** SwiftUI view contains processing plan generation, frame ownership analysis, and FFmpeg segment conversion logic.

---

#### Violation 6.1: Processing Plan Generation

**Lines:** 89-111, 136-177

**Code:**
```swift
private func generateTimelineVisualizationFromExistingData() {
    guard let linkingResult = project.linkingResult else { return }

    Task {
        var visualizationResults: [String: TimelineVisualization] = [:]

        for parent in linkingResult.parentsWithChildren {
            do {
                let processingPlan = try await generateProcessingPlan(for: parent)

                if let visualizationData = processingPlan.visualizationData {
                    visualizationResults[parent.ocf.fileName] = visualizationData
                }
            } catch {
                NSLog("⚠️ Failed to generate timeline visualization for \(parent.ocf.fileName): \(error)")
            }
        }

        await MainActor.run {
            timelineVisualizationData = visualizationResults
        }
    }
}

private func generateProcessingPlan(for parent: OCFParent) async throws -> ProcessingPlan {
    // Convert MediaFileInfo segments to FFmpegGradedSegments
    var ffmpegSegments: [FFmpegGradedSegment] = []

    for child in parent.children {
        let segment = child.segment

        // Create FFmpegGradedSegment from MediaFileInfo
        let ffmpegSegment = FFmpegGradedSegment(
            url: segment.url,
            startTime: CMTime.zero, // Will be calculated by analyzer
            duration: CMTime(seconds: Double(segment.durationInFrames!) / Double(segment.frameRate!.floatValue), preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: segment.isVFXShot ?? false,
            sourceTimecode: segment.sourceTimecode,
            frameRate: segment.frameRate!.floatValue,
            frameRateRational: segment.frameRate,
            isDropFrame: segment.isDropFrame
        )

        ffmpegSegments.append(ffmpegSegment)
    }

    // Create base properties from OCF parent
    let ocf = parent.ocf
    let baseProperties = VideoStreamProperties(
        width: Int(ocf.resolution!.width),
        height: Int(ocf.resolution!.height),
        frameRate: ocf.frameRate!,
        frameRateFloat: ocf.frameRate!.floatValue,
        duration: Double(ocf.durationInFrames!) / Double(ocf.frameRate!.floatValue),
        timebase: AVRational(num: 1, den: Int32(ocf.frameRate!.floatValue)),
        timecode: ocf.sourceTimecode
    )

    let totalFrames = Int(ocf.durationInFrames!)

    // Run the FrameOwnershipAnalyzer
    let analyzer = FrameOwnershipAnalyzer(
        baseProperties: baseProperties,
        segments: ffmpegSegments,
        totalFrames: totalFrames,
        verbose: true
    )

    return try analyzer.analyze()
}
```

**Why it's business logic:**
- FFmpeg segment conversion from MediaFileInfo
- CMTime duration calculations
- VideoStreamProperties construction
- FrameOwnershipAnalyzer invocation
- Should be in `LinkingWorkflowService` in core

**Complexity:** Medium - Data transformation and workflow orchestration

---

## Summary by Violation Type

### File System Operations
| File | Lines | Complexity | Priority |
|------|-------|------------|----------|
| Project.swift | 432-494 | Low | High |
| CompressorStyleOCFCard.swift | 88-104 | Low | High |
| MediaImportTab.swift | 183-211 | Low | High |

**Total:** ~100 lines of file system operations in UI layer

---

### Video Processing & FFmpeg
| File | Lines | Complexity | Priority |
|------|-------|------------|----------|
| LinkingResultsView.swift | 331-438 | High | CRITICAL |
| CompressorStyleOCFCard.swift | 262-400+ | High | CRITICAL |
| LinkingTab.swift | 179-225 | Medium | High |

**Total:** ~300+ lines of video processing in UI layer

---

### Workflow Orchestration
| File | Lines | Complexity | Priority |
|------|-------|------------|----------|
| LinkingResultsView.swift | 136-329 | High | CRITICAL |
| CompressorStyleOCFCard.swift | 80-260 | High | CRITICAL |
| ProjectManager.swift | 338-426 | Low-Medium | High |
| Project.swift | 517-999 | Medium-High | CRITICAL |

**Total:** ~600+ lines of workflow orchestration in UI layer

---

### Concurrent Processing
| File | Lines | Complexity | Priority |
|------|-------|------------|----------|
| MediaImportTab.swift | 234-315 | Medium | Medium |

**Total:** ~80 lines of concurrency logic in UI layer

---

### Cryptographic Operations
| File | Lines | Complexity | Priority |
|------|-------|------------|----------|
| Project.swift | 455-494 | Low | High |

**Total:** ~40 lines of hashing logic in UI layer

---

## Grand Total

**Estimated Lines of Business Logic in UI Layer:** ~2000+ lines

**Critical Files Requiring Immediate Refactoring:**
1. `Project.swift` - 1000+ lines of business logic
2. `LinkingResultsView.swift` - 500+ lines of render queue and composition
3. `CompressorStyleOCFCard.swift` - 300+ lines of render orchestration
4. `ProjectManager.swift` - 200+ lines of workflow coordination

**Impact:**
- Cannot unit test critical business logic (rendering, watch folders, import)
- Cannot reuse workflows in CLI or automation scripts
- UI changes risk breaking business logic
- Code organization violates clean architecture principles
- Testing requires full macOS GUI environment

---

## Next Steps

Refer to `refactoring_plan.md` for detailed migration strategy to move this logic to `SourcePrintCore`.
