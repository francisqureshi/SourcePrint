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
    static let expandSelectedCards = Notification.Name("expandSelectedCards")
    static let collapseSelectedCards = Notification.Name("collapseSelectedCards")
    static let collapseAllCards = Notification.Name("collapseAllCards")
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
    let timelineVisualizationData: [String: TimelineVisualization]
    @EnvironmentObject var projectManager: ProjectManager
    @EnvironmentObject var statusBarVM: StatusBarViewModel
    var onPerformLinking: (() -> Void)? = nil
    var onGenerateBlankRushes: (() -> Void)? = nil
    var onCancelBlankRushes: (() -> Void)? = nil

    // Use the project's current linking result instead of a cached copy
    private var linkingResult: LinkingResult? {
        project.model.linkingResult
    }
    @State private var selectedLinkedFiles: Set<String> = []
    @State private var selectedUnmatchedFiles: Set<String> = []
    @State private var selectedOCFParents: Set<String> = []
    @State private var showUnmatchedDrawer = true

    // Unified navigation state
    enum NavigationContext {
        case ocfList
        case segmentList
    }
    @State private var navigationContext: NavigationContext = .ocfList
    @State private var focusedOCFIndex: Int = 0

    // Render queue manager (from SourcePrintCore)
    @StateObject private var renderQueueManager = RenderQueueManager()

    // Computed property to track which OCF is currently rendering
    private var currentlyRenderingOCF: String? {
        renderQueueManager.currentItem?.ocfFileName
    }

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

    var totalUnmatchedItems: Int {
        guard let linkingResult = linkingResult else { return 0 }
        return linkingResult.unmatchedOCFs.count + linkingResult.unmatchedSegments.count
            + lowConfidenceSegments.count
    }

    // Batch render computed properties
    var canRenderAll: Bool {
        return confidentlyLinkedParents.contains { parent in
            !project.model.offlineMediaFiles.contains(parent.ocf.fileName)
        }
    }

    var canRenderModified: Bool {
        return confidentlyLinkedParents.contains { parent in
            parent.children.contains { child in
                project.model.segmentModificationDates[child.segment.fileName] != nil
            }
        }
    }

    // Helper to get selected OCF parents for context menu batch operations
    private func getSelectedParents() -> [OCFParent] {
        return confidentlyLinkedParents.filter { parent in
            selectedOCFParents.contains(parent.ocf.fileName)
        }
    }

    // Batch render functions - uses RenderQueueManager from SourcePrintCore

    private func renderAll() {
        let ocfsToRender = confidentlyLinkedParents.filter { parent in
            !project.model.offlineMediaFiles.contains(parent.ocf.fileName)
        }

        NSLog("🎬 Starting batch render for %d OCFs", ocfsToRender.count)

        renderQueueManager.addToQueue(ocfsToRender)
        renderQueueManager.startProcessing()
    }

    private func renderModified() {
        let modifiedOCFs = confidentlyLinkedParents.filter { parent in
            parent.children.contains { child in
                project.model.segmentModificationDates[child.segment.fileName] != nil
            }
        }

        NSLog("🔄 Starting batch render for %d modified OCFs", modifiedOCFs.count)

        renderQueueManager.addToQueue(modifiedOCFs)
        renderQueueManager.startProcessing()
    }

    private func renderSelected() {
        let selectedOCFs = confidentlyLinkedParents.filter { parent in
            selectedOCFParents.contains(parent.ocf.fileName)
        }.filter { parent in
            !project.model.offlineMediaFiles.contains(parent.ocf.fileName)
        }

        NSLog("🎬 Starting batch render for %d selected OCFs", selectedOCFs.count)

        renderQueueManager.addToQueue(selectedOCFs)
        renderQueueManager.startProcessing()
    }

    private func renderSingle(parent: OCFParent) {
        NSLog("🎬 Starting single render for: %@", parent.ocf.fileName)
        renderQueueManager.addToQueue([parent])
        renderQueueManager.startProcessing()
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
            selectedOCFParents.contains(parent.ocf.fileName)
        }

        // Count modified OCFs
        let modifiedOCFs = confidentlyLinkedParents.filter { parent in
            parent.children.contains { child in
                project.model.segmentModificationDates[child.segment.fileName] != nil
            }
        }

        // Update status bar state
        statusBarVM.totalRenderableCount = renderableOCFs.count
        statusBarVM.selectedRenderCount = selectedRenderable.count
        statusBarVM.modifiedRenderCount = modifiedOCFs.count
    }

    private func setupView() {
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

    private func handleSegmentProgressChange(_ segmentProgress: SourcePrintCore.SegmentProgress?) {
        guard let segmentProgress = segmentProgress,
            let item = renderQueueManager.currentItem
        else { return }

        let currentIndex = renderQueueManager.completedCount + renderQueueManager.failedCount + 1

        // Use actual frame counts from completed segments (accounts for variable segment lengths)
        // This is accurate because printProcessFFmpeg calculates actual frames from each completed segment
        let totalProgressFrames =
            renderQueueManager.cumulativeCompletedFrames
            + renderQueueManager.currentItemFramesProcessed

        statusBarVM.updateRenderProgress(
            currentItem: currentIndex,
            totalItems: renderQueueManager.initialTotalItems,
            fileName: item.ocfFileName,
            progress: item.progress,
            currentSegment: segmentProgress.current,
            totalSegments: segmentProgress.total,
            totalFrames: renderQueueManager.totalFramesInQueue,
            completedFrames: totalProgressFrames
        )
    }

    // Render queue state is observed automatically via @StateObject
    // SwiftUI will react to changes in renderQueueManager's @Published properties

    // MARK: - Project Status Updates

    private func handleRenderCompleted(_ result: RenderResult, projectManager: ProjectManager?) {
        guard let projectManager = projectManager else { return }

        if result.success {
            // Update blank rush status
            if let blankRushURL = result.blankRushURL {
                project.model.blankRushStatus[result.ocfFileName] = .completed(
                    date: Date(), url: blankRushURL)
            }

            // Update print status
            if let outputURL = result.outputURL {
                project.model.printStatus[result.ocfFileName] = .printed(
                    date: Date(), outputURL: outputURL)
            }

            // Clear modification dates for printed segments
            if let parent = confidentlyLinkedParents.first(where: {
                $0.ocf.fileName == result.ocfFileName
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
                outputURL: result.outputURL
                    ?? project.model.outputDirectory.appendingPathComponent(result.ocfFileName),
                segmentCount: result.segmentCount,
                duration: result.duration,
                success: true
            ))

            NSLog("✅ Updated project status for: \(result.ocfFileName)")
        } else {
            // Record failed render
            project.addPrintRecord(SourcePrintCore.PrintRecord(
                date: Date(),
                ocfFileName: result.ocfFileName,
                outputURL: project.model.outputDirectory.appendingPathComponent(result.ocfFileName),
                segmentCount: result.segmentCount,
                duration: result.duration,
                success: false
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
        mainContent
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.rightArrow) {
                expandSelectedCards()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                collapseSelectedCards()
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
            .onAppear {
                setupView()
            }
            .onChange(of: renderQueueManager.lastCompletedResult) { _, result in
                handleRenderCompletedChange(result)
            }
            .onChange(of: renderQueueManager.isProcessing) { _, isProcessing in
                handleProcessingChange(isProcessing)
            }
            .onChange(of: renderQueueManager.currentItem) { _, item in
                handleCurrentItemChange(item)
            }
            .onChange(of: renderQueueManager.currentSegmentProgress) { _, segmentProgress in
                handleSegmentProgressChange(segmentProgress)
            }
            .onChange(of: renderQueueManager.currentItemFramesProcessed) { _, _ in
                // Frame count changed - update status bar with new progress
                if let item = renderQueueManager.currentItem {
                    handleCurrentItemChange(item)
                }
            }
            .onChange(of: selectedOCFParents) { _, _ in
                updateRenderButtonState()
            }
            .onChange(of: confidentlyLinkedParents.count) { _, _ in
                updateRenderButtonState()
            }
    }

    private var mainContent: some View {
        Group {
            if linkingResult == nil {
                noResultsView
            } else {
                linkingResultsContent
            }
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

    private func expandSelectedCards() {
        // This will be handled by each individual card
        NotificationCenter.default.post(name: .expandSelectedCards, object: nil)
    }

    private func collapseSelectedCards() {
        // This will be handled by each individual card
        NotificationCenter.default.post(name: .collapseSelectedCards, object: nil)
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
                selectedOCFParents = [currentOCF.ocf.fileName]
                selectedLinkedFiles = [sortedChildren[0].segment.fileName]
            } else {
                // OCF is collapsed or has no segments → move to next OCF
                if focusedOCFIndex < confidentlyLinkedParents.count - 1 {
                    focusedOCFIndex += 1
                    selectedOCFParents = [confidentlyLinkedParents[focusedOCFIndex].ocf.fileName]
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
                    selectedOCFParents = [confidentlyLinkedParents[focusedOCFIndex].ocf.fileName]
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
                selectedOCFParents = [currentOCF.ocf.fileName]
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
                    selectedOCFParents = [previousOCF.ocf.fileName]
                    selectedLinkedFiles = [previousSortedChildren.last!.segment.fileName]
                } else {
                    // Previous OCF is collapsed → select it
                    selectedOCFParents = [previousOCF.ocf.fileName]
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
                        Text("Linked Files (\(totalConfidentSegments) segments)")
                            .font(.headline)
                            .monospacedDigit()

                        Spacer()

                        // Show toggle button here when drawer is hidden
                        if !showUnmatchedDrawer {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showUnmatchedDrawer.toggle()
                                }
                            } label: {
                                HStack(spacing: 2) {
                                    Image(systemName: "inset.filled.righthalf.rectangle")
                                        .font(.system(size: 14))
                                        .foregroundColor(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Show Unmatched Items (\(totalUnmatchedItems))")
                            .padding(.trailing)
                        }
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

                // Use ScrollView for true card layout
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(
                            Array(confidentlyLinkedParents.enumerated()), id: \.element.ocf.fileName
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
                                allParents: confidentlyLinkedParents,
                                currentlyRenderingOCF: currentlyRenderingOCF,
                                renderProgress: renderQueueManager.currentItem?.ocfFileName
                                    == parent.ocf.fileName
                                    ? renderQueueManager.currentItem?.progress : nil,
                                renderSegmentProgress: renderQueueManager.currentItem?.ocfFileName
                                    == parent.ocf.fileName
                                    ? renderQueueManager.currentSegmentProgress : nil,
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
                                    allParents: confidentlyLinkedParents
                                )
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(minWidth: 400)

            // Collapsible Unmatched Items Drawer
            if showUnmatchedDrawer {
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

                            // Xcode-style drawer toggle button
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showUnmatchedDrawer.toggle()
                                }
                            } label: {
                                Image(
                                    systemName: showUnmatchedDrawer
                                        ? "inset.filled.righthalf.rectangle"
                                        : "inset.filled.righthalf.rectangle"
                                )
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(
                                showUnmatchedDrawer
                                    ? "Hide Unmatched Items" : "Show Unmatched Items"
                            )
                            .padding(.trailing)
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

                    List(selection: $selectedUnmatchedFiles) {
                        // Unmatched Segments (shown first - most important)
                        if let linkingResult = linkingResult,
                            !linkingResult.unmatchedSegments.isEmpty
                        {
                            Section("Unmatched Segments (\(linkingResult.unmatchedSegments.count))")
                            {
                                ForEach(linkingResult.unmatchedSegments, id: \.fileName) {
                                    segment in
                                    UnmatchedFileRowView(file: segment, type: .segment)
                                        .tag(segment.fileName)
                                }
                            }
                        }

                        // Unmatched OCF Files
                        if let linkingResult = linkingResult, !linkingResult.unmatchedOCFs.isEmpty {
                            Section {
                                ForEach(linkingResult.unmatchedOCFs, id: \.fileName) { ocf in
                                    UnmatchedFileRowView(file: ocf, type: .ocf)
                                        .tag(ocf.fileName)
                                }
                            } header: {
                                HStack {
                                    Text(
                                        "Unmatched OCF Files (\(linkingResult.unmatchedOCFs.count))"
                                    )
                                    .monospacedDigit()

                                    Spacer()

                                    Menu {
                                        Button(
                                            "Remove Unmatched OCF Files", systemImage: "trash"
                                        ) {
                                            removeUnmatchedOCFFiles()
                                        }
                                        .foregroundColor(.red)
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .font(.system(size: 14))
                                            .foregroundColor(.secondary)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .menuOrder(.fixed)
                                    .fixedSize()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        // Low Confidence Matches
                        if !lowConfidenceSegments.isEmpty {
                            Section("Low Confidence Matches (\(lowConfidenceSegments.count))") {
                                ForEach(lowConfidenceSegments, id: \.segment.fileName) {
                                    linkedSegment in
                                    LowConfidenceSegmentRowView(linkedSegment: linkedSegment)
                                        .tag(linkedSegment.segment.fileName)
                                }
                            }
                        }
                    }
                }
                .frame(minWidth: 300)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
    }

    // MARK: - Unmatched File Removal

    private func removeUnmatchedOCFFiles() {
        guard let currentLinkingResult = linkingResult else { return }
        let fileNamesToRemove = currentLinkingResult.unmatchedOCFs.map { $0.fileName }

        // Remove from project files
        project.model.ocfFiles.removeAll { fileNamesToRemove.contains($0.fileName) }

        // Clean up related blank rush status
        for fileName in fileNamesToRemove {
            project.model.blankRushStatus.removeValue(forKey: fileName)
        }

        // Update the linking result to remove these from unmatched list (keep all linked data)
        let updatedUnmatchedOCFs = currentLinkingResult.unmatchedOCFs.filter {
            !fileNamesToRemove.contains($0.fileName)
        }

        let updatedLinkingResult = LinkingResult(
            ocfParents: currentLinkingResult.ocfParents,  // Keep all linked data
            unmatchedSegments: currentLinkingResult.unmatchedSegments,  // Keep unchanged
            unmatchedOCFs: updatedUnmatchedOCFs  // Remove the files we deleted
        )

        project.model.linkingResult = updatedLinkingResult
        project.updateModified()
        projectManager.saveProject(project)

        NSLog(
            "🗑️ Removed \(fileNamesToRemove.count) unmatched OCF file(s) from project: \(fileNamesToRemove.joined(separator: ", "))"
        )
    }
}
