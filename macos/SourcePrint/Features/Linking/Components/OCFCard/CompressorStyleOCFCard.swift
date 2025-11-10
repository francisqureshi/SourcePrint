//
//  CompressorStyleOCFCard.swift
//  SourcePrint
//
//  Main OCF card component with Apple Compressor styling
//

import SourcePrintCore
import SwiftUI
import AVFoundation
import CoreMedia

struct CompressorStyleOCFCard: View {
    let parent: OCFParent
    let ocfIndex: Int
    let project: ProjectViewModel
    let timelineVisualizationData: [String: TimelineVisualization]
    @Binding var selectedLinkedFiles: Set<String>
    @Binding var selectedOCFParents: Set<String>
    @Binding var focusedOCFIndex: Int
    @Binding var navigationContext: LinkingResultsView.NavigationContext
    let projectManager: ProjectManager
    let getSelectedParents: () -> [OCFParent]
    let allParents: [OCFParent]
    let currentlyRenderingOCF: String?  // Global lock to prevent concurrent rendering
    let renderProgress: String?  // Current render progress message
    let renderSegmentProgress: SourcePrintCore.SegmentProgress?  // Current segment progress
    let onRenderSingle: () -> Void  // Callback to render just this OCF


    @State private var isExpanded: Bool = true  // Default to expanded

    // Render state is now managed by RenderQueueManager in parent view
    private var isRendering: Bool {
        currentlyRenderingOCF == parent.ocf.fileName
    }

    private var isSelected: Bool {
        selectedOCFParents.contains(parent.ocf.fileName)
    }

    private func handleCardSelection() {
        // Update navigation state
        focusedOCFIndex = ocfIndex
        navigationContext = .ocfList
        selectedLinkedFiles.removeAll()

        // Check if shift key is pressed for range selection
        let modifierFlags = NSApp.currentEvent?.modifierFlags ?? []
        let isShiftPressed = modifierFlags.contains(.shift)

        if isShiftPressed {
            handleRangeSelection()
        } else {
            // Simple toggle
            if selectedOCFParents.contains(parent.ocf.fileName) {
                selectedOCFParents.remove(parent.ocf.fileName)
            } else {
                selectedOCFParents.insert(parent.ocf.fileName)
            }
        }
    }

    private func handleRangeSelection() {
        // Find the last selected item to use as range start
        guard let lastSelectedFileName = selectedOCFParents.first,
              let lastIndex = allParents.firstIndex(where: { $0.ocf.fileName == lastSelectedFileName }),
              let currentIndex = allParents.firstIndex(where: { $0.ocf.fileName == parent.ocf.fileName }) else {
            // No previous selection, just select this one
            selectedOCFParents.insert(parent.ocf.fileName)
            return
        }

        let startIndex = min(lastIndex, currentIndex)
        let endIndex = max(lastIndex, currentIndex)

        // Select all items in the range
        for i in startIndex...endIndex {
            selectedOCFParents.insert(allParents[i].ocf.fileName)
        }
    }

    // Render logic moved to RenderService in SourcePrintCore
    // Card now just triggers rendering via notification, actual work done by RenderQueueManager

    /// Extract percentage from progress message like "Creating blank rush... 45% @ 180 fps"
    private func extractPercentage(from progress: String) -> Double? {
        // Look for pattern like "45%"
        let pattern = #"(\d+)%"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: progress, range: NSRange(progress.startIndex..., in: progress)),
              let percentRange = Range(match.range(at: 1), in: progress) else {
            return nil
        }

        let percentString = String(progress[percentRange])
        return Double(percentString)
    }

    /// Progress bar view with segment-based or percentage-based progress
    private var progressBarView: some View {
        Group {
            if let segmentProgress = renderSegmentProgress {
                // Use segment progress (e.g., 18/41 = 43.9%)
                ProgressView(value: Double(segmentProgress.current), total: Double(segmentProgress.total))
                    .progressViewStyle(.linear)
                    .tint(AppTheme.success)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            } else if let progress = renderProgress, let percentage = extractPercentage(from: progress) {
                // Fallback: Extract percentage for determinate progress bar
                ProgressView(value: percentage, total: 100.0)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.success)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            } else {
                // Indeterminate progress bar (composition phase)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.success)
                    .scaleEffect(x: 1, y: 0.5, anchor: .center)
            }
        }
    }

    var body: some View {
        cardContent
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onReceive(NotificationCenter.default.publisher(for: .expandSelectedCards)) { _ in
                if isSelected {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = true
                    }
                    project.ocfCardExpansionState[parent.ocf.fileName] = true
                    projectManager.saveProject(project)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .collapseSelectedCards)) { _ in
                if isSelected {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded = false
                    }
                    project.ocfCardExpansionState[parent.ocf.fileName] = false
                    projectManager.saveProject(project)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .collapseAllCards)) { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded = false
                }
                project.ocfCardExpansionState[parent.ocf.fileName] = false
            }
            .onAppear {
                isExpanded = project.ocfCardExpansionState[parent.ocf.fileName] ?? true
            }
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(spacing: 0) {
            // Compressor-style header (title bar)
            OCFCardHeader(
                fileName: parent.ocf.fileName,
                isExpanded: $isExpanded,
                isSelected: isSelected,
                isRendering: isRendering,
                project: project,
                projectManager: projectManager,
                onExpansionToggle: {
                    project.ocfCardExpansionState[parent.ocf.fileName] = isExpanded
                    projectManager.saveProject(project)
                },
                onRenderSingle: onRenderSingle,
                onCardSelection: handleCardSelection
            )

            // Render Progress Bar
            if isRendering, let progress = renderProgress {
                VStack(spacing: 4) {
                    progressBarView

                    // Split progress message to show FPS on the right
                    HStack {
                        if let separatorIndex = progress.range(of: " @ ")?.lowerBound {
                            // Has FPS info - split it
                            let statusPart = String(progress[..<separatorIndex])
                            let fpsPart = String(progress[progress.index(after: separatorIndex)...])

                            Text(statusPart)
                                .font(.caption2)
                                .foregroundColor(.primary)
                            Spacer()
                            Text(fpsPart)
                                .font(.caption2)
                                .foregroundColor(.primary.opacity(0.85))
                                .monospacedDigit()
                        } else {
                            // No FPS info - just show status
                            Text(progress)
                                .font(.caption2)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.3) : Color.appBackgroundSecondary)
            }

            // Card body (expandable content)
            if isExpanded {
                expandableContent
            }
        }
    }

    private var expandableContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // Timeline
                if let timelineData = timelineVisualizationData[parent.ocf.fileName] {
                    TimelineChartView(
                        visualizationData: timelineData,
                        ocfFileName: parent.ocf.fileName,
                        selectedSegmentFileName: selectedLinkedFiles.first
                    )
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                }

                // Render Log Section
                RenderLogSection(
                    project: project,
                    ocfFileName: parent.ocf.fileName
                )

                // Linked segments
                segmentsListView
            }
            .padding(8)
            .background(Color.appBackgroundTertiary.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.top, 0)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.appBackgroundSecondary)
    }

    private var segmentsListView: some View {
        VStack(spacing: 0) {
            ForEach(Array(sortedByTimecode(parent.children).enumerated()), id: \.element.segment.fileName) { index, linkedSegment in
                TreeLinkedSegmentRowView(
                    linkedSegment: linkedSegment,
                    isLast: linkedSegment.segment.fileName == sortedByTimecode(parent.children).last?.segment.fileName,
                    project: project
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .onTapGesture {
                    focusedOCFIndex = ocfIndex
                    navigationContext = .segmentList
                    selectedLinkedFiles = [linkedSegment.segment.fileName]
                    selectedOCFParents = [parent.ocf.fileName]
                }
                .background(
                    selectedLinkedFiles.contains(linkedSegment.segment.fileName)
                    ? Color.accentColor.opacity(0.2)
                    : Color.clear
                )
            }
        }
    }
}

// MARK: - OCF Card Header Component

struct OCFCardHeader: View {
    let fileName: String
    @Binding var isExpanded: Bool
    let isSelected: Bool
    let isRendering: Bool
    let project: ProjectViewModel
    let projectManager: ProjectManager
    let onExpansionToggle: () -> Void
    let onRenderSingle: () -> Void
    let onCardSelection: () -> Void

    var body: some View {
        HStack {
            // OCF filename as main title (clickable)
            Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                    onExpansionToggle()
                }
            }) {
                Text(fileName)
                    .font(.headline)
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)

            Spacer()

            // Status indicators
            HStack(spacing: 8) {
                // Print Status
                printStatusView

                // Render Button / State Display
                renderButtonView

                // Chevron indicator
                chevronButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.appBackgroundSecondary)
        .onTapGesture {
            onCardSelection()
        }
    }

    private var printStatusView: some View {
        Button(action: {}) {
            HStack(spacing: 4) {
                if let printStatus = project.model.printStatus[fileName] {
                    Image(systemName: printStatus.icon)
                        .foregroundColor(printStatus.color)
                    Text(printStatus.displayName)
                        .font(.caption)
                        .foregroundColor(printStatus.color)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                    Text("Not Printed")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var renderButtonView: some View {
        if isRendering {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                    .tint(AppTheme.success)
                    .scaleEffect(0.8)
                Text("Rendering")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
        } else {
            Button(action: onRenderSingle) {
                HStack(spacing: 4) {
                    Image(systemName: "play.circle.fill")
                        .foregroundColor(.accentColor)
                    Text("Render")
                        .font(.caption)
                        .foregroundColor(.accentColor)
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var chevronButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isExpanded.toggle()
                onExpansionToggle()
            }
        }) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
    }
}
