//
//  MediaFileColumnTableView.swift
//  SourcePrint
//
//  Professional NLE-style column table view like Resolve/FCPX
//

import SwiftUI
import SourcePrintCore
import UniformTypeIdentifiers

enum MediaColumn: String, CaseIterable {
    case clipName = "Clip Name"
    case startTC = "Start TC"
    case endTC = "End TC"
    case duration = "Duration"
    case frames = "Frames"
    case type = "Type"
    case resolution = "Resolution"
    case fps = "FPS"
    case status = "Status"
}

struct MediaFileColumnTableView: View {
    let files: [MediaFileInfo]
    let type: MediaType
    let offlineFiles: Set<String>
    let modificationDates: [String: Date]
    let onVFXToggle: ((URL, Bool) -> Void)?
    let onRemoveFiles: (Set<URL>) -> Void
    let onImportAction: (() -> Void)?
    let isAnalyzing: Bool
    var onDropFiles: (([NSItemProvider]) -> Bool)? = nil
    @State private var isDropTargeted = false
    
    @State private var selection = Set<URL>()
    
    @State private var searchText = ""

    @State private var sortColumn: MediaColumn?
    @State private var ascending = true

    private var visibleFiles: [MediaFileInfo] {
        let filtered = searchText.isEmpty ? files : files.filter { $0.fileName.localizedCaseInsensitiveContains(searchText) }
        guard let sortColumn else { return filtered }
        return filtered.sorted { first, second in
            let (a, b) = ascending ? (first, second) : (second, first)
            switch sortColumn {
            case .clipName:
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            case .startTC: return (a.sourceTimecode ?? "") < (b.sourceTimecode ?? "")
            case .endTC: return (a.endTimecode ?? "") < (b.endTimecode ?? "")
            case .duration: return duration(a) < duration(b)
            case .frames: return (a.durationInFrames ?? -1) < (b.durationInFrames ?? -1)
            case .type: return a.mediaType == .originalCameraFile && b.mediaType == .gradedSegment
            case .resolution:
                let left = a.displayResolution ?? a.resolution
                let right = b.displayResolution ?? b.resolution
                return (left?.width ?? 0, left?.height ?? 0) < (right?.width ?? 0, right?.height ?? 0)
            case .fps: return (a.frameRate?.floatValue ?? 0) < (b.frameRate?.floatValue ?? 0)
            case .status: return status(a) < status(b)
            }
        }
    }

    private func duration(_ file: MediaFileInfo) -> Double {
        guard let frames = file.durationInFrames, let rate = file.frameRate?.floatValue, rate > 0 else { return -1 }
        return Double(frames) / Double(rate)
    }

    private func status(_ file: MediaFileInfo) -> (Int, Date) {
        if offlineFiles.contains(file.fileName) { return (0, .distantPast) }
        if let date = modificationDates[file.fileName] { return (1, date) }
        return (2, .distantPast)
    }

    // Column width state - user adjustable and responsive
    @State private var clipNameWidth: CGFloat = 200
    @State private var startTCWidth: CGFloat = 100
    @State private var endTCWidth: CGFloat = 100
    @State private var durationWidth: CGFloat = 80
    @State private var framesWidth: CGFloat = 70
    @State private var typeWidth: CGFloat = 80
    @State private var resolutionWidth: CGFloat = 100
    @State private var fpsWidth: CGFloat = 60
    @State private var statusWidth: CGFloat = 120
    @State private var totalWidth: CGFloat = 0

    // Minimum column widths to prevent over-shrinking
    private let minClipNameWidth: CGFloat = 120
    private let minStartTCWidth: CGFloat = 80
    private let minEndTCWidth: CGFloat = 80
    private let minDurationWidth: CGFloat = 60
    private let minFramesWidth: CGFloat = 50
    private let minTypeWidth: CGFloat = 60
    private let minResolutionWidth: CGFloat = 80
    private let minFpsWidth: CGFloat = 40
    private let minStatusWidth: CGFloat = 100

    // Computed total column width for horizontal scrolling
    private var totalColumnWidth: CGFloat {
        clipNameWidth + startTCWidth + endTCWidth + durationWidth +
        framesWidth + typeWidth + resolutionWidth + fpsWidth + statusWidth
    }
    
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
            TextField("Search \(type.displayName)", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(8)
                .onChange(of: searchText) {
                    selection.formIntersection(visibleFiles.map(\.url))
                }
            
            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        columnHeadersView
                        fileRowsView
                    }
                    .frame(minWidth: geometry.size.width, maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .contentShape(Rectangle())
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !isAnalyzing else { return false }
            return onDropFiles?(providers) ?? false
        }
        .overlay {
            if isDropTargeted && !isAnalyzing {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(AppTheme.accent.opacity(0.12))
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(AppTheme.accent, lineWidth: 2)
                    Label("Import as \(type == .ocf ? "OCF" : "graded clips")", systemImage: "arrow.down.doc")
                        .font(.headline)
                        .padding(16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                .allowsHitTesting(false)
            }
        }
        .onDeleteCommand {
            if !selection.isEmpty {
                onRemoveFiles(selection)
                selection.removeAll()
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
            
            if let importAction = onImportAction {
                Button("Import \(type == .ocf ? "OCF Files" : "Segments")...") {
                    importAction()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                .controlSize(.regular)
                .disabled(isAnalyzing)
            }
        }
        .padding()
        .background(AppTheme.backgroundSecondary)
    }
    
    private var columns: [MediaColumn] {
        MediaColumn.allCases.filter { type == .segment || $0 != .status }
    }

    private func dimensions(for column: MediaColumn) -> (Binding<CGFloat>, CGFloat) {
        switch column {
        case .clipName: return ($clipNameWidth, minClipNameWidth)
        case .startTC: return ($startTCWidth, minStartTCWidth)
        case .endTC: return ($endTCWidth, minEndTCWidth)
        case .duration: return ($durationWidth, minDurationWidth)
        case .frames: return ($framesWidth, minFramesWidth)
        case .type: return ($typeWidth, minTypeWidth)
        case .resolution: return ($resolutionWidth, minResolutionWidth)
        case .fps: return ($fpsWidth, minFpsWidth)
        case .status: return ($statusWidth, minStatusWidth)
        }
    }

    private var columnHeadersView: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                let (width, minimum) = dimensions(for: column)
                Button {
                    ascending = sortColumn == column ? !ascending : true
                    sortColumn = column
                } label: {
                    HStack(spacing: 3) {
                        Text(column.rawValue)
                        if sortColumn == column {
                            Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: width.wrappedValue - 5, height: 22, alignment: .leading)
                    .padding(.leading, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ResizeDivider { delta in
                    width.wrappedValue = max(minimum, width.wrappedValue + delta)
                }
            }

            // Filler Column (expands to fill remaining space)
            Rectangle()
                .fill(Color.appBackgroundSecondary)
                .frame(minWidth: 100, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: 22) // Full width, fixed height for compact header
        .background(Color.appBackgroundSecondary)
        .border(Color.appBackgroundDivider, width: 0.5)
    }
    
    private var fileRowsView: some View {
        List(visibleFiles, id: \.url, selection: $selection) { file in
            MediaFileColumnRowView(
                columns: columns,
                file: file.toDisplayInfo(),
                type: type,
                isOffline: offlineFiles.contains(file.fileName),
                modificationDate: modificationDates[file.fileName],
                onVFXToggle: onVFXToggle,
                columnWidths: ColumnWidths(
                    clipName: clipNameWidth,
                    startTC: startTCWidth,
                    endTC: endTCWidth,
                    duration: durationWidth,
                    frames: framesWidth,
                    type: typeWidth,
                    resolution: resolutionWidth,
                    fps: fpsWidth,
                    status: statusWidth
                )
            )
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
        .overlay {
            if !searchText.isEmpty && visibleFiles.isEmpty {
                Text("No matching files").foregroundStyle(.secondary)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDropTargeted) { providers in
            guard !isAnalyzing else { return false }
            return onDropFiles?(providers) ?? false
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
        .contextMenu(forSelectionType: URL.self) { items in
            if items.count == 1, let url = items.first,
               let file = files.first(where: { $0.url == url }),
               type == .segment {
                Button {
                    onVFXToggle?(file.url, !file.isVFX)
                } label: {
                    Label(file.isVFX ? "Unmark as VFX Shot" : "Mark as VFX Shot",
                          systemImage: file.isVFX ? "wand.and.stars.slash" : "wand.and.stars")
                }
            }

            if items.count == 1, let url = items.first {
                Button("Reveal in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }

            Button("Remove from Project", systemImage: "trash") {
                onRemoveFiles(items)
                selection.subtract(items)
            }
            .foregroundColor(.red)
            .disabled(items.isEmpty)
        }
    }
    
}

// MARK: - ColumnWidths Data Structure

struct ColumnWidths {
    let clipName: CGFloat
    let startTC: CGFloat
    let endTC: CGFloat
    let duration: CGFloat
    let frames: CGFloat
    let type: CGFloat
    let resolution: CGFloat
    let fps: CGFloat
    let status: CGFloat
}

// MARK: - ResizeDivider Component

private struct ResizeDivider: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void

    func makeNSView(context: Context) -> DividerView { DividerView() }

    func updateNSView(_ view: DividerView, context: Context) {
        view.onDrag = onDrag
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: DividerView, context: Context) -> CGSize? {
        CGSize(width: 9, height: proposal.height ?? 22)
    }

    final class DividerView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        private var lastX: CGFloat = 0

        override func draw(_ dirtyRect: NSRect) {
            NSColor.separatorColor.setFill()
            NSRect(x: floor(bounds.midX), y: bounds.midY - 8, width: 1, height: 16).fill()
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func mouseDown(with event: NSEvent) {
            lastX = event.locationInWindow.x
            NSCursor.resizeLeftRight.push()
        }

        override func mouseDragged(with event: NSEvent) {
            let x = event.locationInWindow.x
            onDrag?(x - lastX)
            lastX = x
        }

        override func mouseUp(with event: NSEvent) {
            NSCursor.pop()
        }
    }
}

struct MediaFileColumnRowView: View {
    var columns: [MediaColumn] = MediaColumn.allCases
    let file: DisplayMediaInfo
    let type: MediaFileColumnTableView.MediaType
    let isOffline: Bool
    let modificationDate: Date?
    let onVFXToggle: ((URL, Bool) -> Void)?
    let columnWidths: ColumnWidths

    private var statusView: some View {
        HStack(spacing: 4) {
            if isOffline {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.red)
                Text("Offline")
                    .font(.system(size: 11))
                    .foregroundColor(.red)
            } else if let modDate = modificationDate {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.yellow)
                Text(formatDate(modDate))
                    .font(.system(size: 11))
                    .foregroundColor(.yellow)
            } else {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.green)
                Text("Online")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @ViewBuilder
    private func cell(_ column: MediaColumn) -> some View {
        switch column {
        case .clipName:
            HStack(spacing: 4) {
                if isOffline {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .frame(width: 16)
                } else {
                    Image(systemName: type.icon)
                        .foregroundColor(type.color)
                        .frame(width: 16)
                }

                if file.isVFX && type == .segment {
                    Image(systemName: "wand.and.stars")
                        .foregroundColor(.purple)
                        .frame(width: 14)
                }

                Text(file.fileName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(isOffline ? .red : .primary)

                if isOffline {
                    Text("OFFLINE")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appError)
                        .cornerRadius(3)
                } else if file.isVFX && type == .segment {
                    Text("VFX")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appVfxShot)
                        .cornerRadius(3)
                }

                Spacer()
            }
            .frame(width: columnWidths.clipName, alignment: .leading)
            .padding(.horizontal, 4)

        case .startTC:
            Text(file.sourceTimecode ?? "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(file.sourceTimecode != nil ? .primary : .secondary)
                .frame(width: columnWidths.startTC, alignment: .leading)
                .padding(.horizontal, 4)
            
        case .endTC:
            Text(file.endTimecode ?? "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(file.endTimecode != nil ? .primary : .secondary)
                .frame(width: columnWidths.endTC, alignment: .leading)
                .padding(.horizontal, 4)
            
        case .duration:
            Text(file.durationDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.duration, alignment: .leading)
                .padding(.horizontal, 4)

        case .frames:
            Text(file.frameCountDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.frames, alignment: .leading)
                .padding(.horizontal, 4)
            
        case .type:
            Text(file.mediaTypeDisplay)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.appBackgroundBadge)
                .cornerRadius(3)
                .frame(width: columnWidths.type, alignment: .leading)
                .padding(.horizontal, 4)
            
        case .resolution:
            Text(file.resolutionDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.resolution, alignment: .leading)
                .padding(.horizontal, 4)
            
        case .fps:
            Text(String(format: "%.3f", file.frameRateValue))
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columnWidths.fps, alignment: .leading)
                .padding(.horizontal, 4)

        case .status:
            if type == .segment {
                statusView
                    .frame(width: columnWidths.status, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns, id: \.self) { column in
                cell(column)
            }

            // Filler Column (expands to fill remaining space)
            Rectangle()
                .fill(Color.clear)
                .frame(minWidth: 100, maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .opacity(isOffline ? 0.6 : 1.0)
    }
    
}

#Preview {
    let sampleFiles = [
        DisplayMediaInfo(
            fileName: "C20250825_0303.mov",
            url: URL(fileURLWithPath: "/path/to/file1.mov"),
            resolution: Resolution(width: 3840, height: 2160),
            displayResolution: Resolution(width: 3840, height: 2160),
            sampleAspectRatio: "1:1",
            frameRateDisplay: "25.000fps (25/1)",
            frameRateValue: 25.0,
            isDropFrame: false,
            sourceTimecode: "20:16:31:13",
            endTimecode: "20:17:16:01",
            durationInFrames: 1320,
            durationSeconds: 52.8,
            reelName: nil,
            isInterlaced: false,
            fieldOrder: "progressive",
            mediaType: .originalCameraFile,
            isVFXShot: false
        ),
        DisplayMediaInfo(
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
    ]
    
    VStack {
        Text("Preview of MediaFileColumnRowView")
            .font(.headline)

        MediaFileColumnRowView(
            file: sampleFiles[1], // VFX segment
            type: .segment,
            isOffline: false,
            modificationDate: Date(),
            onVFXToggle: { fileName, isVFX in
                print("Toggle VFX for \(fileName): \(isVFX)")
            },
            columnWidths: ColumnWidths(
                clipName: 200,
                startTC: 100,
                endTC: 100,
                duration: 80,
                frames: 70,
                type: 80,
                resolution: 100,
                fps: 60,
                status: 120
            )
        )
    }
    .frame(height: 400)
}
