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
    let blankRushStatus: BlankRushStatus
    let mostRecentPrint: SourcePrintCore.PrintRecord?
    var publishedURL: URL? = nil
    let parent: OCFParent
    let blankRushDirectory: URL
    @State private var availability: BlankRushAvailability = .missing

    private var blankRushCheckID: String {
        // Refresh after rendering, relinking, metadata edits or changing cache folders.
        let parentData = (try? JSONEncoder().encode(parent)) ?? Data()
        return parentData.base64EncodedString() + blankRushDirectory.path
            + String(describing: blankRushStatus) + String(describing: mostRecentPrint?.id)
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

                    if case .full(let url) = availability {
                        Button(action: {
                            NSWorkspace.shared.open(url)
                        }) {
                            Image(systemName: "play.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open blank rush")
                    }
                    if case .segments(_, _, let directory) = availability {
                        Button { NSWorkspace.shared.open(directory) } label: {
                            Image(systemName: "folder").foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .help("Show blank rush segments in Finder")
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
                                Text(print.cancelled == true ? "Cancelled" : print.success ? "Completed" : "Failed")
                                    .font(.caption)
                                    .foregroundColor(print.cancelled == true ? .orange : print.success ? .green : .red)

                                Text(renderLogDateFormatter.string(from: print.date))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            Text(String(format: "%d segments · Render time %.1fs", print.segmentCount, print.duration))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .monospacedDigit()
                        }

                        if print.success {
                            Button(action: {
                                showInFinder(url: publishedURL ?? print.outputURL)
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
        .task(id: blankRushCheckID) {
            let result = await Task.detached(priority: .utility) {
                await BlankRushAvailability.inspect(parent: parent, directory: blankRushDirectory)
            }.value
            guard !Task.isCancelled else { return }
            availability = result
        }
    }

    // MARK: - Blank Rush Status

    private var blankRushStatusText: String {
        if case .inProgress = blankRushStatus { return "Creating…" }
        switch availability {
        case .notRequired: return "Not needed · Fully graded"
        case .full: return "Ready · Full blank rush"
        case .segments(let count, let frames, _):
            return "\(count) blank \(count == 1 ? "segment" : "segments") · \(frames.formatted()) frames"
        case .missing:
            if case .failed(let error) = blankRushStatus { return "Failed: \(error)" }
            return "Not Created"
        }
    }

    private var blankRushStatusColor: Color {
        if case .inProgress = blankRushStatus { return .orange }
        switch availability {
        case .full, .segments: return .green
        case .notRequired: return .secondary
        case .missing:
            if case .failed = blankRushStatus { return .red }
            return .secondary
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
