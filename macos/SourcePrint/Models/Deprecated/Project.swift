//
//  Project.swift
//  ProResWriter
//
//  Created by Claude on 25/08/2025.
//
//  ⚠️ DEPRECATED - DO NOT USE IN NEW CODE
//  This class is kept ONLY for backward compatibility when loading old .w2 files.
//  All new code should use ProjectViewModel instead.
//  See ProjectManager.swift loadProject() for migration logic.
//

import CryptoKit
import Foundation
import SourcePrintCore
import SwiftUI

// MARK: - DEPRECATED Project Data Model (For Migration Only)

class Project: ObservableObject, Codable, Identifiable, WatchFolderDelegate {

    // MARK: - Basic Project Info
    let id = UUID()
    @Published var name: String
    @Published var createdDate: Date
    @Published var lastModified: Date

    // MARK: - Core Data Integration
    @Published var ocfFiles: [MediaFileInfo] = []
    @Published var segments: [MediaFileInfo] = []
    @Published var linkingResult: LinkingResult?
    // Note: ProcessingPlans are generated on-demand during print process to avoid Codable complexity

    // MARK: - Status Tracking
    @Published var blankRushStatus: [String: BlankRushStatus] = [:]  // OCF filename → status
    @Published var segmentModificationDates: [String: Date] = [:]  // Segment filename → last modified date
    @Published var segmentFileSizes: [String: Int64] = [:]  // Segment filename → file size (proactive tracking)
    @Published var offlineMediaFiles: Set<String> = []  // Track offline (deleted/moved) media files
    @Published var offlineFileMetadata: [String: OfflineFileMetadata] = [:]  // Track metadata for offline files
    @Published var lastPrintDate: Date?
    @Published var printHistory: [PrintRecord] = []
    @Published var ocfCardExpansionState: [String: Bool] = [:]  // OCF filename → isExpanded (default true if not set)

    // MARK: - Render Queue System
    @Published var renderQueue: [RenderQueueItem] = []
    @Published var printStatus: [String: PrintStatus] = [:]  // OCF filename → print status

    // MARK: - Project Settings
    @Published var outputDirectory: URL
    @Published var blankRushDirectory: URL
    @Published var fileURL: URL?

    // MARK: - Watch Folder Settings
    @Published var watchFolderSettings: WatchFolderSettings = WatchFolderSettings() {
        didSet {
            updateWatchFolderMonitoring()
        }
    }
    private var watchFolderService: WatchFolderService?

    // MARK: - Computed Properties
    var hasLinkedMedia: Bool {
        linkingResult?.totalLinkedSegments ?? 0 > 0
    }

    var readyForBlankRush: Bool {
        linkingResult?.parentsWithChildren.isEmpty == false
    }

    /// Check if blank rush file exists on disk for given OCF filename
    func blankRushFileExists(for ocfFileName: String) -> Bool {
        let baseName = (ocfFileName as NSString).deletingPathExtension
        let blankRushFileName = "\(baseName)_blankRush.mov"
        let blankRushURL = blankRushDirectory.appendingPathComponent(blankRushFileName)
        return FileManager.default.fileExists(atPath: blankRushURL.path)
    }

    var blankRushProgress: (completed: Int, total: Int) {
        let total = linkingResult?.parentsWithChildren.count ?? 0
        let completed = blankRushStatus.values.compactMap {
            if case .completed = $0 { return 1 } else { return nil }
        }.count
        return (completed, total)
    }

    /// Check if any segments have been modified since last blank rush generation
    var hasModifiedSegments: Bool {
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

    /// Get segments that have been modified since tracking started
    var modifiedSegments: [String] {
        guard let linkingResult = linkingResult else { return [] }
        var modified: [String] = []

        for parent in linkingResult.parentsWithChildren {
            for child in parent.children {
                let segmentFileName = child.segment.fileName

                if case .success(let fileModDate) = FileSystemOperations.getModificationDate(for: child.segment.url),
                    let trackedModDate = segmentModificationDates[segmentFileName],
                    fileModDate > trackedModDate
                {
                    modified.append(segmentFileName)
                }
            }
        }
        return modified
    }

    // MARK: - Initialization
    init(name: String, outputDirectory: URL, blankRushDirectory: URL) {
        self.name = name
        self.createdDate = Date()
        self.lastModified = Date()
        self.outputDirectory = outputDirectory
        self.blankRushDirectory = blankRushDirectory
    }

    // MARK: - Codable Implementation
    private enum CodingKeys: String, CodingKey {
        case name, createdDate, lastModified
        case ocfFiles, segments, linkingResult
        case blankRushStatus, segmentModificationDates, segmentFileSizes, offlineMediaFiles,
            offlineFileMetadata, lastPrintDate, printHistory
        case renderQueue, printStatus
        case outputDirectory, blankRushDirectory, fileURL
        case watchFolderSettings
        case ocfCardExpansionState
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        name = try container.decode(String.self, forKey: .name)
        createdDate = try container.decode(Date.self, forKey: .createdDate)
        lastModified = try container.decode(Date.self, forKey: .lastModified)

        ocfFiles = try container.decode([MediaFileInfo].self, forKey: .ocfFiles)
        segments = try container.decode([MediaFileInfo].self, forKey: .segments)
        linkingResult = try container.decodeIfPresent(LinkingResult.self, forKey: .linkingResult)

        blankRushStatus = try container.decode(
            [String: BlankRushStatus].self, forKey: .blankRushStatus)
        segmentModificationDates =
            try container.decodeIfPresent([String: Date].self, forKey: .segmentModificationDates)
            ?? [:]
        segmentFileSizes =
            try container.decodeIfPresent([String: Int64].self, forKey: .segmentFileSizes) ?? [:]
        offlineMediaFiles =
            try container.decodeIfPresent(Set<String>.self, forKey: .offlineMediaFiles) ?? []
        offlineFileMetadata =
            try container.decodeIfPresent(
                [String: OfflineFileMetadata].self, forKey: .offlineFileMetadata) ?? [:]
        lastPrintDate = try container.decodeIfPresent(Date.self, forKey: .lastPrintDate)
        printHistory =
            try container.decodeIfPresent([PrintRecord].self, forKey: .printHistory) ?? []

        renderQueue =
            try container.decodeIfPresent([RenderQueueItem].self, forKey: .renderQueue) ?? []
        printStatus =
            try container.decodeIfPresent([String: PrintStatus].self, forKey: .printStatus) ?? [:]

        outputDirectory = try container.decode(URL.self, forKey: .outputDirectory)
        blankRushDirectory = try container.decode(URL.self, forKey: .blankRushDirectory)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)

        watchFolderSettings =
            try container.decodeIfPresent(WatchFolderSettings.self, forKey: .watchFolderSettings)
            ?? WatchFolderSettings()

        ocfCardExpansionState =
            try container.decodeIfPresent([String: Bool].self, forKey: .ocfCardExpansionState)
            ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(name, forKey: .name)
        try container.encode(createdDate, forKey: .createdDate)
        try container.encode(lastModified, forKey: .lastModified)

        try container.encode(ocfFiles, forKey: .ocfFiles)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(linkingResult, forKey: .linkingResult)

        try container.encode(blankRushStatus, forKey: .blankRushStatus)
        try container.encode(segmentModificationDates, forKey: .segmentModificationDates)
        try container.encode(segmentFileSizes, forKey: .segmentFileSizes)
        try container.encode(offlineMediaFiles, forKey: .offlineMediaFiles)
        try container.encode(offlineFileMetadata, forKey: .offlineFileMetadata)
        try container.encodeIfPresent(lastPrintDate, forKey: .lastPrintDate)
        try container.encode(printHistory, forKey: .printHistory)

        try container.encode(renderQueue, forKey: .renderQueue)
        try container.encode(printStatus, forKey: .printStatus)

        try container.encode(outputDirectory, forKey: .outputDirectory)
        try container.encode(blankRushDirectory, forKey: .blankRushDirectory)
        try container.encodeIfPresent(fileURL, forKey: .fileURL)

        try container.encode(watchFolderSettings, forKey: .watchFolderSettings)

        try container.encode(ocfCardExpansionState, forKey: .ocfCardExpansionState)
    }

    // MARK: - Project Management
    func updateModified() {
        lastModified = Date()
    }

    func addOCFFiles(_ files: [MediaFileInfo]) {
        let result = ProjectOperations.addOCFFiles(files, existingOCFs: ocfFiles)
        applyOperationResult(result)
    }

    func addSegments(_ newSegments: [MediaFileInfo]) {
        let result = ProjectOperations.addSegments(
            newSegments,
            existingSegments: segments,
            existingFileSizes: segmentFileSizes
        )
        applyOperationResult(result)
    }

    /// Update modification dates for all segments (useful for refresh)
    func refreshSegmentModificationDates() {
        let result = ProjectOperations.refreshSegmentModificationDates(
            existingSegments: segments,
            existingModDates: segmentModificationDates
        )
        applyOperationResult(result)
    }

    func updateLinkingResult(_ result: LinkingResult) {
        linkingResult = result
        updateModified()

        // Initialize blank rush status for new OCF parents
        for parent in result.parentsWithChildren {
            if blankRushStatus[parent.ocf.fileName] == nil {
                // Check if blank rush file already exists on disk
                if blankRushFileExists(for: parent.ocf.fileName) {
                    let baseName = (parent.ocf.fileName as NSString).deletingPathExtension
                    let blankRushFileName = "\(baseName)_BlankRush.mov"
                    let blankRushURL = blankRushDirectory.appendingPathComponent(blankRushFileName)
                    blankRushStatus[parent.ocf.fileName] = .completed(
                        date: Date(), url: blankRushURL)
                } else {
                    blankRushStatus[parent.ocf.fileName] = .notCreated
                }
            }
        }
    }

    func updateBlankRushStatus(ocfFileName: String, status: BlankRushStatus) {
        blankRushStatus[ocfFileName] = status
        updateModified()
    }

    func addPrintRecord(_ record: PrintRecord) {
        printHistory.append(record)
        lastPrintDate = record.date
        updateModified()
    }

    /// Check for modified segments and automatically update print status to needsReprint
    func checkForModifiedSegmentsAndUpdatePrintStatus() {
        // Convert print status to format expected by service
        let statusForService = printStatus.mapValues { status -> (Bool, Date?, URL?) in
            switch status {
            case .printed(let date, let url):
                return (true, date, url)
            case .needsReprint(let date, _):
                return (true, date, nil)
            case .notPrinted:
                return (false, nil, nil)
            }
        }

        let (needsReprint, statusChanged) = ProjectOperations.checkForModifiedSegments(
            linkingResult: linkingResult,
            existingPrintStatus: statusForService
        )

        // Apply reprint flags
        for (ocfFileName, lastPrintDate) in needsReprint {
            printStatus[ocfFileName] = .needsReprint(
                lastPrintDate: lastPrintDate,
                reason: .segmentModified
            )
        }

        if statusChanged {
            updateModified()
        }
    }

    /// Refresh print status for all OCFs - useful to call when project is loaded or segments are updated
    func refreshPrintStatus() {
        checkForModifiedSegmentsAndUpdatePrintStatus()
    }

    /// Remove OCF files by filename
    func removeOCFFiles(_ fileNames: [String]) {
        // Convert blank rush status to strings for service
        let blankRushStatusStrings = blankRushStatus.mapValues { _ in "status" }

        let result = ProjectOperations.removeOCFFiles(
            fileNames,
            existingOCFs: ocfFiles,
            existingBlankRushStatus: blankRushStatusStrings
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            linkingResult = nil
        }
    }

    /// Remove segments by filename
    func removeSegments(_ fileNames: [String]) {
        let result = ProjectOperations.removeSegments(
            fileNames,
            existingSegments: segments,
            existingModDates: segmentModificationDates,
            existingFileSizes: segmentFileSizes,
            existingOfflineFiles: offlineMediaFiles
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            linkingResult = nil
        }
    }

    /// Remove all offline media files from the project
    func removeOfflineMedia() {
        // Convert status dictionaries to strings for service
        let printStatusStrings = printStatus.mapValues { _ in "status" }
        let blankRushStatusStrings = blankRushStatus.mapValues { _ in "status" }

        let result = ProjectOperations.removeOfflineMedia(
            offlineFiles: offlineMediaFiles,
            existingOCFs: ocfFiles,
            existingSegments: segments,
            existingModDates: segmentModificationDates,
            existingFileSizes: segmentFileSizes,
            existingPrintStatus: printStatusStrings,
            existingBlankRushStatus: blankRushStatusStrings,
            existingOfflineMetadata: offlineFileMetadata
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            linkingResult = nil
        }
    }

    /// Toggle VFX status for OCF file
    func toggleOCFVFXStatus(_ fileName: String, isVFX: Bool) {
        let result = ProjectOperations.toggleOCFVFXStatus(
            fileName,
            isVFX: isVFX,
            existingOCFs: ocfFiles
        )
        applyOperationResult(result)
    }

    /// Toggle VFX status for segment file
    func toggleSegmentVFXStatus(_ fileName: String, isVFX: Bool) {
        let result = ProjectOperations.toggleSegmentVFXStatus(
            fileName,
            isVFX: isVFX,
            existingSegments: segments
        )
        applyOperationResult(result)
    }

    /// Apply ProjectOperationResult to @Published properties
    private func applyOperationResult(_ result: ProjectOperationResult) {
        if let updated = result.ocfFiles {
            ocfFiles = updated
        }

        if let updated = result.segments {
            segments = updated
        }

        if let updated = result.segmentModificationDates {
            segmentModificationDates = updated
        }

        if let updated = result.segmentFileSizes {
            segmentFileSizes = updated
        }

        if let updated = result.offlineFiles {
            offlineMediaFiles = updated
        }

        if let updated = result.offlineMetadata {
            offlineFileMetadata = updated
        }

        // Note: printStatus and blankRushStatus are handled separately in calling methods
        // because they have complex enum types that the service doesn't know about

        if result.shouldUpdateModified {
            updateModified()
        }
    }

    /// Scan for existing blank rush files and update status accordingly
    func scanForExistingBlankRushes() {
        guard let linkingResult = linkingResult else { return }

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: blankRushDirectory
        )

        for (ocfFileName, url) in found {
            // Only update if we don't already have a status or if it's marked as not created
            if blankRushStatus[ocfFileName] == nil || blankRushStatus[ocfFileName] == .notCreated {
                blankRushStatus[ocfFileName] = .completed(date: Date(), url: url)
            }
        }

        updateModified()
    }

    // MARK: - Watch Folder Monitoring

    // MARK: - WatchFolderDelegate

    func watchFolder(_ service: WatchFolderService, didDetectNewFiles files: [URL], isVFX: Bool) {
        // Process detected files using AutoImportService
        let result = AutoImportService.processDetectedFiles(
            files: files,
            isVFX: isVFX,
            existingSegments: segments,
            offlineFiles: offlineMediaFiles,
            offlineMetadata: offlineFileMetadata,
            trackedSizes: segmentFileSizes,
            linkingResult: linkingResult,
            autoImportEnabled: watchFolderSettings.autoImportEnabled
        )

        // Apply state changes
        applyAutoImportResult(result)

        // Import new files if any
        if !result.filesToImport.isEmpty {
            Task {
                let mediaFiles = await analyzeDetectedFiles(urls: result.filesToImport, isVFX: isVFX)
                await MainActor.run {
                    addSegments(mediaFiles)
                    NSLog(
                        "✅ Auto-imported %d new %@ files from watch folder",
                        mediaFiles.count, isVFX ? "VFX" : "grade")
                }
            }
        }
    }

    func watchFolder(_ service: WatchFolderService, didDetectDeletedFiles fileNames: [String], isVFX: Bool) {
        let result = AutoImportService.processDeletedFiles(
            fileNames: fileNames,
            isVFX: isVFX,
            existingSegments: segments,
            trackedSizes: segmentFileSizes,
            linkingResult: linkingResult
        )

        applyAutoImportResult(result)
    }

    func watchFolder(_ service: WatchFolderService, didDetectModifiedFiles fileNames: [String], isVFX: Bool) {
        let result = AutoImportService.processModifiedFiles(
            fileNames: fileNames,
            isVFX: isVFX,
            existingSegments: segments,
            linkingResult: linkingResult
        )

        applyAutoImportResult(result)
    }

    func watchFolder(_ service: WatchFolderService, didEncounterError error: WatchFolderError) {
        NSLog("⚠️ Watch folder error: %@", error.localizedDescription)
    }

    /// Apply AutoImportResult to @Published properties
    private func applyAutoImportResult(_ result: AutoImportResult) {
        // Remove offline status for returning files
        for fileName in result.offlineFiles {
            offlineMediaFiles.remove(fileName)
        }

        // Remove offline metadata
        for fileName in result.offlineMetadata.keys {
            offlineFileMetadata.removeValue(forKey: fileName)
        }

        // Add new offline files
        for fileName in result.offlineFiles {
            if !offlineMediaFiles.contains(fileName) {
                offlineMediaFiles.insert(fileName)
            }
        }

        // Add new offline metadata
        for (fileName, metadata) in result.offlineMetadata where metadata != nil {
            offlineFileMetadata[fileName] = metadata
        }

        // Update modification dates
        for (fileName, date) in result.modificationDates {
            segmentModificationDates[fileName] = date
        }

        // Update file sizes
        for (fileName, size) in result.updatedFileSizes {
            segmentFileSizes[fileName] = size
        }

        // Update print status for affected OCFs
        for (ocfFileName, update) in result.printStatusUpdates {
            if update.needsReprint {
                let lastPrintDate = update.lastPrintDate ?? Date()
                let reason: ReprintReason = update.reason == "segmentOffline" ? .segmentOffline : .segmentModified
                printStatus[ocfFileName] = .needsReprint(lastPrintDate: lastPrintDate, reason: reason)
            }
        }

        // Trigger UI update if changes were made
        if result.modifiedFiles.count > 0 || result.offlineFiles.count > 0 || !result.printStatusUpdates.isEmpty {
            objectWillChange.send()
        }
    }

    // MARK: - Watch Folder Lifecycle

    private func updateWatchFolderMonitoring() {
        NSLog(
            "🔄 Watch folder settings changed: enabled=%@",
            watchFolderSettings.isEnabled ? "true" : "false")

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
        if let gradePath = gradePath {
            NSLog("📁 Grade folder: %@", gradePath)
        }
        if let vfxPath = vfxPath {
            NSLog("🎬 VFX folder: %@", vfxPath)
        }

        watchFolderService = WatchFolderService(gradePath: gradePath, vfxPath: vfxPath)
        watchFolderService?.delegate = self

        // Check for files that changed while app was closed BEFORE starting monitor
        // This prevents duplicate imports (startup scan vs real-time detection)
        checkForChangedFilesOnStartup(gradePath: gradePath, vfxPath: vfxPath)
    }

    /// Check if any already-imported files in watch folders have changed while app was closed
    /// Also scans for new files added while app was closed
    private func checkForChangedFilesOnStartup(gradePath: String?, vfxPath: String?) {
        guard let service = watchFolderService else { return }

        // Process startup changes using AutoImportService
        Task {
            let (modificationsResult, newFiles) = await AutoImportService.processStartupChanges(
                service: service,
                existingSegments: segments,
                trackedSizes: segmentFileSizes,
                linkingResult: linkingResult,
                autoImportEnabled: watchFolderSettings.autoImportEnabled
            )

            // Apply modifications on main actor
            await MainActor.run {
                applyAutoImportResult(modificationsResult)
            }

            // Auto-import new grade files (WAIT for completion)
            if !newFiles.gradeFiles.isEmpty && watchFolderSettings.autoImportEnabled {
                NSLog("🎬 Auto-importing %d new grade files from startup scan...", newFiles.gradeFiles.count)
                let gradeMediaFiles = await analyzeDetectedFiles(urls: newFiles.gradeFiles, isVFX: false)
                await MainActor.run {
                    addSegments(gradeMediaFiles)
                    NSLog("✅ Startup import complete: %d grade files", gradeMediaFiles.count)
                }
            }

            // Auto-import new VFX files (WAIT for completion)
            if !newFiles.vfxFiles.isEmpty && watchFolderSettings.autoImportEnabled {
                NSLog("🎬 Auto-importing %d new VFX files from startup scan...", newFiles.vfxFiles.count)
                let vfxMediaFiles = await analyzeDetectedFiles(urls: newFiles.vfxFiles, isVFX: true)
                await MainActor.run {
                    addSegments(vfxMediaFiles)
                    NSLog("✅ Startup import complete: %d VFX files", vfxMediaFiles.count)
                }
            }

            // NOW start the file monitor (after startup import FULLY completes)
            await MainActor.run {
                service.startMonitoring()
                NSLog("✅ Watch folder monitoring active")
            }
        }
    }

    private func stopWatchFolder() {
        watchFolderService?.stopMonitoring()
        watchFolderService = nil
    }

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
                NSLog(
                    "❌ Failed to analyze watch folder file %@: %@", url.lastPathComponent,
                    error.localizedDescription)
            }
        }

        NSLog("✅ Analysis complete: %d/%d files analyzed successfully", results.count, urls.count)
        return results
    }

}

// MARK: - Supporting Types

// BlankRushStatus now imported from SourcePrintCore

struct PrintRecord: Codable, Identifiable {
    let id: UUID
    let date: Date
    let outputURL: URL
    let segmentCount: Int
    let duration: TimeInterval
    let success: Bool

    init(date: Date, outputURL: URL, segmentCount: Int, duration: TimeInterval, success: Bool) {
        self.id = UUID()
        self.date = date
        self.outputURL = outputURL
        self.segmentCount = segmentCount
        self.duration = duration
        self.success = success
    }

    var statusIcon: String {
        success ? "✅" : "❌"
    }
}

// MARK: - Render Queue System

struct RenderQueueItem: Codable, Identifiable {
    let id: UUID
    let ocfFileName: String
    let addedDate: Date
    var status: RenderQueueStatus

    init(ocfFileName: String) {
        self.id = UUID()
        self.ocfFileName = ocfFileName
        self.addedDate = Date()
        self.status = .queued
    }
}

enum RenderQueueStatus: String, Codable, CaseIterable {
    case queued = "queued"
    case rendering = "rendering"
    case completed = "completed"
    case failed = "failed"

    var displayName: String {
        switch self {
        case .queued: return "Queued"
        case .rendering: return "Rendering"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var icon: String {
        switch self {
        case .queued: return "clock"
        case .rendering: return "gear"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .queued: return AppTheme.queued
        case .rendering: return AppTheme.rendering
        case .completed: return AppTheme.completed
        case .failed: return AppTheme.failed
        }
    }
}

// PrintStatus now imported from SourcePrintCore

// UI-specific extensions for PrintStatus
extension PrintStatus {
    var icon: String {
        return statusIcon  // Use Core's statusIcon property
    }

    var color: Color {
        switch self {
        case .notPrinted: return AppTheme.notPrinted
        case .printed: return AppTheme.printed
        case .needsReprint: return AppTheme.needsReprint
        }
    }
}

// ReprintReason now imported from SourcePrintCore

// MARK: - Extensions

extension DateFormatter {
    static let short: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
