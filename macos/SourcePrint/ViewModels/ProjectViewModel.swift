//
//  ProjectViewModel.swift
//  SourcePrint
//
//  Created by Claude on 31/10/2025.
//
//  Phase 5A: Full ViewModel Split - SwiftUI reactive wrapper around ProjectModel

import CryptoKit
import Foundation
import SourcePrintCore
import SwiftUI

/// SwiftUI-reactive ViewModel wrapping the pure ProjectModel from Core
/// Handles all UI state management and delegates business logic to Core services
class ProjectViewModel: ObservableObject, Codable, Identifiable, WatchFolderDelegate {

    // MARK: - File Format Version

    /// File format version for future migrations
    /// Current version: 1
    /// Increment this when making breaking changes to the .w2 file structure
    static let currentFileFormatVersion = 1
    var fileFormatVersion: Int = ProjectViewModel.currentFileFormatVersion

    // MARK: - Core Data Model

    /// Single source of truth for project data
    /// internal(set) allows ProjectManager to mutate, views observe via @Published
    @Published internal(set) var model: ProjectModel

    // MARK: - UI-Specific State

    /// Render queue (UI-only, not persisted in Core model)
    /// Uses Core's RenderQueueItem (Codable version for persistence)
    @Published var renderQueue: [SourcePrintCore.RenderQueueItem] = []

    /// OCF card expansion state (UI-only)
    @Published var ocfCardExpansionState: [String: Bool] = [:]

    /// Watch folder settings (UI-only)
    @Published var watchFolderSettings: WatchFolderSettings = WatchFolderSettings() {
        didSet {
            updateWatchFolderMonitoring()
        }
    }

    /// Project validation result (UI-only, not persisted)
    @Published var validationResult: ProjectValidationResult?

    /// Callback for automatic linking (set by LinkingTab)
    var autoLinkingCallback: (() -> Void)?

    /// Watch folder service instance
    private var watchFolderService: WatchFolderService?

    // MARK: - Computed Properties (Delegate to Model)

    var id: UUID { model.id }
    var hasLinkedMedia: Bool { model.hasLinkedMedia }
    var readyForBlankRush: Bool { model.readyForBlankRush }
    var blankRushProgress: (completed: Int, total: Int) { model.blankRushProgress }
    var hasModifiedSegments: Bool { model.hasModifiedSegments }
    var modifiedSegments: [(fileName: String, fileModDate: Date, trackedModDate: Date)] {
        model.modifiedSegments
    }

    /// Check if blank rush file exists on disk for given OCF filename
    func blankRushFileExists(for ocfFileName: String) -> Bool {
        let baseName = (ocfFileName as NSString).deletingPathExtension
        let blankRushFileName = "\(baseName)_blankRush.mov"
        let blankRushURL = model.blankRushDirectory.appendingPathComponent(blankRushFileName)
        return FileManager.default.fileExists(atPath: blankRushURL.path)
    }

    // MARK: - Initialization

    /// Create new project with ViewModel
    init(name: String, outputDirectory: URL, blankRushDirectory: URL) {
        self.model = ProjectModel(
            name: name,
            outputDirectory: outputDirectory,
            blankRushDirectory: blankRushDirectory
        )
    }

    /// Wrap existing ProjectModel
    init(model: ProjectModel, renderQueue: [SourcePrintCore.RenderQueueItem] = [], ocfCardExpansionState: [String: Bool] = [:], watchFolderSettings: WatchFolderSettings = WatchFolderSettings()) {
        self.model = model
        self.renderQueue = renderQueue
        self.ocfCardExpansionState = ocfCardExpansionState
        self.watchFolderSettings = watchFolderSettings
    }

    // MARK: - Codable Implementation
    // Uses ProjectContainer from Core for cross-platform compatibility

    required init(from decoder: Decoder) throws {
        // Decode using cross-platform ProjectContainer
        let projectContainer = try ProjectContainer(from: decoder)

        // Initialize from container
        self.fileFormatVersion = projectContainer.fileFormatVersion
        self.model = projectContainer.model
        self.renderQueue = projectContainer.renderQueue
        self.ocfCardExpansionState = projectContainer.ocfCardExpansionState
        self.watchFolderSettings = projectContainer.watchFolderSettings
    }

    func encode(to encoder: Encoder) throws {
        // Create ProjectContainer and encode
        let projectContainer = ProjectContainer(
            fileFormatVersion: fileFormatVersion,
            model: model,
            renderQueue: renderQueue,
            ocfCardExpansionState: ocfCardExpansionState,
            watchFolderSettings: watchFolderSettings
        )
        try projectContainer.encode(to: encoder)
    }

    // MARK: - Project Management Methods

    func updateModified() {
        model.updateModified()
    }

    func addOCFFiles(_ files: [MediaFileInfo]) {
        let result = ProjectOperations.addOCFFiles(files, existingOCFs: model.ocfFiles)
        applyOperationResult(result)
    }

    func addSegments(_ newSegments: [MediaFileInfo]) {
        let result = ProjectOperations.addSegments(
            newSegments,
            existingSegments: model.segments,
            existingFileSizes: model.segmentFileSizes
        )
        applyOperationResult(result)
    }

    /// Update modification dates for all segments (useful for refresh)
    func refreshSegmentModificationDates() {
        let result = ProjectOperations.refreshSegmentModificationDates(
            existingSegments: model.segments,
            existingModDates: model.segmentModificationDates
        )
        applyOperationResult(result)
    }

    func updateLinkingResult(_ result: LinkingResult) {
        model.linkingResult = result
        model.updateModified()

        // Initialize blank rush status for new OCF parents
        for parent in result.parentsWithChildren {
            if model.blankRushStatus[parent.ocf.fileName] == nil {
                // Check if blank rush file already exists on disk
                if blankRushFileExists(for: parent.ocf.fileName) {
                    let baseName = (parent.ocf.fileName as NSString).deletingPathExtension
                    let blankRushFileName = "\(baseName)_BlankRush.mov"
                    let blankRushURL = model.blankRushDirectory.appendingPathComponent(blankRushFileName)
                    model.blankRushStatus[parent.ocf.fileName] = .completed(date: Date(), url: blankRushURL)
                } else {
                    model.blankRushStatus[parent.ocf.fileName] = .notCreated
                }
            }
        }
    }

    func updateBlankRushStatus(ocfFileName: String, status: BlankRushStatus) {
        model.blankRushStatus[ocfFileName] = status
        model.updateModified()
    }

    func addPrintRecord(_ record: SourcePrintCore.PrintRecord) {
        // Directly append Core PrintRecord
        model.printHistory.append(record)
        model.lastPrintDate = record.date
        model.updateModified()
    }

    /// Check for modified segments and automatically update print status to needsReprint
    func checkForModifiedSegmentsAndUpdatePrintStatus() {
        // Convert print status to format expected by service
        let statusForService = model.printStatus.mapValues { status -> (Bool, Date?, URL?) in
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
            linkingResult: model.linkingResult,
            existingPrintStatus: statusForService
        )

        // Apply reprint flags
        for (ocfFileName, lastPrintDate) in needsReprint {
            model.printStatus[ocfFileName] = .needsReprint(
                lastPrintDate: lastPrintDate,
                reason: .segmentModified
            )
        }

        if statusChanged {
            model.updateModified()
        }
    }

    /// Refresh print status for all OCFs
    func refreshPrintStatus() {
        checkForModifiedSegmentsAndUpdatePrintStatus()
    }

    /// Remove OCF files by filename
    func removeOCFFiles(_ fileNames: [String]) {
        // Convert blank rush status to strings for service
        let blankRushStatusStrings = model.blankRushStatus.mapValues { _ in "status" }

        let result = ProjectOperations.removeOCFFiles(
            fileNames,
            existingOCFs: model.ocfFiles,
            existingBlankRushStatus: blankRushStatusStrings
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            model.linkingResult = nil
        }
    }

    /// Remove segments by filename
    func removeSegments(_ fileNames: [String]) {
        let result = ProjectOperations.removeSegments(
            fileNames,
            existingSegments: model.segments,
            existingModDates: model.segmentModificationDates,
            existingFileSizes: model.segmentFileSizes,
            existingOfflineFiles: model.offlineMediaFiles
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            model.linkingResult = nil
        }
    }

    /// Remove all offline media files from the project
    func removeOfflineMedia() {
        // Convert status dictionaries to strings for service
        let printStatusStrings = model.printStatus.mapValues { _ in "status" }
        let blankRushStatusStrings = model.blankRushStatus.mapValues { _ in "status" }

        let result = ProjectOperations.removeOfflineMedia(
            offlineFiles: model.offlineMediaFiles,
            existingOCFs: model.ocfFiles,
            existingSegments: model.segments,
            existingModDates: model.segmentModificationDates,
            existingFileSizes: model.segmentFileSizes,
            existingPrintStatus: printStatusStrings,
            existingBlankRushStatus: blankRushStatusStrings,
            existingOfflineMetadata: model.offlineFileMetadata
        )

        applyOperationResult(result)

        // Invalidate linking if needed
        if result.shouldInvalidateLinking {
            model.linkingResult = nil
        }
    }

    /// Toggle VFX status for OCF file
    func toggleOCFVFXStatus(_ fileName: String, isVFX: Bool) {
        let result = ProjectOperations.toggleOCFVFXStatus(
            fileName,
            isVFX: isVFX,
            existingOCFs: model.ocfFiles
        )
        applyOperationResult(result)
    }

    /// Toggle VFX status for segment file
    func toggleSegmentVFXStatus(_ fileName: String, isVFX: Bool) {
        let result = ProjectOperations.toggleSegmentVFXStatus(
            fileName,
            isVFX: isVFX,
            existingSegments: model.segments
        )
        applyOperationResult(result)
    }

    /// Apply ProjectOperationResult to model
    private func applyOperationResult(_ result: ProjectOperationResult) {
        if let updated = result.ocfFiles {
            model.ocfFiles = updated
        }

        if let updated = result.segments {
            model.segments = updated
        }

        if let updated = result.segmentModificationDates {
            model.segmentModificationDates = updated
        }

        if let updated = result.segmentFileSizes {
            model.segmentFileSizes = updated
        }

        if let updated = result.offlineFiles {
            model.offlineMediaFiles = updated
        }

        if let updated = result.offlineMetadata {
            model.offlineFileMetadata = updated
        }

        if result.shouldUpdateModified {
            model.updateModified()
        }
    }

    /// Scan for existing blank rush files and update status accordingly
    func scanForExistingBlankRushes() {
        guard let linkingResult = model.linkingResult else { return }

        let found = BlankRushScanner.scanForExistingBlankRushes(
            linkingResult: linkingResult,
            blankRushDirectory: model.blankRushDirectory
        )

        for (ocfFileName, url) in found {
            // Only update if we don't already have a status or if it's marked as not created
            if model.blankRushStatus[ocfFileName] == nil || model.blankRushStatus[ocfFileName] == .notCreated {
                model.blankRushStatus[ocfFileName] = .completed(date: Date(), url: url)
            }
        }

        model.updateModified()
    }

    // MARK: - WatchFolderDelegate

    func watchFolder(_ service: WatchFolderService, didDetectNewFiles files: [URL], isVFX: Bool) {
        // Process detected files using AutoImportService
        let result = AutoImportService.processDetectedFiles(
            files: files,
            isVFX: isVFX,
            existingSegments: model.segments,
            offlineFiles: model.offlineMediaFiles,
            offlineMetadata: model.offlineFileMetadata,
            trackedSizes: model.segmentFileSizes,
            linkingResult: model.linkingResult,
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
                    NSLog("✅ Auto-imported %d new %@ files from watch folder", mediaFiles.count, isVFX ? "VFX" : "grade")

                    // Trigger automatic linking after import
                    autoLinkingCallback?()
                }
            }
        }
    }

    func watchFolder(_ service: WatchFolderService, didDetectDeletedFiles fileNames: [String], isVFX: Bool) {
        let result = AutoImportService.processDeletedFiles(
            fileNames: fileNames,
            isVFX: isVFX,
            existingSegments: model.segments,
            trackedSizes: model.segmentFileSizes,
            linkingResult: model.linkingResult
        )

        applyAutoImportResult(result)
    }

    func watchFolder(_ service: WatchFolderService, didDetectModifiedFiles fileNames: [String], isVFX: Bool) {
        let result = AutoImportService.processModifiedFiles(
            fileNames: fileNames,
            isVFX: isVFX,
            existingSegments: model.segments,
            linkingResult: model.linkingResult
        )

        applyAutoImportResult(result)
    }

    func watchFolder(_ service: WatchFolderService, didEncounterError error: WatchFolderError) {
        NSLog("⚠️ Watch folder error: %@", error.localizedDescription)
    }

    /// Apply AutoImportResult to model
    private func applyAutoImportResult(_ result: AutoImportResult) {
        // Remove offline status for returning files
        for fileName in result.offlineFiles {
            model.offlineMediaFiles.remove(fileName)
        }

        // Remove offline metadata
        for fileName in result.offlineMetadata.keys {
            model.offlineFileMetadata.removeValue(forKey: fileName)
        }

        // Add new offline files
        for fileName in result.offlineFiles {
            if !model.offlineMediaFiles.contains(fileName) {
                model.offlineMediaFiles.insert(fileName)
            }
        }

        // Add new offline metadata
        for (fileName, metadata) in result.offlineMetadata where metadata != nil {
            model.offlineFileMetadata[fileName] = metadata
        }

        // Update modification dates
        for (fileName, date) in result.modificationDates {
            model.segmentModificationDates[fileName] = date
        }

        // Update file sizes
        for (fileName, size) in result.updatedFileSizes {
            model.segmentFileSizes[fileName] = size
        }

        // Update print status for affected OCFs
        for (ocfFileName, update) in result.printStatusUpdates {
            if update.needsReprint {
                let lastPrintDate = update.lastPrintDate ?? Date()
                let reason: ReprintReason = update.reason == "segmentOffline" ? .segmentOffline : .segmentModified
                model.printStatus[ocfFileName] = .needsReprint(lastPrintDate: lastPrintDate, reason: reason)
            }
        }

        // Trigger UI update if changes were made
        if result.modifiedFiles.count > 0 || result.offlineFiles.count > 0 || !result.printStatusUpdates.isEmpty {
            objectWillChange.send()
        }
    }

    // MARK: - Watch Folder Lifecycle

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
        if let gradePath = gradePath {
            NSLog("📁 Grade folder: %@", gradePath)
        }
        if let vfxPath = vfxPath {
            NSLog("🎬 VFX folder: %@", vfxPath)
        }

        watchFolderService = WatchFolderService(gradePath: gradePath, vfxPath: vfxPath)
        watchFolderService?.delegate = self

        // Check for files that changed while app was closed BEFORE starting monitor
        checkForChangedFilesOnStartup(gradePath: gradePath, vfxPath: vfxPath)
    }

    /// Check if any already-imported files in watch folders have changed while app was closed
    private func checkForChangedFilesOnStartup(gradePath: String?, vfxPath: String?) {
        guard let service = watchFolderService else { return }

        // Process startup changes using AutoImportService
        Task {
            let (modificationsResult, newFiles) = await AutoImportService.processStartupChanges(
                service: service,
                existingSegments: model.segments,
                trackedSizes: model.segmentFileSizes,
                linkingResult: model.linkingResult,
                autoImportEnabled: watchFolderSettings.autoImportEnabled
            )

            // Apply modifications on main actor
            await MainActor.run {
                applyAutoImportResult(modificationsResult)
            }

            // Auto-import new grade files
            if !newFiles.gradeFiles.isEmpty && watchFolderSettings.autoImportEnabled {
                NSLog("🎬 Auto-importing %d new grade files from startup scan...", newFiles.gradeFiles.count)
                let gradeMediaFiles = await analyzeDetectedFiles(urls: newFiles.gradeFiles, isVFX: false)
                await MainActor.run {
                    addSegments(gradeMediaFiles)
                    NSLog("✅ Startup import complete: %d grade files", gradeMediaFiles.count)
                }
            }

            // Auto-import new VFX files
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

        // Process files serially to avoid potential MediaAnalyzer threading issues
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
}
