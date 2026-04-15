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

    // Returns the file modification date if this segment was modified after last print, nil otherwise
    private var modifiedFileDate: Date? {
        let lastPrintDate: Date?
        switch project.model.printStatus[ocfFileName] {
        case .printed(let date, _):
            lastPrintDate = date
        case .needsReprint(let date, _):
            lastPrintDate = date
        case .notPrinted, nil:
            return nil
        }
        guard let printDate = lastPrintDate else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(
            atPath: linkedSegment.segment.url.path)
        if let fileModDate = attrs?[.modificationDate] as? Date, fileModDate > printDate {
            return fileModDate
        }
        return nil
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
        HStack(alignment: .top, spacing: 12) {
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

            // RIGHT: badges, timecode, and modified status — trailing aligned
            VStack(alignment: .trailing, spacing: 2) {
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
            }

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
                || project.getManualLinkOverride(segmentFileName: linkedSegment.segment.fileName)
                    != nil
            {
                Button(action: {
                    project.removeManualLinkOverride(
                        segmentFileName: linkedSegment.segment.fileName)
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
    }

}

// MARK: - Low Confidence Segment Row

struct LowConfidenceSegmentRowView: View {
    let linkedSegment: LinkedSegment
    let availableOCFs: [MediaFileInfo]
    let project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    var onLinkConfirmed: (() -> Void)?

    @State private var selectedOCFName: String?
    @State private var isLinked: Bool = false

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        linkedSegment.segment.isVFX
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.red)
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

            // Resolution controls
            HStack(spacing: 12) {
                if isLinked, let ocfName = selectedOCFName {
                    // Show linked status with edit button
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .foregroundColor(.green)
                            .font(.system(size: 12))

                        Text("Linked to: \(ocfName)")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: {
                            isLinked = false
                        }) {
                            Text("Change")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.blue)
                    }
                } else {
                    // Show dropdown and link button
                    HStack(spacing: 8) {
                        Text("Link to:")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Picker("", selection: $selectedOCFName) {
                            Text("Select OCF...").tag(nil as String?)
                            ForEach(availableOCFs, id: \.fileName) { ocf in
                                Text(ocf.fileName).tag(ocf.fileName as String?)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 200)

                        Button(action: {
                            if let ocfName = selectedOCFName {
                                project.setManualLinkOverride(
                                    segmentFileName: linkedSegment.segment.fileName,
                                    ocfFileName: ocfName
                                )
                                projectManager.saveProject(project)
                                isLinked = true
                                NSLog(
                                    "📌 Manual link: \(linkedSegment.segment.fileName) → \(ocfName)")

                                // Trigger re-linking to move segment to linked OCF
                                onLinkConfirmed?()
                            }
                        }) {
                            Text("Confirm Link")
                                .font(.caption)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(selectedOCFName == nil)
                    }
                }
            }
            .padding(.leading, 32)
        }
        .onAppear {
            // Check if there's already a manual override
            if let existingOverride = project.getManualLinkOverride(
                segmentFileName: linkedSegment.segment.fileName)
            {
                selectedOCFName = existingOverride
                isLinked = true
            } else {
                // Suggest best match from available OCFs
                selectedOCFName = suggestBestMatch()
            }
        }
    }

    private func suggestBestMatch() -> String? {
        // Find OCF with matching resolution, frame rate, and filename similarity
        guard let segmentRes = linkedSegment.segment.effectiveDisplayResolution,
            let segmentFR = linkedSegment.segment.frameRate
        else {
            return availableOCFs.first?.fileName
        }

        let segmentNameLower = linkedSegment.segment.fileNameLower

        // First try: Look for filename match + tech specs match
        let filenameMatch = availableOCFs.first { ocf in
            guard let ocfRes = ocf.effectiveDisplayResolution,
                let ocfFR = ocf.frameRate
            else {
                return false
            }

            let ocfBaseName = (ocf.fileName as NSString).deletingPathExtension
            let ocfBaseNameLower = ocfBaseName.lowercased()
            let hasFilenameMatch = segmentNameLower.contains(ocfBaseNameLower)

            return hasFilenameMatch && segmentRes.width == ocfRes.width
                && segmentRes.height == ocfRes.height
                && FrameRateManager.areFrameRatesCompatible(segmentFR, ocfFR)
        }

        if let match = filenameMatch {
            return match.fileName
        }

        // Second try: Just tech specs match (no filename requirement)
        let techMatch = availableOCFs.first { ocf in
            guard let ocfRes = ocf.effectiveDisplayResolution,
                let ocfFR = ocf.frameRate
            else {
                return false
            }

            return segmentRes.width == ocfRes.width && segmentRes.height == ocfRes.height
                && FrameRateManager.areFrameRatesCompatible(segmentFR, ocfFR)
        }

        return techMatch?.fileName ?? availableOCFs.first?.fileName
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
