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
class ProjectViewModel: ObservableObject, Codable, Identifiable {

    @Published var isPublishing = false
    @Published var mediaRefreshNotice: String? {
        didSet { mediaRefreshDetails = [] }
    }
    @Published var mediaRefreshDetails: [String] = []
    @Published var mediaReviewURLs: Set<URL> = []
    @Published var mediaReviewRequestID: UUID?
    @Published var unavailableGradeURLs: Set<URL> = []
    private var missingGradeURLs: Set<URL> = []
    private var availabilityNotice: String?
    private var relinkAfterMediaRefresh = false

    /// Clear only missing-file failures after reconnection; metadata is still checked on link/render.
    @MainActor
    func updateGradeAvailability(checkedURLs: Set<URL>, unavailableURLs: Set<URL>) {
        let recovered = missingGradeURLs.intersection(checkedURLs).subtracting(unavailableURLs)
        guard !recovered.isEmpty else { return }
        missingGradeURLs.subtract(recovered)
        unavailableGradeURLs.subtract(recovered)
        if mediaRefreshNotice == availabilityNotice {
            setAvailabilityNotice(offlineCount: missingGradeURLs.count, failures: mediaRefreshDetails)
        }
    }

    private func setAvailabilityNotice(offlineCount: Int, failures: [String]) {
        var messages: [String] = []
        if offlineCount > 0 {
            messages.append("\(offlineCount) \(offlineCount == 1 ? "clip is" : "clips are") offline. Reconnect the files before linking.")
        }
        if !failures.isEmpty {
            messages.append("\(failures.count) \(failures.count == 1 ? "clip could" : "clips could") not be read. Review the details before linking.")
        }
        mediaRefreshNotice = messages.isEmpty ? nil : messages.joined(separator: " ")
        mediaRefreshDetails = failures
        availabilityNotice = mediaRefreshNotice
    }
    private var mediaRefreshTask: Task<Bool, Never>?

    @MainActor
    func refreshGradedMedia() async -> Bool {
        if let task = mediaRefreshTask { return await task.value }
        let task = Task { @MainActor in
            let snapshot = model.segments
            let previousNotice = mediaRefreshNotice
            var changed = false
            var failures: [String] = []
            var missing: Set<URL> = []
            var unavailable: Set<URL> = []
            for original in snapshot {
                do {
                    let refreshed = try await SourceMediaRefresh.refresh(original)
                    guard let index = model.segments.firstIndex(where: { $0.url == original.url }) else { continue }
                    if refreshed.analyzedFingerprint != original.analyzedFingerprint {
                        let metadataChanged = refreshed.durationInFrames != original.durationInFrames || refreshed.sourceTimecode != original.sourceTimecode || refreshed.resolution != original.resolution || refreshed.frameRateFloat != original.frameRateFloat
                        if original.analyzedFingerprint != nil || metadataChanged {
                            for parent in model.linkingResult?.ocfParents ?? [] where parent.children.contains(where: { $0.segment.url == original.url }) {
                                model.invalidatedRenderURLs.insert(parent.ocf.url)
                                if case .printed(let date, _) = model.printStatus[parent.ocf.fileName] {
                                    model.printStatus[parent.ocf.fileName] = .needsReprint(lastPrintDate: date, reason: .segmentModified)
                                }
                            }
                        }
                        var replacement = refreshed
                        replacement.isVFXShot = model.segments[index].isVFXShot
                        model.segments[index] = replacement
                        if metadataChanged {
                            model.manualLinkOverrides.removeValue(forKey: original.fileName)
                            model.manualLinkPaths.removeValue(forKey: SegmentOCFLinker.fileKey(original.url))
                        }
                        changed = true
                    }
                } catch {
                    unavailable.insert(original.url)
                    let nsError = error as NSError
                    if nsError.domain == NSCocoaErrorDomain &&
                        (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError) {
                        missing.insert(original.url)
                    } else {
                        failures.append("\(original.fileName): \(error.localizedDescription)")
                    }
                }
            }
            missingGradeURLs = missing
            unavailableGradeURLs = unavailable
            if !unavailable.isEmpty {
                relinkAfterMediaRefresh = relinkAfterMediaRefresh || model.linkingResult != nil
                model.linkingResult = nil
                setAvailabilityNotice(offlineCount: missing.count, failures: failures)
            } else {
                mediaRefreshNotice = nil
                if (changed && model.linkingResult != nil) || relinkAfterMediaRefresh {
                    relinkAfterMediaRefresh = false
                    updateLinkingResult(SegmentOCFLinker().linkSegments(model.segments,
                        withOCFParents: model.ocfFiles, manualPathOverrides: model.manualLinkPaths))
                }
            }
            if changed || previousNotice != mediaRefreshNotice { model.updateModified() }
            return unavailable.isEmpty
        }
        mediaRefreshTask = task
        let success = await task.value
        mediaRefreshTask = nil
        return success
    }

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

    /// Legacy persistence only. Folder monitoring has been retired.
    var watchFolderSettings: WatchFolderSettings = WatchFolderSettings()

    /// Set to true by the Link Files button to trigger linking once LinkingTab appears
    var pendingLinkRequest: Bool = false

    /// Callback for manual linking (set by LinkingTab)
    var performLinkingCallback: (() -> Void)?

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
        model.printHistory.forEach(indexPrint)
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
        model.printHistory.forEach(indexPrint)
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

    // MARK: - Manual Link Overrides

    /// Add or update a manual link override for a segment
    @discardableResult
    func setManualLinkOverride(segmentURL: URL, ocfURL: URL) -> Bool {
        guard let segment = model.segments.first(where: { $0.url == segmentURL }),
              SegmentOCFLinker().validCandidates(for: segment, in: model.ocfFiles).contains(where: { $0.url == ocfURL }) else { return false }
        model.manualLinkPaths[SegmentOCFLinker.fileKey(segmentURL)] = SegmentOCFLinker.fileKey(ocfURL)
        model.manualLinkOverrides.removeValue(forKey: segment.fileName)
        model.updateModified()
        return true
    }

    func removeManualLinkOverride(segmentURL: URL) {
        model.manualLinkPaths.removeValue(forKey: SegmentOCFLinker.fileKey(segmentURL))
        if let segment = model.segments.first(where: { $0.url == segmentURL }) {
            model.manualLinkOverrides.removeValue(forKey: segment.fileName)
        }
        model.updateModified()
    }

    func getManualLinkOverride(segmentURL: URL) -> URL? {
        model.manualLinkPaths[SegmentOCFLinker.fileKey(segmentURL)].map { URL(fileURLWithPath: $0) }
    }

    // Build once when loading saved history, then index each completed render.
    private(set) var latestPrintByOCF: [String: SourcePrintCore.PrintRecord] = [:]

    private func indexPrint(_ record: SourcePrintCore.PrintRecord) {
        if let previous = latestPrintByOCF[record.ocfFileName], previous.date >= record.date { return }
        latestPrintByOCF[record.ocfFileName] = record
    }

    func addPrintRecord(_ record: SourcePrintCore.PrintRecord) {
        indexPrint(record)
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

    func removeOCFFiles(_ urls: Set<URL>) {
        let removedNames = Set(model.ocfFiles.filter { urls.contains($0.url) }.map(\.fileName))
        model.ocfFiles.removeAll { urls.contains($0.url) }
        for name in removedNames.subtracting(model.ocfFiles.map(\.fileName)) {
            model.blankRushStatus.removeValue(forKey: name)
        }
        model.linkingResult = nil
        model.updateModified()
    }

    func removeSegments(_ urls: Set<URL>) {
        let removedNames = Set(model.segments.filter { urls.contains($0.url) }.map(\.fileName))
        model.segments.removeAll { urls.contains($0.url) }
        for name in removedNames.subtracting(model.segments.map(\.fileName)) {
            model.segmentModificationDates.removeValue(forKey: name)
            model.segmentFileSizes.removeValue(forKey: name)
            if !model.ocfFiles.contains(where: { $0.fileName == name }) {
                model.offlineMediaFiles.remove(name)
            }
        }
        model.linkingResult = nil
        model.updateModified()
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
    func toggleSegmentVFXStatus(_ url: URL, isVFX: Bool) {
        guard let index = model.segments.firstIndex(where: { $0.url == url }) else { return }
        model.segments[index].isVFXShot = isVFX
        model.updateModified()
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
}
