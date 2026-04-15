//
//  RenderLogSection.swift
//  SourcePrint
//
//  Render log and status section for OCF cards
//

import SourcePrintCore
import SwiftUI

private let renderLogDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "dd/MM/yyyy @ HH:mm"
    return f
}()

struct RenderLogSection: View {
    @ObservedObject var project: ProjectViewModel
    let ocfFileName: String

    // Filter print history for this specific OCF
    private var relevantPrintHistory: [SourcePrintCore.PrintRecord] {
        let baseName = (ocfFileName as NSString).deletingPathExtension
        return project.model.printHistory.filter { record in
            record.outputURL.lastPathComponent.contains(baseName)
        }.sorted { $0.date > $1.date } // Most recent first
    }

    private var mostRecentPrint: SourcePrintCore.PrintRecord? {
        relevantPrintHistory.first
    }

    private var blankRushStatus: BlankRushStatus {
        project.model.blankRushStatus[ocfFileName] ?? .notCreated
    }

    // Actual status verified against file system
    private var actualBlankRushStatus: BlankRushStatus {
        let storedStatus = project.model.blankRushStatus[ocfFileName] ?? .notCreated

        // Verify file existence for "completed" status
        if case .completed(_, let url) = storedStatus {
            if !FileManager.default.fileExists(atPath: url.path) {
                // File is missing - return .notCreated instead
                return .notCreated
            }
        }

        return storedStatus
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                // Blank Rush Status Row
                HStack(spacing: 12) {
                    Label {
                        Text("Blank Rush")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: "film.fill")
                            .foregroundColor(blankRushStatusColor)
                    }

                    Spacer()

                    Text(blankRushStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if case .completed(_, let url) = actualBlankRushStatus {
                        Button(action: {
                            NSWorkspace.shared.open(url)
                        }) {
                            Image(systemName: "play.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open blank rush")
                    }
                }

                Divider()

                // Print History Row
                HStack(spacing: 12) {
                    Label {
                        Text("Print Status")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } icon: {
                        Image(systemName: printStatusIcon)
                            .foregroundColor(printStatusColor)
                    }

                    Spacer()

                    if let print = mostRecentPrint {
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(print.success ? "Completed" : "Failed")
                                    .font(.caption)
                                    .foregroundColor(print.success ? .green : .red)

                                Text(renderLogDateFormatter.string(from: print.date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(String(format: "%d segments printed in %.1fs", print.segmentCount, print.duration))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        if print.success {
                            Button(action: {
                                showInFinder(url: print.outputURL)
                            }) {
                                Image(systemName: "folder")
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                        }
                    } else {
                        Text("Never printed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    }
                }
            }
            .padding(.vertical, 4)
        } label: {
            Label("Render Pipeline", systemImage: "gearshape.2")
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Blank Rush Status

    private var blankRushStatusText: String {
        switch actualBlankRushStatus {
        case .notCreated:
            return "Not Created"
        case .inProgress:
            return "Creating..."
        case .completed:
            return "Ready"
        case .failed(let error):
            return "Failed: \(error)"
        }
    }

    private var blankRushStatusColor: Color {
        switch actualBlankRushStatus {
        case .notCreated:
            return .secondary
        case .inProgress:
            return .orange
        case .completed:
            return Color.white.opacity(0.5)
        case .failed:
            return .red
        }
    }

    // MARK: - Print Status

    private var printStatusIcon: String {
        if let print = mostRecentPrint {
            return print.success ? "checkmark.circle.fill" : "xmark.circle.fill"
        }
        return "circle"
    }

    private var printStatusColor: Color {
        if let print = mostRecentPrint {
            return print.success ? .green : .red
        }
        return .secondary
    }

    // MARK: - Actions

    private func showInFinder(url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
}

// MARK: - Relative Date Formatter

extension RelativeDateTimeFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
