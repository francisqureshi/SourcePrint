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
    @ObservedObject var project: ProjectViewModel

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        linkedSegment.segment.isVFX
    }

    // Online/offline/updated status
    private var isOffline: Bool {
        project.model.offlineMediaFiles.contains(linkedSegment.segment.fileName)
    }

    private var modificationDate: Date? {
        project.model.segmentModificationDates[linkedSegment.segment.fileName]
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
        HStack(spacing: 4) {
            Image(systemName: confidenceIcon)
                .foregroundColor(confidenceColor)
                .frame(width: 16)

            Image(systemName: "film")
                .foregroundColor(AppTheme.segmentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(linkedSegment.segment.fileName)
                        .font(.body)
                        .foregroundColor(isOffline ? .red : .primary)

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

                    // Online/Offline/Updated status badge
                    if isOffline {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.red)
                            Text("OFFLINE")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appError)
                        .cornerRadius(3)
                    } else if let modDate = modificationDate {
                        HStack(spacing: 2) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 6))
                                .foregroundColor(.yellow)
                            Text("UPDATED")
                                .font(.caption2)
                                .fontWeight(.bold)
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appWarning)
                        .cornerRadius(3)
                    }
                }

                HStack {
                    HStack(spacing: 4) {
                        ForEach(formatLinkMethodBadges(linkedSegment.linkMethod), id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.appBackgroundBadge)
                                .cornerRadius(3)
                        }
                    }
                    if let startTC = linkedSegment.segment.sourceTimecode,
                       let endTC = linkedSegment.segment.endTimecode {
                        Text("•")
                        Text("\(startTC) - \(endTC)")
                            .monospacedDigit()
                    }
                    // Show modification date for updated files
                    if let modDate = modificationDate {
                        Text("•")
                        Text("Updated: \(formatDate(modDate))")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.leading, 20)
        .opacity(isOffline ? 0.6 : 1.0)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Low Confidence Segment Row

struct LowConfidenceSegmentRowView: View {
    let linkedSegment: LinkedSegment

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        linkedSegment.segment.isVFX
    }

    var body: some View {
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
                        ForEach(formatLinkMethodBadges(linkedSegment.linkMethod), id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.appBackgroundBadge)
                                .cornerRadius(3)
                        }
                    }
                    if let startTC = linkedSegment.segment.sourceTimecode,
                       let endTC = linkedSegment.segment.endTimecode {
                        Text("•")
                        Text("\(startTC) - \(endTC)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Text("Needs Review")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.2))
                .cornerRadius(4)
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
                        ForEach(formatLinkMethodBadges(linkedSegment.linkMethod), id: \.self) { badge in
                            Text(badge)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Color.appBackgroundBadge)
                                .cornerRadius(3)
                        }
                    }
                    if let startTC = linkedSegment.segment.sourceTimecode,
                       let endTC = linkedSegment.segment.endTimecode {
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
                ForEach(sortedByTimecode(parent.children), id: \.segment.fileName) { linkedSegment in
                    LinkedSegmentRowView(linkedSegment: linkedSegment)
                        .padding(.leading, 20)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
