//
//  LinkingResultsView.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import AVFoundation
import CoreMedia
import SourcePrintCore
import SwiftUI
import TimecodeKit

extension Notification.Name {
    static let renderOCF = Notification.Name("renderOCF")
}

// MARK: - Helper Functions

/// Format linkMethod string into user-friendly badge labels
func formatLinkMethodBadges(_ linkMethod: String) -> [String] {
    let criteria = linkMethod.split(separator: "+").map(String.init)
    return criteria.map { criterion in
        switch criterion {
        case "resolution": return "Resolution"
        case "fps": return "FPS"
        case "filename_contains": return "Filename"
        case "timecode_range": return "Timecode"
        case "reel": return "Reel"
        case "vfx_exemption": return "VFX"
        case "consumer_camera": return "Consumer"
        default: return criterion.capitalized
        }
    }
}

/// Sort segments chronologically by start timecode
func sortedByTimecode(_ segments: [LinkedSegment]) -> [LinkedSegment] {
    return segments.sorted { seg1, seg2 in
        guard let tc1 = seg1.segment.sourceTimecode,
            let tc2 = seg2.segment.sourceTimecode
        else {
            // If no timecode, maintain original order
            return false
        }
        // Timecode strings sort correctly lexicographically (HH:MM:SS:FF or HH:MM:SS;FF)
        return tc1 < tc2
    }
}

struct LinkingResultsView: View {
    @ObservedObject var project: ProjectViewModel
    @Binding var selectedTab: ProjectTab
    let timelineVisualizationData: [String: TimelineVisualization]
    @EnvironmentObject var projectManager: ProjectManager
    @Environment(StatusBarViewModel.self) private var statusBarVM
    var onPerformLinking: (() -> Void)? = nil
    var onGenerateBlankRushes: (() -> Void)? = nil
    var onCancelBlankRushes: (() -> Void)? = nil

    // Use the project's current linking result instead of a cached copy
    private var linkingResult: LinkingResult? {
        project.model.linkingResult
    }
    @State private var selectedLinkedFiles: Set<String> = []
    @State private var selectedUnmatchedFiles: Set<String> = []
    @State private var selectedOCFParents: Set<URL> = []
    @State private var showUnmatchedDrawer = true
    @State private var showRenderLog = false
    @State private var unmatchedSearch = ""
    @State private var searchText: String = ""

    // Unified navigation state
    enum NavigationContext {
        case ocfList
        case segmentList
    }
    @State private var navigationContext: NavigationContext = .ocfList
    @State private var focusedOCFIndex: Int = 0

    // Render queue manager (from SourcePrintCore)
    @State private var renderQueueManager = RenderQueueManager()

    @State private var currentlyRenderingOCF: String?

    // Computed properties to separate high/medium confidence from low confidence segments
    var confidentlyLinkedParents: [OCFParent] {
        guard let linkingResult = linkingResult else { return [] }
        return linkingResult.ocfParents.compactMap { parent in
            let goodSegments = parent.children.filter { segment in
                segment.linkConfidence == .high || segment.linkConfidence == .medium
            }
            return goodSegments.isEmpty ? nil : OCFParent(ocf: parent.ocf, children: goodSegments)
        }
    }

    var filteredConfidentlyLinkedParents: [OCFParent] {
        if searchText.isEmpty {
            return confidentlyLinkedParents
        } else {
            return confidentlyLinkedParents.filter { parent in
                parent.ocf.fileName.localizedCaseInsensitiveContains(searchText) ||
                    parent.children.contains { $0.segment.fileName.localizedCaseInsensitiveContains(searchText) }
            }
        }
    }

    var lowConfidenceSegments: [LinkedSegment] {
        guard let linkingResult = linkingResult else { return [] }
        return linkingResult.ocfParents.flatMap { parent in
            parent.children.filter { segment in
                segment.linkConfidence == .low
            }
        }
    }

    var totalConfidentSegments: Int {
        return confidentlyLinkedParents.reduce(0) { $0 + $1.childCount }
    }

    var filteredSegmentCount: Int {
        return filteredConfidentlyLinkedParents.reduce(0) { $0 + $1.childCount }
    }

    var totalUnmatchedItems: Int {
        guard let linkingResult = linkingResult else { return 0 }
        return linkingResult.unmatchedOCFs.count + linkingResult.unmatchedSegments.count
            + lowConfidenceSegments.count
    }

    @State private var modifiedURLs: Set<URL> = []

    private var renderableParents: [OCFParent] {
        confidentlyLinkedParents.filter { !project.model.offlineMediaFiles.contains($0.ocf.fileName) }
    }

    private func refreshModifiedJobs() async {
        let model = project.model
        let names = Dictionary(grouping: model.ocfFiles, by: \.fileName)
        var lastSuccess: [URL: Date] = [:]
        for record in model.printHistory where record.success {
            let matches = names[record.ocfFileName]
            guard let url = record.ocfURL ?? (matches?.count == 1 ? matches?.first?.url : nil) else { continue }
            lastSuccess[url] = max(lastSuccess[url] ?? .distantPast, record.date)
        }
        let jobs = renderableParents.compactMap { parent -> (URL, Date, [URL])? in
            var baseline = lastSuccess[parent.ocf.url]
            if baseline == nil, names[parent.ocf.fileName]?.count == 1 {
                switch model.printStatus[parent.ocf.fileName] {
                case .printed(let date, _), .needsReprint(let date, _): baseline = date
                default: break
                }
            }
            guard let baseline else { return nil }
            return (parent.ocf.url, baseline, parent.children.map { $0.segment.url })
        }
        let changed = await Task.detached(priority: .utility) {
            Set(jobs.compactMap { url, date, grades -> URL? in
                let modified = grades.contains { grade in
                    guard case .success(let mtime) = FileSystemOperations.getModificationDate(for: grade) else { return false }
                    return mtime > date
                }
                return modified ? url : nil
            })
        }.value
        guard !Task.isCancelled else { return }
        modifiedURLs = changed.union(model.invalidatedRenderURLs.intersection(Set(jobs.map { $0.0 })))
        updateRenderButtonState()
    }

    // Helper to get selected OCF parents for context menu batch operations
    private func getSelectedParents() -> [OCFParent] {
        return confidentlyLinkedParents.filter { parent in
            selectedOCFParents.contains(parent.ocf.url)
        }
    }

    // Batch render functions - uses RenderQueueManager from SourcePrintCore

    private func renderAll() {
        enqueueFresh(batchName: "Render All") { renderableParents }
    }

    private func renderModified() {
        enqueueFresh(batchName: "Render Modified") {
            renderableParents.filter { modifiedURLs.contains($0.ocf.url) }
        }
    }

    private func renderSelected() {
        enqueueFresh(batchName: "Render Selected") {
            renderableParents.filter { selectedOCFParents.contains($0.ocf.url) }
        }
    }

    private func renderSingle(parent: OCFParent) {
        enqueueFresh(batchName: "Render Job") {
            renderableParents.filter { $0.ocf.url == parent.ocf.url }
        }
    }

    @State private var isCheckingSources = false
    private struct RenderChangeReview: Identifiable {
        let id = UUID()
        let changes: [SourceMediaRefresh.Change]
        let unavailable: [SourceMediaRefresh.Unavailable]
        let review: () -> Void
    }
    @State private var pendingReview: RenderChangeReview?

    private func enqueueFresh(batchName: String, parents: @escaping () -> [OCFParent]) {
        guard !project.isPublishing, !isCheckingSources else { return }
        showRenderLog = true
        isCheckingSources = true
        Task { @MainActor in
            defer { isCheckingSources = false }
            do {
                let inspection = try await SourceMediaRefresh.inspect(project.model.segments)
                let changes = inspection.changes
                if !inspection.canRender || !changes.isEmpty {
                    pendingReview = RenderChangeReview(changes: changes, unavailable: inspection.unavailable) {
                        Task { @MainActor in
                            project.mediaReviewURLs = Set(changes.map(\.id) + inspection.unavailable.map(\.id))
                            project.mediaReviewRequestID = UUID()
                            _ = await project.refreshGradedMedia()
                            projectManager.saveProject(project)
                            selectedTab = .media
                        }
                    }
                    return
                }
                guard !project.isPublishing else { return }
                let requestedSegments = Set(parents().flatMap { $0.children.map { $0.segment.url } })
                await refreshModifiedJobs()
                projectManager.saveProject(project)
                let refreshedParents = parents()
                let availableSegments = Set(refreshedParents.flatMap { $0.children.map { $0.segment.url } })
                guard !refreshedParents.isEmpty, requestedSegments.isSubset(of: availableSegments) else {
                    project.mediaRefreshNotice = "Changed clips no longer match the requested jobs. Review the links before rendering."
                    return
                }
                renderQueueManager.addToQueue(refreshedParents, batchName: batchName)
                renderQueueManager.startProcessing()
            } catch {
                project.mediaRefreshNotice = "Cannot check graded clips: \(error.localizedDescription)"
            }
        }
    }

    private struct SourceChangeRow: Identifiable {
        let url: URL
        let clip: String
        let field: String
        let before: String
        let after: String
        var blocked: Bool = false
        var explanation: String = ""
        var id: String { url.absoluteString + "|" + field }
    }

    private func sourceChangesSheet(_ review: RenderChangeReview) -> some View {
        let blocked = !review.unavailable.isEmpty
        let rows = review.unavailable.map { issue in
            SourceChangeRow(url: issue.id, clip: issue.original.fileName, field: "Availability",
                            before: "Imported", after: issue.status, blocked: true, explanation: issue.message)
        } + review.changes.flatMap { change in
            change.differences.map { difference in
                SourceChangeRow(url: change.id, clip: change.original.fileName,
                                field: difference.field, before: difference.before, after: difference.after)
            }
        }
        return VStack(alignment: .leading, spacing: 16) {
            Label(blocked ? "Graded clips need attention" : "Review graded clips", systemImage: "exclamationmark.triangle.fill")
                .font(.title2)
            Text(blocked
                 ? "Rendering is blocked. Choose Review to locate the highlighted clips in Media and reconnect or replace unavailable files."
                 : "Rendering is paused. Choose Review to refresh the metadata and inspect the highlighted clips in Media before rendering again.")
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("All graded clips are available and up to date.").foregroundStyle(.secondary)
            }
            Table(rows) {
                TableColumn("Clip") { row in
                    Text(row.clip).lineLimit(1).foregroundStyle(row.blocked ? Color.red : Color.primary).help(row.url.path)
                }.width(min: 180, ideal: 250)
                TableColumn("Changed field", value: \.field).width(130)
                TableColumn("Before") { row in
                    Text(row.before).monospacedDigit()
                }.width(min: 110, ideal: 140)
                TableColumn("After") { row in
                    Text(row.after).monospacedDigit().foregroundStyle(row.blocked ? Color.red : Color.primary)
                        .help(row.explanation)
                }.width(min: 110, ideal: 160)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    pendingReview = nil
                }.keyboardShortcut(.cancelAction)
                Button("Review") {
                    pendingReview = nil
                    review.review()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 820, height: 420)
    }

    @State private var candidateChoices: [URL: URL] = [:]
    @State private var inspectedGrade: URL?

    private var effectiveCandidateChoices: [URL: URL] {
        var result: [URL: URL] = [:]
        let linker = SegmentOCFLinker()
        for child in lowConfidenceSegments {
            let grade = child.segment
            if let chosen = candidateChoices[grade.url] {
                // An explicit choice takes precedence, but must still be a valid candidate.
                result[grade.url] = linker.validCandidates(for: grade, in: project.model.ocfFiles)
                    .first(where: { $0.url == chosen })?.url
            } else {
                result[grade.url] = linker.preferredCandidate(for: grade,
                    in: project.model.ocfFiles, folder: project.model.preferredOCFFolder)?.url
            }
        }
        return result
    }

    private var bulkConfirmationPairs: [(segment: URL, ocf: URL)] {
        let choices = effectiveCandidateChoices
        return lowConfidenceSegments.filter { matchesUnmatchedSearch($0.segment) }.compactMap { child in
            guard let candidate = choices[child.segment.url] else { return nil }
            return (child.segment.url, candidate)
        }
    }

    private func choosePreferredOCFFolder() {
        let panel = NSOpenPanel()
        panel.title = "Prefer OCFs from this folder"
        panel.prompt = "Use Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = project.model.preferredOCFFolder
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        project.model.preferredOCFFolder = folder
        project.updateModified()
        projectManager.saveProject(project)
    }

    private var bulkConfirmationControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Prefer Folder…", action: choosePreferredOCFFolder)
                if project.model.preferredOCFFolder != nil {
                    Button("Clear") {
                        project.model.preferredOCFFolder = nil
                        project.updateModified()
                        projectManager.saveProject(project)
                    }
                }
                Spacer()
                Button("Confirm Link") {
                    guard let grade = inspectedGrade, let ocf = effectiveCandidateChoices[grade],
                          project.setManualLinkOverride(segmentURL: grade, ocfURL: ocf) else { return }
                    projectManager.saveProject(project)
                    project.performLinkingCallback?()
                    inspectedGrade = nil
                }
                .disabled(inspectedGrade.flatMap { effectiveCandidateChoices[$0] } == nil)
                Button("Confirm All (\(bulkConfirmationPairs.count))") {
                    let pairs = bulkConfirmationPairs
                    for pair in pairs {
                        project.setManualLinkOverride(segmentURL: pair.segment, ocfURL: pair.ocf)
                    }
                    projectManager.saveProject(project)
                    project.performLinkingCallback?()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bulkConfirmationPairs.isEmpty)
            }
            if let folder = project.model.preferredOCFFolder {
                Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(2).help(folder.path)
            }
            Text("Confirm All uses your chosen candidates first, then unique matches from the folder preference. Only shown clips with a valid choice are confirmed.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal)
    }

    private func cancelCurrentOperation() {
        NSLog("🛑 Cancel requested")

        // Cancel rendering if active
        if renderQueueManager.isProcessing {
            NSLog("🛑 Canceling render queue")
            renderQueueManager.stopProcessing()
            statusBarVM.reset()
        }

        // Cancel blank rush generation if active (delegate to parent)
        onCancelBlankRushes?()
    }

    private func updateRenderButtonState() {
        // Count renderable OCFs (excluding offline)
        let renderableOCFs = confidentlyLinkedParents.filter { parent in
            !project.model.offlineMediaFiles.contains(parent.ocf.fileName)
        }

        // Count selected OCFs that are also renderable
        let selectedRenderable = renderableOCFs.filter { parent in
            selectedOCFParents.contains(parent.ocf.url)
        }

        // Update status bar state
        statusBarVM.totalRenderableCount = renderableOCFs.count
        statusBarVM.selectedRenderCount = selectedRenderable.count
        statusBarVM.modifiedRenderCount = renderableOCFs.filter { modifiedURLs.contains($0.ocf.url) }.count
    }

    private func setupView() {
        statusBarVM.isPublishing = project.isPublishing
        // Configure RenderQueueManager with project directories
        let configuration = RenderConfiguration(
            blankRushDirectory: project.model.blankRushDirectory,
            outputDirectory: project.model.outputDirectory,
            proResProfile: "4"
        )
        renderQueueManager.configure(with: configuration)

        // Set up render button callbacks
        statusBarVM.onRenderAll = renderAll
        statusBarVM.onRenderSelected = renderSelected
        statusBarVM.onRenderModified = renderModified
        statusBarVM.onCancel = cancelCurrentOperation

        // Initial state update
        updateRenderButtonState()
    }

    private func handleRenderCompletedChange(_ result: RenderResult?) {
        guard let result = result else { return }
        handleRenderCompleted(result, projectManager: projectManager)
        NSLog(
            "📊 Queue progress: \(renderQueueManager.completedCount) completed, \(renderQueueManager.failedCount) failed"
        )
    }

    private func handleProcessingChange(_ isProcessing: Bool) {
        if !isProcessing && renderQueueManager.queue.isEmpty {
            let total = renderQueueManager.completedCount + renderQueueManager.failedCount
            statusBarVM.completeOperation(summary: "Rendered \(total) item\(total == 1 ? "" : "s")")
        }
    }

    private func handleCurrentItemChange(_ item: SourcePrintCore.RuntimeRenderQueueItem?) {
        if let item = item {
            let currentIndex =
                renderQueueManager.completedCount + renderQueueManager.failedCount + 1

            // Calculate total progress including current item
            let totalProgressFrames =
                renderQueueManager.cumulativeCompletedFrames
                + renderQueueManager.currentItemFramesProcessed

            statusBarVM.updateRenderProgress(
                currentItem: currentIndex,
                totalItems: renderQueueManager.initialTotalItems,
                fileName: item.ocfFileName,
                progress: item.progress,
                currentSegment: item.currentSegment,
                totalSegments: item.totalSegments,
                totalFrames: renderQueueManager.totalFramesInQueue,
                completedFrames: totalProgressFrames
            )
        }
    }

    // MARK: - Project Status Updates

    private func handleRenderCompleted(_ result: RenderResult, projectManager: ProjectManager?) {
        guard let projectManager = projectManager else { return }

        if result.success {
            // Update blank rush status
            if let blankRushURL = result.blankRushURL {
                project.model.blankRushStatus[result.ocfFileName] = .completed(
                    date: Date(), url: blankRushURL)
            }

            if let url = result.ocfURL { project.model.invalidatedRenderURLs.remove(url) }

            // Update print status
            if let outputURL = result.outputURL {
                project.model.printStatus[result.ocfFileName] = .printed(
                    date: Date(), outputURL: outputURL)
            }

            // Clear modification dates for printed segments
            if let parent = confidentlyLinkedParents.first(where: {
                $0.ocf.url == result.ocfURL
            }) {
                for child in parent.children {
                    project.model.segmentModificationDates.removeValue(
                        forKey: child.segment.fileName)
                }
            }

            // Add print record
            project.addPrintRecord(SourcePrintCore.PrintRecord(
                date: Date(),
                ocfFileName: result.ocfFileName,
                ocfURL: result.ocfURL,
                outputURL: result.outputURL
                    ?? project.model.outputDirectory.appendingPathComponent(result.ocfFileName),
                segmentCount: result.segmentCount,
                duration: result.duration,
                success: true,
                outputFingerprint: result.outputFingerprint,
                batch: result.batch
            ))

            NSLog("✅ Updated project status for: \(result.ocfFileName)")
        } else {
            // Record failed render
            project.addPrintRecord(SourcePrintCore.PrintRecord(
                date: Date(),
                ocfFileName: result.ocfFileName,
                ocfURL: result.ocfURL,
                outputURL: project.model.outputDirectory.appendingPathComponent(result.ocfFileName),
                segmentCount: result.segmentCount,
                duration: result.duration,
                success: false,
                errorMessage: result.error,
                cancelled: result.cancelled,
                batch: result.batch
            ))

            NSLog("❌ Recorded failed render for: \(result.ocfFileName)")
        }

        // Save project
        projectManager.saveProject(project)
    }

    // NOTE: Old batch render functions removed - now handled by RenderQueueManager
    // The following functions have been extracted to SourcePrintCore:
    // - processBatchRenderQueue() -> RenderQueueManager.startProcessing()
    // - processOCFInQueue() -> Handled by card's RenderService
    // - createBlankRushForOCF() -> RenderService.generateBlankRush()
    // - renderOCFInQueue() -> RenderService.composeVideo()

    var body: some View {
        contentWithKeyboardHandling
            .sheet(item: $pendingReview) { review in sourceChangesSheet(review) }
            .safeAreaInset(edge: .top) {
                if let notice = project.mediaRefreshNotice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .padding()
                }
            }
            .onReceive(renderQueueManager.$lastCompletedResult.dropFirst(), perform: handleRenderCompletedChange)
            .onReceive(renderQueueManager.$isProcessing.dropFirst(), perform: handleProcessingChange)
            .onReceive(renderQueueManager.$currentItem) { item in
                if currentlyRenderingOCF != item?.ocfFileName {
                    currentlyRenderingOCF = item?.ocfFileName
                }
                handleCurrentItemChange(item)
            }
            .task(id: project.model.lastModified) {
                await refreshModifiedJobs()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await refreshModifiedJobs() }
            }
            .onChange(of: project.isPublishing) { _, publishing in
                statusBarVM.isPublishing = publishing
            }
            .onChange(of: selectedOCFParents) { _, _ in
                updateRenderButtonState()
            }
            .onChange(of: confidentlyLinkedParents.count) { _, _ in
                updateRenderButtonState()
            }
    }

    private var contentWithKeyboardHandling: some View {
        mainContent
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) {
                setSelectedCardsExpanded(true)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                setSelectedCardsExpanded(false)
                return .handled
            }
            .onKeyPress(.downArrow) {
                handleDownArrow()
                return .handled
            }
            .onKeyPress(.upArrow) {
                handleUpArrow()
                return .handled
            }
            .onKeyPress(.escape) {
                // Deselect all
                selectedOCFParents.removeAll()
                selectedLinkedFiles.removeAll()
                selectedUnmatchedFiles.removeAll()
                return .handled
            }
            .onKeyPress(keys: ["a"]) { press in
                // Check if Command key is pressed
                if press.modifiers.contains(.command) {
                    // Select all OCF parents
                    selectedOCFParents = Set(filteredConfidentlyLinkedParents.map { $0.ocf.url })
                    selectedLinkedFiles.removeAll()
                    selectedUnmatchedFiles.removeAll()
                    navigationContext = .ocfList
                    return .handled
                }
                return .ignored
            }
            .onAppear {
                setupView()
            }
    }

    private var mainContent: some View {
        HStack(spacing: 0) {
            Group {
                if linkingResult == nil {
                    noResultsView
                } else {
                    linkingResultsContent
                }
            }
            if showRenderLog {
                Divider()
                RenderHistoryDrawer(project: project, isRendering: renderQueueManager.isProcessing, onClose: { showRenderLog = false })
                    .id(project.model.id)
                    .frame(minWidth: 420, idealWidth: 500, maxWidth: 560)
            }
        }
        .toolbar {
            Button {
                if showRenderLog {
                    showRenderLog = false
                    showUnmatchedDrawer = true
                } else {
                    showUnmatchedDrawer.toggle()
                }
            } label: {
                Label("Unmatched Items", systemImage: "link")
            }
            .disabled(linkingResult == nil)
            .help("\(showUnmatchedDrawer && !showRenderLog ? "Hide" : "Show") Unmatched Items (\(totalUnmatchedItems))")

            Button {
                showRenderLog.toggle()
            } label: {
                Label("Render Log", systemImage: "clock.arrow.circlepath")
            }
            .help("Show render history")
        }
    }

    private var noResultsView: some View {
        VStack {
            // Action buttons even when no results
            HStack {
                Text("Linking")
                    .font(.headline)

                Spacer()

                // Auto-linking happens automatically after import
                Text("Linking will run automatically when files are imported")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "link.circle")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)
                Text("No linking results yet")
                    .font(.title2)
                    .foregroundColor(.secondary)

                if project.model.ocfFiles.isEmpty && project.model.segments.isEmpty {
                    Text("Import OCF files and segments to begin linking")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else if project.model.ocfFiles.isEmpty {
                    Text("Import OCF files to link with segments")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else if project.model.segments.isEmpty {
                    Text("Import segments to link with OCF files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Click 'Run Auto-Linking' to match segments with OCF files")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setSelectedCardsExpanded(_ expanded: Bool) {
        guard !selectedOCFParents.isEmpty else { return }
        var states = project.ocfCardExpansionState
        for url in selectedOCFParents { states[url.lastPathComponent] = expanded }
        withAnimation(.easeInOut(duration: 0.2)) { project.ocfCardExpansionState = states }
        projectManager.saveProject(project)
    }

    private func handleDownArrow() {
        guard !confidentlyLinkedParents.isEmpty else { return }

        // Ensure focusedOCFIndex is valid
        if focusedOCFIndex >= confidentlyLinkedParents.count {
            focusedOCFIndex = 0
        }

        let currentOCF = confidentlyLinkedParents[focusedOCFIndex]
        let sortedChildren = sortedByTimecode(currentOCF.children)

        switch navigationContext {
        case .ocfList:
            // Currently focused on an OCF card
            let isExpanded = project.ocfCardExpansionState[currentOCF.ocf.fileName] ?? true

            if isExpanded && !sortedChildren.isEmpty {
                // OCF is expanded and has segments → move to first segment
                navigationContext = .segmentList
                selectedOCFParents = [currentOCF.ocf.url]
                selectedLinkedFiles = [sortedChildren[0].segment.fileName]
            } else {
                // OCF is collapsed or has no segments → move to next OCF
                if focusedOCFIndex < confidentlyLinkedParents.count - 1 {
                    focusedOCFIndex += 1
                    selectedOCFParents = [confidentlyLinkedParents[focusedOCFIndex].ocf.url]
                }
            }

        case .segmentList:
            // Currently focused on a segment
            guard let currentSegment = selectedLinkedFiles.first,
                let segmentIndex = sortedChildren.firstIndex(where: {
                    $0.segment.fileName == currentSegment
                })
            else {
                return
            }

            if segmentIndex < sortedChildren.count - 1 {
                // Move to next segment in current OCF
                selectedLinkedFiles = [sortedChildren[segmentIndex + 1].segment.fileName]
            } else {
                // At last segment → move to next OCF card
                if focusedOCFIndex < confidentlyLinkedParents.count - 1 {
                    focusedOCFIndex += 1
                    navigationContext = .ocfList
                    selectedLinkedFiles.removeAll()
                    selectedOCFParents = [confidentlyLinkedParents[focusedOCFIndex].ocf.url]
                }
            }
        }
    }

    private func handleUpArrow() {
        guard !confidentlyLinkedParents.isEmpty else { return }

        // Ensure focusedOCFIndex is valid
        if focusedOCFIndex >= confidentlyLinkedParents.count {
            focusedOCFIndex = max(0, confidentlyLinkedParents.count - 1)
        }

        let currentOCF = confidentlyLinkedParents[focusedOCFIndex]
        let sortedChildren = sortedByTimecode(currentOCF.children)

        switch navigationContext {
        case .segmentList:
            // Currently focused on a segment
            guard let currentSegment = selectedLinkedFiles.first,
                let segmentIndex = sortedChildren.firstIndex(where: {
                    $0.segment.fileName == currentSegment
                })
            else {
                return
            }

            if segmentIndex > 0 {
                // Move to previous segment in current OCF
                selectedLinkedFiles = [sortedChildren[segmentIndex - 1].segment.fileName]
            } else {
                // At first segment → move back to parent OCF card
                navigationContext = .ocfList
                selectedLinkedFiles.removeAll()
                selectedOCFParents = [currentOCF.ocf.url]
            }

        case .ocfList:
            // Currently focused on an OCF card
            if focusedOCFIndex > 0 {
                focusedOCFIndex -= 1
                let previousOCF = confidentlyLinkedParents[focusedOCFIndex]
                let previousSortedChildren = sortedByTimecode(previousOCF.children)
                let isExpanded = project.ocfCardExpansionState[previousOCF.ocf.fileName] ?? true

                if isExpanded && !previousSortedChildren.isEmpty {
                    // Previous OCF is expanded → jump to its last segment
                    navigationContext = .segmentList
                    selectedOCFParents = [previousOCF.ocf.url]
                    selectedLinkedFiles = [previousSortedChildren.last!.segment.fileName]
                } else {
                    // Previous OCF is collapsed → select it
                    selectedOCFParents = [previousOCF.ocf.url]
                }
            }
        // If already at first OCF, do nothing (stay at top)
        }
    }

    @ViewBuilder
    private var linkingResultsContent: some View {
        HStack(spacing: 0) {
            // Main Linked Results with List View
            VStack(alignment: .leading) {
                VStack(spacing: 8) {
                    HStack {
                        Text(searchText.isEmpty
                            ? "Linked Files (\(totalConfidentSegments) segments)"
                            : "Linked Files (\(filteredSegmentCount) of \(totalConfidentSegments) segments)")
                            .font(.headline)
                            .monospacedDigit()

                        Spacer()
                    }

                    // Status line with linking result summary
                    if let result = project.model.linkingResult {
                        HStack {
                            Text(result.summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding()
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedOCFParents.removeAll()
                }

                // Search bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))

                    TextField("Search OCF or segment names…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))

                    if !searchText.isEmpty {
                        Button(action: {
                            searchText = ""
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 14))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.appBackgroundTertiary)
                .cornerRadius(6)
                .padding(.horizontal)
                .padding(.bottom, 8)

                // Use ScrollView for true card layout
                ZStack {
                    // Background layer to capture taps in empty space
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Clicking in empty space deselects all
                            selectedOCFParents.removeAll()
                            selectedLinkedFiles.removeAll()
                            selectedUnmatchedFiles.removeAll()
                        }

                    let allParents = confidentlyLinkedParents
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(
                                Array(filteredConfidentlyLinkedParents.enumerated()), id: \.element.ocf.url
                            ) { index, parent in
                                CompressorStyleOCFCard(
                                    parent: parent,
                                    ocfIndex: index,
                                    project: project,
                                    timelineVisualizationData: timelineVisualizationData,
                                    selectedLinkedFiles: $selectedLinkedFiles,
                                    selectedOCFParents: $selectedOCFParents,
                                    focusedOCFIndex: $focusedOCFIndex,
                                    navigationContext: $navigationContext,
                                    projectManager: projectManager,
                                    getSelectedParents: getSelectedParents,
                                    allParents: allParents,
                                    isRendering: currentlyRenderingOCF == parent.ocf.fileName,
                                    renderQueueManager: renderQueueManager,
                                    onRenderSingle: {
                                        renderSingle(parent: parent)
                                    }
                                )
                                .contextMenu {
                                    OCFParentContextMenu(
                                        parent: parent,
                                        project: project,
                                        projectManager: projectManager,
                                        selectedParents: getSelectedParents(),
                                        allParents: allParents
                                    )
                                }
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(minWidth: 400)

            // Collapsible Unmatched Items Drawer
            if showUnmatchedDrawer && !showRenderLog {
                // Visual divider similar to Xcode
                Rectangle()
                    .fill(Color.appBackgroundDivider)
                    .frame(width: 1)

                VStack(alignment: .leading) {
                    VStack(spacing: 8) {
                        HStack {
                            Text("Unmatched Items")
                                .font(.headline)

                            Spacer()

                            // Balance with some actions or info
                            HStack(spacing: 12) {
                                Text("(\(totalUnmatchedItems))")
                                    .font(.headline)
                                    .monospacedDigit()
                                    .foregroundColor(.secondary)
                            }

                            Button {
                                showUnmatchedDrawer = false
                            } label: {
                                Image(systemName: "xmark")
                            }
                            .buttonStyle(.plain)
                            .help("Close unmatched items")
                        }

                        // Status line for unmatched items
                        if totalUnmatchedItems > 0 {
                            HStack {
                                Text("Review these items before proceeding")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    .padding()

                    TextField("Search unmatched items", text: $unmatchedSearch)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)

                    if !lowConfidenceSegments.isEmpty { bulkConfirmationControls }

                    let segments = (linkingResult?.unmatchedSegments ?? []).filter { matchesUnmatchedSearch($0) }
                    let ocfs = (linkingResult?.unmatchedOCFs ?? []).filter { matchesUnmatchedSearch($0) }
                    let lowConfidence = lowConfidenceSegments.filter { matchesUnmatchedSearch($0.segment) }
                    MatchReviewOutline(
                        grades: lowConfidence.map(\.segment), unmatchedGrades: segments,
                        unmatchedOCFs: ocfs, originals: project.model.ocfFiles,
                        choices: effectiveCandidateChoices,
                        onChoose: { grade, ocf in
                            candidateChoices[grade] = ocf
                            inspectedGrade = grade
                        },
                        onInspect: { inspectedGrade = $0 }
                    )
                    if !ocfs.isEmpty {
                        HStack {
                            Text("Unmatched OCFs (\(ocfs.count))").foregroundStyle(.secondary)
                            Spacer()
                            Button("Clear", systemImage: "trash", role: .destructive) {
                                removeUnmatchedOCFFiles(ocfs)
                            }
                            .help("Remove shown unmatched OCF entries. Files on disk are kept.")
                        }.padding(.horizontal).padding(.bottom, 8)
                    }

                }
                .frame(minWidth: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Unmatched File Removal

    private func matchesUnmatchedSearch(_ file: MediaFileInfo) -> Bool {
        unmatchedSearch.isEmpty || file.fileName.localizedCaseInsensitiveContains(unmatchedSearch)
    }

    private func removeUnmatchedOCFFiles(_ files: [MediaFileInfo]) {
        guard let result = linkingResult else { return }
        let paths = Set(files.map { $0.url.standardizedFileURL.path })
        project.model.ocfFiles.removeAll { paths.contains($0.url.standardizedFileURL.path) }

        let remainingNames = Set(project.model.ocfFiles.map(\.fileName))
        for file in files where !remainingNames.contains(file.fileName) {
            project.model.blankRushStatus.removeValue(forKey: file.fileName)
        }
        project.model.linkingResult = LinkingResult(
            ocfParents: result.ocfParents.filter { !paths.contains($0.ocf.url.standardizedFileURL.path) },
            unmatchedSegments: result.unmatchedSegments,
            unmatchedOCFs: result.unmatchedOCFs.filter { !paths.contains($0.url.standardizedFileURL.path) }
        )
        project.updateModified()
        projectManager.saveProject(project)
    }
}
