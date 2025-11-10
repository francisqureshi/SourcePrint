//
//  MediaFileTableView.swift
//  SourcePrint
//
//  Professional NLE-style table view for media files with sortable columns
//

import SourcePrintCore
import SwiftUI

struct MediaFileTableView: View {
    let files: [MediaFileInfo]
    let type: MediaType
    let selectedFiles: Binding<Set<String>>
    let onVFXToggle: ((String, Bool) -> Void)?
    let onRemoveFiles: ([String]) -> Void

    @State private var sortOrder = [KeyPathComparator(\MediaFileInfo.fileName)]
    @State private var selection = Set<String>()

    enum MediaType {
        case ocf, segment

        var displayName: String {
            switch self {
            case .ocf: return "Original Camera Files"
            case .segment: return "Graded Segments"
            }
        }

        var icon: String {
            switch self {
            case .ocf: return "film.fill"
            case .segment: return "film"
            }
        }

        var color: Color {
            switch self {
            case .ocf: return AppTheme.ocfColor
            case .segment: return AppTheme.segmentColor
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            tableView
        }
        .onDeleteCommand {
            if !selection.isEmpty {
                onRemoveFiles(Array(selection))
            }
        }
    }

    private var headerView: some View {
        HStack {
            Image(systemName: type.icon)
                .foregroundColor(type.color)
            Text("\(type.displayName) (\(files.count))")
                .font(.headline)
            Spacer()
        }
        .padding()
        .background(Color.appBackgroundSecondary)
    }

    private var tableView: some View {
        List(files, id: \.fileName, selection: $selection) { file in
            MediaFileTableRowView(
                file: file.toDisplayInfo(),
                type: type,
                onVFXToggle: onVFXToggle
            )
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { items in
            if items.count == 1, let fileName = items.first,
                let file = files.first(where: { $0.fileName == fileName }),
                type == .segment
            {
                Button {
                    onVFXToggle?(file.fileName, !file.isVFX)
                } label: {
                    Label(
                        file.isVFX ? "Unmark as VFX Shot" : "Mark as VFX Shot",
                        systemImage: file.isVFX ? "wand.and.stars.slash" : "wand.and.stars")
                }

                Divider()
            }

            Button("Remove from Project", systemImage: "trash") {
                onRemoveFiles(Array(items))
            }
            .foregroundColor(.red)
            .disabled(items.isEmpty)
        } primaryAction: { items in
            // Double-click action could be added here
        }
        .onChange(of: selection) { oldValue, newValue in
            selectedFiles.wrappedValue = newValue
        }
    }
}

struct MediaFileTableRowView: View {
    let file: DisplayMediaInfo
    let type: MediaFileTableView.MediaType
    let onVFXToggle: ((String, Bool) -> Void)?

    var body: some View {
        VStack(spacing: 4) {
            // Main row with file name and key info
            HStack(spacing: 12) {
                // File icon and VFX indicator
                HStack(spacing: 4) {
                    Image(systemName: type.icon)
                        .foregroundColor(type.color)
                        .frame(width: 16)

                    if file.isVFX && type == .segment {
                        Image(systemName: "wand.and.stars")
                            .foregroundColor(.purple)
                            .frame(width: 14)
                    }
                }
                .frame(width: 36, alignment: .leading)

                // File name
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(file.fileName)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.medium)

                        Spacer()

                        if file.isVFX && type == .segment {
                            Text("VFX")
                                .font(.caption)
                                .fontWeight(.medium)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.appBackgroundBadge)
                                .foregroundColor(Color.appVfxShot)
                                .cornerRadius(3)
                        }
                    }

                    // Metadata row
                    HStack(spacing: 1) {
                        // Duration
                        Text(file.durationDisplay)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Frame rate
                        Text(file.frameRateDisplay)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Resolution
                        Text(file.resolutionDisplay)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        // Timecode
                        if let timecode = file.sourceTimecode {
                            Text(timecode)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        // Media type badge
                        Text(file.mediaTypeDisplay)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.appBackgroundBadge)
                            .cornerRadius(3)
                    }
                }

                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

}

#Preview {
    // Create sample DisplayMediaInfo for preview
    let sampleFile = DisplayMediaInfo(
        fileName: "Segment_001_VFX.mov",
        url: URL(fileURLWithPath: "/path/to/file2.mov"),
        resolution: Resolution(width: 3840, height: 2160),
        displayResolution: Resolution(width: 3840, height: 2160),
        sampleAspectRatio: "1:1",
        frameRateDisplay: "59.940fps (60000/1001)",
        frameRateValue: 59.94,
        isDropFrame: true,
        sourceTimecode: "01:00:00:00",
        endTimecode: "01:00:10:00",
        durationInFrames: 600,
        durationSeconds: 10.01,
        reelName: nil,
        isInterlaced: false,
        fieldOrder: "progressive",
        mediaType: .gradedSegment,
        isVFXShot: true
    )

    VStack {
        Text("Preview of MediaFileTableRowView")
            .font(.headline)

        MediaFileTableRowView(
            file: sampleFile,
            type: .segment,
            onVFXToggle: { fileName, isVFX in
                print("Toggle VFX for \(fileName): \(isVFX)")
            }
        )
    }
    .frame(height: 400)
}

