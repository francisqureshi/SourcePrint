//
//  StatusBarView.swift
//  SourcePrint
//
//  Persistent bottom "chin" status bar with Apple Compressor styling
//

import SwiftUI

struct StatusBarView: View {
    @ObservedObject var viewModel: StatusBarViewModel

    // Apple Compressor purple accent
    private let accentColor = Color(red: 155/255, green: 89/255, blue: 182/255) // #9B59B6

    var body: some View {
        VStack(spacing: 0) {
            // Top border
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(height: 1)

            // Main content
            VStack(spacing: 0) {
                // Compact mode (always visible)
                compactView

                // Expanded mode (conditional)
                if viewModel.isExpanded {
                    expandedView
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(height: viewModel.isExpanded ? 120 : 44)
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
                    .frame(width: 200)
            }

            Spacer()

            // Right: Expand/Collapse Button
            Button(action: {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    viewModel.toggleExpanded()
                }
            }) {
                Image(systemName: viewModel.isExpanded ? "chevron.up" : "chevron.down")
                    .foregroundColor(.secondary)
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
            .help(viewModel.isExpanded ? "Collapse" : "Show Details")
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
        .background(Color(nsColor: .controlBackgroundColor))
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
                // Progress bar for determinate progress
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
