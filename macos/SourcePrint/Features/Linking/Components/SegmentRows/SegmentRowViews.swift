//
//  SegmentRowViews.swift
//  SourcePrint
//
//  Segment row components for linking view
//

import SourcePrintCore
import SwiftUI

// MARK: - Tree Linked Segment Row

struct TreeLinkedSegmentRowView: View {
    let linkedSegment: LinkedSegment
    let isLast: Bool
    let ocfFileName: String
    @ObservedObject var project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    var onUnlink: (() -> Void)?

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        linkedSegment.segment.isVFX
    }

    // Online/offline/updated status
    private var isOffline: Bool {
        project.model.offlineMediaFiles.contains(linkedSegment.segment.fileName)
    }

    @State private var modifiedFileDate: Date?

    private struct ModificationCheck: Equatable {
        let url: URL
        let printDate: Date?
        let trackedDate: Date?
        let isOffline: Bool
    }

    private var modificationCheck: ModificationCheck {
        let printDate: Date?
        switch project.model.printStatus[ocfFileName] {
        case .printed(let date, _), .needsReprint(let date, _): printDate = date
        default: printDate = nil
        }
        return ModificationCheck(url: linkedSegment.segment.url, printDate: printDate,
                                 trackedDate: project.model.segmentModificationDates[linkedSegment.segment.fileName],
                                 isOffline: isOffline)
    }

    private static let modifiedDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yy @ HH:mm:ss"
        return f
    }()

    var confidenceColor: Color {
        switch linkedSegment.linkConfidence {
        case .high: return Color.white.opacity(0.3)
        case .medium: return AppTheme.warning
        case .low: return AppTheme.error
        case .none: return .gray
        }
    }

    var confidenceIcon: String {
        switch linkedSegment.linkConfidence {
        case .high: return "checkmark.circle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "questionmark.circle.fill"
        case .none: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // LEFT: confidence + film icons, filename as label text
            Label {
                Text(linkedSegment.segment.fileName)
                    .font(.caption)
                    .foregroundColor(isOffline ? .red : .primary)
                    .contextMenu {
                        Button("Copy Filename") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                linkedSegment.segment.fileName, forType: .string)
                        }
                    }
            } icon: {
                HStack(spacing: 2) {
                    Image(systemName: confidenceIcon)
                        .foregroundColor(confidenceColor)
                    Image(systemName: "film")
                        .foregroundColor(AppTheme.segmentColor)
                }
                .font(.caption)
            }

            Spacer()

            // MIDDLE: modified badge — shown inline when file changed since last print
            if let modDate = modifiedFileDate {
                Text("MODIFIED • \(Self.modifiedDateFormatter.string(from: modDate))")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(AppTheme.warning.opacity(0.15))
                    .foregroundColor(AppTheme.warning)
                    .cornerRadius(3)
            }

            // RIGHT: badges and timecode — trailing aligned
            HStack(spacing: 4) {
                    if isVFXShot {
                        Text("VFX")
                            .fontWeight(.medium)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appBackgroundBadge)
                            .foregroundColor(Color.appVfxShot)
                            .cornerRadius(3)
                    }
                    if isOffline {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.red)
                            Text("OFFLINE")
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appError)
                        .cornerRadius(3)
                    }
                    ForEach(formatLinkMethodBadges(linkedSegment.linkMethod), id: \.self) { badge in
                        Text(badge)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appBackgroundBadge)
                            .cornerRadius(3)
                    }
                    if let startTC = linkedSegment.segment.sourceTimecode,
                        let endTC = linkedSegment.segment.endTimecode
                    {
                        Text("•")
                        Text("\(startTC) - \(endTC)")
                            .monospacedDigit()
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)

            // Reveal in Finder
            Button(action: {
                NSWorkspace.shared.selectFile(
                    linkedSegment.segment.url.path,
                    inFileViewerRootedAtPath: ""
                )
            }) {
                Image(systemName: "folder")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            // Unlink (manual links only)
            if linkedSegment.linkMethod == "manual"
                || project.getManualLinkOverride(segmentURL: linkedSegment.segment.url)
                    != nil
            {
                Button(action: {
                    project.removeManualLinkOverride(
                        segmentURL: linkedSegment.segment.url)
                    projectManager.saveProject(project)
                    onUnlink?()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "link.badge.minus")
                            .font(.system(size: 14))
                        Text("Unlink")
                            .font(.caption)
                    }
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .help("Remove manual link")
            }
        }
        .opacity(isOffline ? 0.6 : 1.0)
        .task(id: modificationCheck) {
            let check = modificationCheck
            modifiedFileDate = nil
            guard let printDate = check.printDate, !check.isOffline else { return }
            let date = await Task.detached(priority: .utility) {
                try? FileSystemOperations.getModificationDate(for: check.url).get()
            }.value
            guard !Task.isCancelled, let date, date > printDate else { return }
            modifiedFileDate = date
        }
    }

}

// MARK: - Low Confidence Segment Row

struct LowConfidenceSegmentRowView: View {
    let linkedSegment: LinkedSegment
    let availableOCFs: [MediaFileInfo]
    @ObservedObject var project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    var onLinkConfirmed: (() -> Void)?
    @State private var selectedOCFURL: URL?

    private var candidates: [MediaFileInfo] {
        SegmentOCFLinker().validCandidates(for: linkedSegment.segment, in: availableOCFs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(linkedSegment.segment.fileName, systemImage: "questionmark.circle.fill")
                .font(.headline)
                .help(linkedSegment.segment.url.path)
            Text("\(candidates.count) valid candidate\(candidates.count == 1 ? "" : "s") · matching resolution, FPS and timecode range")
                .font(.caption).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text("No valid candidates. Check the media metadata and link again.")
                    .font(.caption).foregroundStyle(.red)
            } else {
                Picker("Valid OCF candidates", selection: $selectedOCFURL) {
                    ForEach(candidates, id: \.url) { ocf in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(ocf.fileName)
                            Text(ocf.url.deletingLastPathComponent().path)
                                .font(.caption).foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .help(ocf.url.path)
                        .tag(ocf.url as URL?)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            HStack {
                Spacer()
                Button("Confirm Link") {
                    guard let url = selectedOCFURL,
                          project.setManualLinkOverride(segmentURL: linkedSegment.segment.url, ocfURL: url) else { return }
                    projectManager.saveProject(project)
                    onLinkConfirmed?()
                }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .disabled(!candidates.contains(where: { $0.url == selectedOCFURL }))
            }
        }
        .padding(.vertical, 6)
        .task(id: candidates.map { $0.url.path }.joined(separator: "|") + (project.model.preferredOCFFolder?.path ?? "")) {
            let existing = project.getManualLinkOverride(segmentURL: linkedSegment.segment.url)
            selectedOCFURL = candidates.first(where: { $0.url == existing })?.url
                ?? SegmentOCFLinker().preferredCandidate(for: linkedSegment.segment, in: availableOCFs,
                    folder: project.model.preferredOCFFolder)?.url
        }
    }
}

// MARK: - Linked Segment Row

struct LinkedSegmentRowView: View {
    let linkedSegment: LinkedSegment

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        linkedSegment.segment.isVFX
    }

    var confidenceColor: Color {
        switch linkedSegment.linkConfidence {
        case .high: return Color.white.opacity(0.3)
        case .medium: return AppTheme.warning
        case .low: return AppTheme.error
        case .none: return .gray
        }
    }

    var confidenceIcon: String {
        switch linkedSegment.linkConfidence {
        case .high: return "checkmark.circle.fill"
        case .medium: return "exclamationmark.circle.fill"
        case .low: return "questionmark.circle.fill"
        case .none: return "xmark.circle.fill"
        }
    }

    var body: some View {
        HStack {
            Image(systemName: confidenceIcon)
                .foregroundColor(confidenceColor)
                .frame(width: 16)

            Image(systemName: "film")
                .foregroundColor(AppTheme.segmentColor)
                .frame(width: 16)

            // VFX indicator
            if isVFXShot {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.purple)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(linkedSegment.segment.fileName)
                        .font(.body)

                    // VFX badge
                    if isVFXShot {
                        Text("VFX")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appBackgroundBadge)
                            .foregroundColor(Color.appVfxShot)
                            .cornerRadius(3)
                    }
                }

                HStack {
                    HStack(spacing: 4) {
                        ForEach(formatLinkMethodBadges(linkedSegment.linkMethod), id: \.self) {
                            badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.appBackgroundBadge)
                                .cornerRadius(3)
                        }
                    }
                    if let startTC = linkedSegment.segment.sourceTimecode,
                        let endTC = linkedSegment.segment.endTimecode
                    {
                        Text("•")
                        Text("\(startTC) - \(endTC)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
    }
}

// MARK: - OCF Parent Row

struct OCFParentRowView: View {
    let parent: OCFParent
    let project: Project
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading) {
            // OCF Parent Row
            HStack {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                Image(systemName: "film.fill")
                    .foregroundColor(AppTheme.ocfColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(parent.ocf.fileName)
                        .font(.body)
                        .fontWeight(.medium)

                    HStack {
                        Text("\(parent.childCount) linked segments")
                            .monospacedDigit()
                        Text("•")
                        if let fps = parent.ocf.frameRate {
                            Text("\(fps.floatValue, specifier: "%.3f") fps")
                                .monospacedDigit()
                        }
                        if let startTC = parent.ocf.sourceTimecode {
                            Text("•")
                            Text("TC: \(startTC)")
                                .monospacedDigit()
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                Spacer()
            }

            // Children Segments (when expanded)
            if isExpanded && parent.hasChildren {
                ForEach(sortedByTimecode(parent.children), id: \.segment.fileName) {
                    linkedSegment in
                    LinkedSegmentRowView(linkedSegment: linkedSegment)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
