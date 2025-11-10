//
//  MediaFileColumnTableView.swift
//  SourcePrint
//
//  Professional NLE-style column table view like Resolve/FCPX
//

import SwiftUI
import SourcePrintCore

struct MediaFileColumnTableView: View {
    let files: [MediaFileInfo]
    let type: MediaType
    let selectedFiles: Binding<Set<String>>
    let offlineFiles: Set<String>
    let modificationDates: [String: Date]
    let onVFXToggle: ((String, Bool) -> Void)?
    let onRemoveFiles: ([String]) -> Void
    let onImportAction: (() -> Void)?
    let isAnalyzing: Bool
    
    @State private var selection = Set<String>()
    
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
    
    private var columnHeadersView: some View {
        HStack(spacing: 0) {
            // Clip Name Column
            HStack(spacing: 0) {
                Text("Clip Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: clipNameWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    clipNameWidth = max(clipNameWidth + delta, minClipNameWidth)
                }
            }
            
            // Start TC Column
            HStack(spacing: 0) {
                Text("Start TC")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: startTCWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    startTCWidth = max(startTCWidth + delta, minStartTCWidth)
                }
            }
            
            // End TC Column
            HStack(spacing: 0) {
                Text("End TC")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: endTCWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    endTCWidth = max(endTCWidth + delta, minEndTCWidth)
                }
            }
            
            // Duration Column
            HStack(spacing: 0) {
                Text("Duration")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: durationWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    durationWidth = max(durationWidth + delta, minDurationWidth)
                }
            }
            
            // Frames Column
            HStack(spacing: 0) {
                Text("Frames")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: framesWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    framesWidth = max(framesWidth + delta, minFramesWidth)
                }
            }
            
            // Type Column
            HStack(spacing: 0) {
                Text("Type")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: typeWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    typeWidth = max(typeWidth + delta, minTypeWidth)
                }
            }
            
            // Resolution Column
            HStack(spacing: 0) {
                Text("Resolution")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: resolutionWidth, alignment: .leading)
                    .padding(.horizontal, 4)
                
                ResizeDivider { delta in
                    resolutionWidth = max(resolutionWidth + delta, minResolutionWidth)
                }
            }
            
            // FPS Column
            HStack(spacing: 0) {
                Text("FPS")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: fpsWidth, alignment: .leading)
                    .padding(.horizontal, 4)

                ResizeDivider { delta in
                    fpsWidth = max(fpsWidth + delta, minFpsWidth)
                }
            }

            // Status Column (only for segments)
            if type == .segment {
                HStack(spacing: 0) {
                    Text("Status")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: statusWidth, alignment: .leading)
                        .padding(.horizontal, 4)

                    ResizeDivider { delta in
                        statusWidth = max(statusWidth + delta, minStatusWidth)
                    }
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
        List(files, id: \.fileName, selection: $selection) { file in
            MediaFileColumnRowView(
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
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity)
        .contextMenu(forSelectionType: String.self) { items in
            if items.count == 1, let fileName = items.first,
               let file = files.first(where: { $0.fileName == fileName }),
               type == .segment {
                Button {
                    onVFXToggle?(file.fileName, !file.isVFX)
                } label: {
                    Label(file.isVFX ? "Unmark as VFX Shot" : "Mark as VFX Shot",
                          systemImage: file.isVFX ? "wand.and.stars.slash" : "wand.and.stars")
                }
                
                Divider()
            }
            
            Button("Remove from Project", systemImage: "trash") {
                onRemoveFiles(Array(items))
            }
            .foregroundColor(.red)
            .disabled(items.isEmpty)
        }
        .onChange(of: selection) { oldValue, newValue in
            selectedFiles.wrappedValue = newValue
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

struct ResizeDivider: View {
    let onDrag: (CGFloat) -> Void
    @State private var isDragging = false
    @State private var startLocation: CGPoint = .zero
    @State private var isHovering = false
    
    var body: some View {
        ZStack {
            // Main separator line
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1, height: 16)
            
            // Drag handle icon - only visible on hover or drag
            if isHovering || isDragging {
                VStack(spacing: 1) {
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 2, height: 3)
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 2, height: 3)
                    Rectangle()
                        .fill(Color.secondary)
                        .frame(width: 2, height: 3)
                }
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 8, height: 12)
                )
            }
        }
        .overlay(
            Rectangle()
                .fill(Color.clear)
                .frame(width: 20, height: 24) // Even wider hit target
                .cursor(.resizeLeftRight)
        )
        .contentShape(Rectangle().size(width: 20, height: 24))
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .gesture(
            DragGesture(coordinateSpace: .local)
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        startLocation = value.startLocation
                    }
                    let delta = value.translation.width
                    onDrag(delta)
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

struct MediaFileColumnRowView: View {
    let file: DisplayMediaInfo
    let type: MediaFileColumnTableView.MediaType
    let isOffline: Bool
    let modificationDate: Date?
    let onVFXToggle: ((String, Bool) -> Void)?
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
                VStack(alignment: .leading, spacing: 0) {
                    Text("Updated")
                        .font(.system(size: 11))
                        .foregroundColor(.yellow)
                    Text(formatDate(modDate))
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
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

    var body: some View {
        HStack(spacing: 0) {
            // Clip Name Column
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

            // Start TC Column
            Text(file.sourceTimecode ?? "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(file.sourceTimecode != nil ? .primary : .secondary)
                .frame(width: columnWidths.startTC, alignment: .leading)
                .padding(.horizontal, 4)
            
            // End TC Column
            Text(file.endTimecode ?? "—")
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .foregroundColor(file.endTimecode != nil ? .primary : .secondary)
                .frame(width: columnWidths.endTC, alignment: .leading)
                .padding(.horizontal, 4)
            
            // Duration Column
            Text(file.durationDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.duration, alignment: .leading)
                .padding(.horizontal, 4)

            // Frames Column
            Text(file.frameCountDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.frames, alignment: .leading)
                .padding(.horizontal, 4)
            
            // Type Column
            Text(file.mediaTypeDisplay)
                .font(.caption)
                .lineLimit(1)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(Color.appBackgroundBadge)
                .cornerRadius(3)
                .frame(width: columnWidths.type, alignment: .leading)
                .padding(.horizontal, 4)
            
            // Resolution Column
            Text(file.resolutionDisplay)
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: columnWidths.resolution, alignment: .leading)
                .padding(.horizontal, 4)
            
            // FPS Column
            Text(String(format: "%.3f", file.frameRateValue))
                .font(.system(size: 12))
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columnWidths.fps, alignment: .leading)
                .padding(.horizontal, 4)

            // Status Column (only for segments)
            if type == .segment {
                statusView
                    .frame(width: columnWidths.status, alignment: .leading)
                    .padding(.horizontal, 4)
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
