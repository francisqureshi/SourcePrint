//
//  StatusBarView.swift
//  SourcePrint
//
//  Persistent bottom "chin" status bar with Apple Compressor styling
//

import SwiftUI

struct StatusBarView: View {
    @ObservedObject var viewModel: StatusBarViewModel

    // Themed green for progress bars
    private let accentColor = AppTheme.success

    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(Color.appBackgroundDivider)
                .frame(height: 1)

            // Main content
            // Compact mode (always visible)
            compactView
                .background(Color.appBackgroundSecondary)
        }
        .frame(height: 44)
    }

    // MARK: - Compact View

    private var compactView: some View {
        HStack(spacing: 12) {
            // Left: Icon + Status Text
            HStack(spacing: 8) {
                operationIcon
                    .foregroundColor(accentColor)
                    .imageScale(.medium)

                Text(viewModel.statusText)
                    .font(.system(size: 13))
                    .foregroundColor(.primary)
            }

            Spacer()

            // Center: Progress Indicator
            if viewModel.currentOperation != .idle {
                progressIndicator
                    .frame(width: 1000)
            }

            Spacer()

            // Right: Render/Stop Buttons + Expand/Collapse
            HStack(spacing: 8) {
                // Show Stop button when actively processing
                if viewModel.currentOperation == .generatingBlankRush || viewModel.currentOperation == .rendering {
                    Button(action: {
                        viewModel.onCancel?()
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 12))
                            Text("Stop")
                                .font(.system(size: 14, weight: .medium))
                        }
                        .frame(minWidth: 100)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.regular)
                    .help("Cancel current operation")
                }
                // Show Render buttons when idle
                else if viewModel.currentOperation == .idle {
                    renderButtons
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    // MARK: - Expanded View

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let details = viewModel.detailedInfo {
                // File name
                if let fileName = details.fileName {
                    HStack(spacing: 6) {
                        Image(systemName: "film")
                            .foregroundColor(.secondary)
                            .imageScale(.small)
                        Text(fileName)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.primary)
                    }
                }

                // Metrics row
                HStack(spacing: 16) {
                    // FPS
                    if let fps = details.fps {
                        metricView(label: "FPS", value: String(format: "%.2f", fps))
                    }

                    // Percentage
                    if let percentage = details.percentage {
                        metricView(label: "Progress", value: percentage)
                    }

                    // Item counter
                    if let current = details.currentItem, let total = details.totalItems {
                        metricView(label: "Item", value: "\(current)/\(total)")
                    }

                    // Time remaining
                    if let timeRemaining = details.timeRemaining {
                        metricView(label: "Remaining", value: timeRemaining)
                    }

                    Spacer()
                }
                .font(.system(size: 11))
            } else {
                Text("No additional details available")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.appBackgroundTertiary)
    }

    // MARK: - Helper Views

    private var operationIcon: some View {
        Group {
            switch viewModel.currentOperation {
            case .idle:
                Image(systemName: "checkmark.circle.fill")
            case .importing:
                Image(systemName: "arrow.down.circle")
            case .linking:
                Image(systemName: "link.circle")
            case .generatingBlankRush:
                Image(systemName: "film.stack")
            case .rendering:
                Image(systemName: "gearshape.circle")
            case .watchFolderImport:
                Image(systemName: "folder.badge.plus")
            }
        }
    }

    private var progressIndicator: some View {
        Group {
            if viewModel.isIndeterminate {
                // Spinner for indeterminate progress
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .controlSize(.small)
                    Text("Processing...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            } else {
                // Standard progress bar
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .tint(accentColor)

                    Text(String(format: "%.0f%%", viewModel.progressValue * 100))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func metricView(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(.primary)
                .fontWeight(.medium)
        }
    }

    // MARK: - Action Buttons (Tab-Aware)

    private var renderButtons: some View {
        HStack(spacing: 8) {
            // Show different buttons based on active tab
            switch viewModel.currentTab {
            case .media:
                linkButton
            case .linking:
                renderingButtons
            case .overview:
                EmptyView()
            }
        }
    }

    // MARK: - Link Button (Media Import Tab)

    private var linkButton: some View {
        Group {
            if viewModel.ocfFileCount > 0 && viewModel.segmentFileCount > 0 {
                Button(action: {
                    viewModel.onLinkFiles?()
                }) {
                    Text("Link Files")
                        .font(.system(size: 14, weight: .medium))
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .controlSize(.regular)
                .help("Link \(viewModel.ocfFileCount) OCF file\(viewModel.ocfFileCount == 1 ? "" : "s") with \(viewModel.segmentFileCount) segment\(viewModel.segmentFileCount == 1 ? "" : "s")")
            }
        }
    }

    // MARK: - Render Buttons (Linking Tab)

    private var renderingButtons: some View {
        HStack(spacing: 8) {
            // Primary render button (changes based on selection)
            if viewModel.totalRenderableCount > 0 {
                Button(action: {
                    if viewModel.selectedRenderCount > 0 {
                        viewModel.onRenderSelected?()
                    } else {
                        viewModel.onRenderAll?()
                    }
                }) {
                    Text(renderButtonLabel)
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .frame(minWidth: 100) // Wide enough for "Render 999"
                }
                .buttonStyle(.borderedProminent)
                .tint(accentColor)
                .controlSize(.regular)
                .help(renderButtonTooltip)
            }

            // Re-render Modified button (only if there are modified files)
            if viewModel.modifiedRenderCount > 0 {
                Button(action: {
                    viewModel.onRenderModified?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Modified (\(viewModel.modifiedRenderCount))")
                            .font(.system(size: 13))
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("Re-render \(viewModel.modifiedRenderCount) modified OCF file\(viewModel.modifiedRenderCount == 1 ? "" : "s")")
            }
        }
    }

    private var renderButtonLabel: String {
        if viewModel.selectedRenderCount > 0 {
            return "Render \(viewModel.selectedRenderCount)"
        } else {
            return "Render All"
        }
    }

    private var renderButtonTooltip: String {
        if viewModel.selectedRenderCount > 0 {
            return "Render \(viewModel.selectedRenderCount) selected OCF file\(viewModel.selectedRenderCount == 1 ? "" : "s")"
        } else {
            return "Render all \(viewModel.totalRenderableCount) OCF files"
        }
    }
}

// MARK: - Preview

#if DEBUG
struct StatusBarView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            Spacer()

            // Idle state
            StatusBarView(viewModel: {
                let vm = StatusBarViewModel()
                vm.statusText = "Ready • Last: Rendered 12 items (2 minutes ago)"
                return vm
            }())

            // Rendering state
            StatusBarView(viewModel: {
                let vm = StatusBarViewModel()
                vm.updateRenderProgress(
                    currentItem: 3,
                    totalItems: 12,
                    fileName: "A001C003_230515_R2DN.mov",
                    progress: "67.5%"
                )
                vm.isExpanded = true
                return vm
            }())

            // Import state
            StatusBarView(viewModel: {
                let vm = StatusBarViewModel()
                vm.updateImportProgress(
                    currentFile: 45,
                    totalFiles: 100,
                    fileName: "Segment_045.mov"
                )
                return vm
            }())
        }
        .frame(width: 800, height: 400)
    }
}
#endif
