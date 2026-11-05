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

    /// Keep the common parent name for context and enough suffix to distinguish every location.
    private func candidateFolder(_ url: URL) -> String {
        let folders = candidates.map { $0.url.deletingLastPathComponent().pathComponents }
        let current = url.deletingLastPathComponent().pathComponents
        var shared = 0
        while shared < current.count, folders.allSatisfy({ $0.count > shared && $0[shared] == current[shared] }) {
            shared += 1
        }
        return current.dropFirst(max(1, shared - 1)).joined(separator: "/")
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
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("Choose")
                        Text("OCF filename")
                        Text("Folder")
                        Text("Reveal")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(candidates, id: \.url) { ocf in
                        GridRow {
                            Button {
                                selectedOCFURL = ocf.url
                            } label: {
                                Image(systemName: selectedOCFURL == ocf.url ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedOCFURL == ocf.url ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Choose \(ocf.fileName) in \(candidateFolder(ocf.url))")
                            .accessibilityValue(selectedOCFURL == ocf.url ? "Selected" : "Not selected")
                            Text(ocf.fileName)
                                .lineLimit(1).truncationMode(.middle)
                                .help(ocf.url.path)
                            Text(candidateFolder(ocf.url))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .help(ocf.url.deletingLastPathComponent().path)
                            Button {
                                NSWorkspace.shared.selectFile(ocf.url.path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Reveal in Finder")
                            .accessibilityLabel("Reveal \(ocf.fileName) in Finder")
                        }
                        .padding(.vertical, 3)
                    }
                }

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

// Native outline keeps candidate selection independent from the highlighted inspection row.
struct MatchReviewOutline: NSViewRepresentable {
    let grades: [MediaFileInfo]
    let unmatchedGrades: [MediaFileInfo]
    let unmatchedOCFs: [MediaFileInfo]
    let originals: [MediaFileInfo]
    let choices: [URL: URL]
    var onChoose: (URL, URL) -> Void
    var onInspect: (URL?) -> Void

    final class Node: NSObject {
        let file: MediaFileInfo
        let grade: URL?
        let status: String
        let key: String
        var children: [Node] = []
        init(_ file: MediaFileInfo, grade: URL?, status: String, key: String) {
            self.file = file; self.grade = grade; self.status = status; self.key = key
        }
    }
    final class ActionButton: NSButton {
        var actionBlock: (() -> Void)?
        @objc func runAction() { actionBlock?() }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let table = NSOutlineView()
        table.headerView = NSTableHeaderView()
        table.rowHeight = 26
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for (name, width) in [("Name", 260.0), ("Choose", 60.0), ("Folder", 210.0), ("Status", 130.0), ("Resolution", 100.0), ("FPS", 65.0), ("Start TC", 110.0), ("End TC", 110.0), ("Reveal", 55.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(name))
            column.title = name; column.width = width; column.minWidth = 45
            column.resizingMask = .userResizingMask
            table.addTableColumn(column)
        }
        table.outlineTableColumn = table.tableColumns.first
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        scroll.documentView = table
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        context.coordinator.table = table
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(self)
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: MatchReviewOutline
        weak var table: NSOutlineView?
        var roots: [Node] = []
        var signature = ""
        var rebuilding = false
        init(_ parent: MatchReviewOutline) { self.parent = parent }
        func update(_ next: MatchReviewOutline) {
            parent = next
            guard let table else { return }
            let linker = SegmentOCFLinker()
            let nextRoots = next.grades.map { grade -> Node in
                let candidates = linker.validCandidates(for: grade, in: next.originals)
                let node = Node(grade, grade: grade.url, status: "\(candidates.count) candidates", key: "grade|\(grade.url.path)")
                node.children = candidates.map { Node($0, grade: grade.url, status: "Valid candidate", key: "\(grade.url.path)|\($0.url.path)") }
                return node
            } + next.unmatchedGrades.map { Node($0, grade: nil, status: "Unmatched grade", key: "unmatched|\($0.url.path)") }
              + next.unmatchedOCFs.map { Node($0, grade: nil, status: "Unmatched OCF", key: "ocf|\($0.url.path)") }
            let nextSignature = nextRoots.flatMap { [$0.key] + $0.children.map(\.key) }.joined(separator: "\n")
            if nextSignature == signature {
                table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<table.numberOfRows), columnIndexes: IndexSet(integer: 1))
                return
            }
            rebuilding = true
            let expanded = Set(roots.filter { table.isItemExpanded($0) }.map(\.key))
            let known = Set(roots.map(\.key))
            let selected = (table.item(atRow: table.selectedRow) as? Node)?.key
            roots = nextRoots; signature = nextSignature
            table.reloadData()
            for node in roots where expanded.contains(node.key) || !known.contains(node.key) { table.expandItem(node) }
            if let node = (roots + roots.flatMap(\.children)).first(where: { $0.key == selected }), table.row(forItem: node) >= 0 {
                table.selectRowIndexes(IndexSet(integer: table.row(forItem: node)), byExtendingSelection: false)
            }
            rebuilding = false
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? roots.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? roots[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !rebuilding, let table else { return }
            parent.onInspect((table.item(atRow: table.selectedRow) as? Node)?.grade)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column = tableColumn?.identifier.rawValue else { return nil }
            let file = node.file
            if column == "Reveal" || (column == "Choose" && node.status == "Valid candidate") {
                let button = ActionButton()
                button.target = button; button.action = #selector(ActionButton.runAction)
                if column == "Reveal" {
                    button.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Reveal in Finder")
                    button.isBordered = false
                    button.toolTip = "Reveal in Finder — \(file.url.path)"
                    button.actionBlock = { NSWorkspace.shared.selectFile(file.url.path, inFileViewerRootedAtPath: "") }
                } else if let grade = node.grade {
                    button.setButtonType(.radio); button.title = ""
                    button.state = parent.choices[grade] == file.url ? .on : .off
                    button.setAccessibilityLabel("Choose \(file.fileName) in \(file.url.deletingLastPathComponent().path)")
                    button.actionBlock = { [weak self] in self?.parent.onChoose(grade, file.url) }
                }
                return button
            }
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingMiddle
            text.font = .systemFont(ofSize: NSFont.systemFontSize)
            switch column {
            case "Name": text.stringValue = file.fileName; if !node.children.isEmpty { text.font = .boldSystemFont(ofSize: NSFont.systemFontSize) }
            case "Folder":
                text.stringValue = file.url.deletingLastPathComponent().pathComponents.suffix(3).joined(separator: "/")
                text.toolTip = file.url.deletingLastPathComponent().path
            case "Status": text.stringValue = node.status; if node.status == "Unmatched grade" { text.textColor = .systemRed }
            case "Resolution": text.stringValue = file.resolution.map { "\($0.width)×\($0.height)" } ?? "—"
            case "FPS": text.stringValue = String(format: "%.3f", file.frameRateFloat ?? 0)
            case "Start TC": text.stringValue = file.sourceTimecode ?? "—"
            case "End TC": text.stringValue = file.endTimecode ?? "—"
            default: break
            }
            if column == "Name" { text.toolTip = file.url.path }
            return text
        }
    }
}
