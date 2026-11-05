//
//  MediaImportTab.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import SwiftUI
import SourcePrintCore
import UniformTypeIdentifiers

struct MediaImportTab: View {
    @ObservedObject var project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    @Environment(StatusBarViewModel.self) private var statusBarVM
    @Binding var selectedTab: ProjectTab
    @State private var importingOCF = false
    @State private var isAnalyzing = false
    @State private var importNotice: String?
    @State private var showRemoveOfflineConfirmation = false
    
    @State private var confirmDuplicateCleanup = false

    private var duplicateCount: Int {
        let model = project.model
        return model.ocfFiles.count - ProjectOperations.uniqueMediaFiles(model.ocfFiles).count
            + model.segments.count - ProjectOperations.uniqueMediaFiles(model.segments).count
    }

    var body: some View {
        VStack(spacing: 20) {
            // Watch Folder Section
            WatchFolderSection(project: project)

            HStack {
                Spacer()
                Button("Find Matching OCF…", systemImage: "folder.badge.magnifyingglass") {
                    findMatchingOCF()
                }
                .disabled(isAnalyzing || project.model.segments.isEmpty)
                .help("Search a footage folder for original camera files matching your graded clips")
            }
            .padding(.horizontal)

            let repeatedEntries = duplicateCount
            if repeatedEntries > 0 {
                HStack {
                    Label("\(repeatedEntries) repeated media entries", systemImage: "exclamationmark.triangle")
                    Button("Clean Up…") { confirmDuplicateCleanup = true }
                }
                .confirmationDialog("Remove repeated project entries?", isPresented: $confirmDuplicateCleanup, titleVisibility: .visible) {
                    Button("Remove Duplicate Entries", role: .destructive) {
                        project.model.ocfFiles = ProjectOperations.uniqueMediaFiles(project.model.ocfFiles)
                        project.model.segments = ProjectOperations.uniqueMediaFiles(project.model.segments)
                        project.model.linkingResult = nil
                        project.updateModified()
                        projectManager.saveProject(project)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Keep the first entry for each file path. Media files stay on disk. Link files again after cleanup.")
                }
            }

            // Offline Media Warning/Action Bar
            if !project.model.offlineMediaFiles.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("\(project.model.offlineMediaFiles.count) offline media file(s)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    Button("Remove Offline Media") {
                        showRemoveOfflineConfirmation = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
                .padding()
                .background(Color.appBackgroundBadge)
                .cornerRadius(6)
                .padding(.horizontal)
            }

            if let importNotice {
                HStack(alignment: .top) {
                    Label(importNotice, systemImage: "info.circle")
                        .font(.callout)
                        .textSelection(.enabled)
                    Spacer()
                    Button { self.importNotice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .help("Dismiss import result")
                }
                .padding(.horizontal)
            }

            if let notice = project.mediaRefreshNotice {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }

            // Media Tables
            HSplitView {
                // OCF Files Table
                MediaFileColumnTableView(
                    files: project.model.ocfFiles,
                    type: .ocf,
                    offlineFiles: project.model.offlineMediaFiles,
                    modificationDates: [:], // OCFs don't track modification dates
                    onVFXToggle: nil,
                    onRemoveFiles: { urls in
                        project.removeOCFFiles(urls)
                        projectManager.saveProject(project)
                    },
                    onImportAction: {
                        importingOCF = true
                        showImportPicker()
                    },
                    isAnalyzing: isAnalyzing,
                    onDropFiles: { importDroppedFiles($0, isOCF: true) }
                )
                .frame(minWidth: 400)

                // Segments Table
                MediaFileColumnTableView(
                    files: project.model.segments,
                    type: .segment,
                    offlineFiles: project.model.offlineMediaFiles,
                    modificationDates: project.model.segmentModificationDates,
                    onVFXToggle: { url, isVFX in
                        project.toggleSegmentVFXStatus(url, isVFX: isVFX)
                        projectManager.saveProject(project)
                    },
                    onRemoveFiles: { urls in
                        project.removeSegments(urls)
                        projectManager.saveProject(project)
                    },
                    onImportAction: {
                        importingOCF = false
                        showImportPicker()
                    },
                    isAnalyzing: isAnalyzing,
                    onDropFiles: { importDroppedFiles($0, isOCF: false) }
                )
                .frame(minWidth: 400)
            }
        }
        .confirmationDialog(
            "Remove Offline Media",
            isPresented: $showRemoveOfflineConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove \(project.model.offlineMediaFiles.count) Offline Files", role: .destructive) {
                project.removeOfflineMedia()
                projectManager.saveProject(project)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently remove all offline media files from the project. This cannot be undone.")
        }
        .task {
            while !Task.isCancelled {
                let previous = project.model.lastModified
                _ = await project.refreshGradedMedia()
                if project.model.lastModified != previous { projectManager.saveProject(project) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .onAppear {
            // Set status bar tab context
            statusBarVM.currentTab = .media

            // Wire up link button callback
            statusBarVM.onLinkFiles = {
                project.pendingLinkRequest = true
                selectedTab = .linking
            }

            // Update file counts
            updateStatusBarCounts()
        }
        .onChange(of: project.model.ocfFiles.count) { _ in
            updateStatusBarCounts()
        }
        .onChange(of: project.model.segments.count) { _ in
            updateStatusBarCounts()
        }
    }
    
    private func findMatchingOCF() {
        let panel = NSOpenPanel()
        panel.title = "Find Matching OCF"
        panel.prompt = "Search Footage"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        isAnalyzing = true
        importNotice = nil
        Task { @MainActor in
            defer { isAnalyzing = false }
            guard await project.refreshGradedMedia() else { return }
            let segments = project.model.segments
            statusBarVM.updateImportProgress(currentFile: 0, totalFiles: 0, fileName: "Searching footage…")
            let discovery: MatchingOCFDiscovery.Result
            do {
                discovery = try await MatchingOCFDiscovery.search(folder: folder, segments: segments,
                    existingOCFs: project.model.ocfFiles) { current, total, url in
                    await MainActor.run {
                        statusBarVM.updateImportProgress(currentFile: current, totalFiles: total, fileName: url.lastPathComponent)
                    }
                }
            } catch {
                statusBarVM.completeOperation(summary: "Footage search cancelled")
                return
            }
            let matches = discovery.matches
            project.addOCFFiles(matches)
            let result = SegmentOCFLinker().linkSegments(project.model.segments,
                withOCFParents: project.model.ocfFiles, manualOverrides: project.model.manualLinkOverrides, requireTimecodeMatch: true)
            project.updateLinkingResult(result)
            projectManager.saveProject(project)
            importNotice = "Added \(matches.count) matching OCF file(s). \(result.unmatchedSegments.count) graded clip(s) still unmatched. Review uncertain matches in Linking."
                + (discovery.notices.isEmpty ? "" : " " + discovery.notices.joined(separator: " "))
            statusBarVM.completeOperation(summary: "Found \(matches.count) matching OCF file(s)")
        }
    }

    private func showImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .quickTimeMovie]
        panel.title = importingOCF ? "Import OCF Files or Folders" : "Import Segment Files or Folders"
        panel.message = "Select video files and/or folders. Folders will be scanned recursively for video files."
        
        let isOCF = importingOCF
        if panel.runModal() == .OK, !panel.urls.isEmpty, !isAnalyzing {
            isAnalyzing = true
            Task { await importLocations(panel.urls, isOCF: isOCF) }
        }
    }

    private func importDroppedFiles(_ providers: [NSItemProvider], isOCF: Bool) -> Bool {
        guard !isAnalyzing, !providers.isEmpty else { return false }
        isAnalyzing = true
        importNotice = nil
        Task {
            var urls: [URL] = []
            for provider in providers {
                let url: URL? = await withCheckedContinuation { continuation in
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                        if let url = item as? URL {
                            continuation.resume(returning: url)
                        } else if let data = item as? Data {
                            continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                        } else {
                            continuation.resume(returning: nil)
                        }
                    }
                }
                if let url, url.isFileURL { urls.append(url) }
            }
            await importLocations(urls, isOCF: isOCF, unreadableDrops: providers.count - urls.count)
        }
        return true
    }

    private func importLocations(_ locations: [URL], isOCF: Bool, unreadableDrops: Int = 0) async {
        importNotice = nil
        statusBarVM.updateImportProgress(currentFile: 0, totalFiles: 0, fileName: "Scanning media…")
        let discovery = await Task.detached(priority: .userInitiated) {
            await MediaImportSelection.discover(locations)
        }.value
        var notices = discovery.notices
        if unreadableDrops > 0 { notices.append("Could not read \(unreadableDrops) dropped item(s).") }
        guard !discovery.files.isEmpty else {
            isAnalyzing = false
            let message = (["No new supported media to import."] + notices).joined(separator: " ")
            importNotice = message
            statusBarVM.completeOperation(summary: message)
            return
        }
        importMediaFiles(urls: discovery.files, isOCF: isOCF, notices: notices)
    }

    private func importMediaFiles(urls: [URL], isOCF: Bool, notices: [String] = []) {
        isAnalyzing = true

        statusBarVM.updateImportProgress(
            currentFile: 0,
            totalFiles: urls.count,
            fileName: "Starting analysis..."
        )

        Task {
            let mediaFiles = await analyzeMediaFilesInParallel(urls: urls, isOCF: isOCF)

            await MainActor.run {
                let previousCount = isOCF ? project.model.ocfFiles.count : project.model.segments.count
                if isOCF {
                    project.addOCFFiles(mediaFiles)
                } else {
                    project.addSegments(mediaFiles)
                }

                projectManager.saveProject(project)
                isAnalyzing = false

                // Update status bar with completion
                let added = (isOCF ? project.model.ocfFiles.count : project.model.segments.count) - previousCount
                let skipped = mediaFiles.count - added
                var summary = "Imported \(added) \(isOCF ? "OCF" : "segment") file\(added == 1 ? "" : "s")"
                if skipped > 0 { summary += " · Skipped \(skipped) duplicate\(skipped == 1 ? "" : "s")" }
                let analyzedURLs = Set(mediaFiles.map { $0.url.standardizedFileURL })
                let failed = urls.filter { !analyzedURLs.contains($0.standardizedFileURL) }
                if !failed.isEmpty {
                    summary += " · Could not read \(failed.count) file(s): " + failed.prefix(3).map(\.lastPathComponent).joined(separator: ", ")
                }
                importNotice = ([summary] + notices).joined(separator: " ")
                statusBarVM.completeOperation(summary: summary)
                NSLog("%@", summary)
            }
        }
    }
    
    private func analyzeMediaFilesInParallel(urls: [URL], isOCF: Bool) async -> [MediaFileInfo] {
        // For I/O-bound tasks like media analysis, we can use much higher concurrency
        let maxConcurrentTasks = min(urls.count, 50)  // Increased from CPU core count to 50
        var completedCount = 0
        let totalCount = urls.count
        var lastUpdateTime = CFAbsoluteTimeGetCurrent()
        let updateInterval: CFTimeInterval = 0.5  // Update UI every 0.5 seconds
        
        return await withTaskGroup(of: (Int, MediaFileInfo?).self, returning: [MediaFileInfo].self) { taskGroup in
            var urlIndex = 0
            
            // Start initial batch of tasks
            for _ in 0..<min(maxConcurrentTasks, urls.count) {
                let index = urlIndex
                let url = urls[index]
                urlIndex += 1
                
                taskGroup.addTask {
                    do {
                        let mediaFile = try await MediaAnalyzer().analyzeMediaFile(
                            at: url, 
                            type: isOCF ? .originalCameraFile : .gradedSegment
                        )
                        return (index, mediaFile)
                    } catch {
                        NSLog("❌ Failed to analyze \(url.lastPathComponent): \(error)")
                        return (index, nil)
                    }
                }
            }
            
            // Collect results and maintain steady concurrency
            var results: [(Int, MediaFileInfo?)] = []
            results.reserveCapacity(totalCount)  // Pre-allocate array capacity
            
            for await result in taskGroup {
                results.append(result)
                completedCount += 1
                
                // Add next task if we have more URLs to process
                if urlIndex < urls.count {
                    let index = urlIndex
                    let url = urls[index]
                    urlIndex += 1
                    
                    taskGroup.addTask {
                        do {
                            let mediaFile = try await MediaAnalyzer().analyzeMediaFile(
                                at: url, 
                                type: isOCF ? .originalCameraFile : .gradedSegment
                            )
                            return (index, mediaFile)
                        } catch {
                            NSLog("❌ Failed to analyze \(url.lastPathComponent): \(error)")
                            return (index, nil)
                        }
                    }
                }
                
                // Throttled UI updates
                let currentTime = CFAbsoluteTimeGetCurrent()
                if currentTime - lastUpdateTime >= updateInterval || completedCount == totalCount {
                    lastUpdateTime = currentTime

                    await MainActor.run {
                        let (_, mediaFile) = result
                        let fileName = mediaFile?.fileName ?? "Unknown file"

                        statusBarVM.updateImportProgress(
                            currentFile: completedCount,
                            totalFiles: totalCount,
                            fileName: fileName
                        )
                    }
                }
            }
            
            // Sort by original index and filter out failed analyses
            return results
                .sorted { $0.0 < $1.0 }
                .compactMap { $0.1 }
        }
    }
    
    private func updateStatusBarCounts() {
        statusBarVM.ocfFileCount = project.model.ocfFiles.count
        statusBarVM.segmentFileCount = project.model.segments.count
    }
}

// MARK: - Watch Folder Section

struct WatchFolderSection: View {
    @ObservedObject var project: ProjectViewModel

    var body: some View {
        HStack(spacing: 20) {
            // Left side: Toggle
            HStack(spacing: 12) {
                Toggle("Watch Folders", isOn: $project.watchFolderSettings.isEnabled)
                    .toggleStyle(SwitchToggleStyle())
                    .labelsHidden()

                Text("Watch Folders")
                    .font(.headline)
            }

            Spacer()

            // Right side: Folder selections
            HStack(spacing: 12) {
                // Grade folder compact display
                HStack(spacing: 8) {
                    Text("Grade")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .leading)

                    if let folder = project.watchFolderSettings.primaryGradeFolder {
                        Text(folder.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 120, alignment: .leading)

                        Button(action: {
                            project.watchFolderSettings.primaryGradeFolder = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Clear grade folder")
                    } else {
                        Text("No folder selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                    }

                    Button("Select") {
                        selectGradeFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appBackgroundBadge)
                .cornerRadius(6)

                // VFX folder compact display
                HStack(spacing: 8) {
                    Text("VFX")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .leading)

                    if let folder = project.watchFolderSettings.vfxFolder {
                        Text(folder.lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 120, alignment: .leading)

                        Button(action: {
                            project.watchFolderSettings.vfxFolder = nil
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .imageScale(.small)
                        }
                        .buttonStyle(.plain)
                        .help("Clear VFX folder")
                    } else {
                        Text("No folder selected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                    }

                    Button("Select") {
                        selectVFXFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.appBackgroundBadge)
                .cornerRadius(6)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.appBackgroundSecondary)
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func selectGradeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Grade Watch Folder"
        panel.message = "Files in this folder will be imported as grade segments"

        if panel.runModal() == .OK, let url = panel.url {
            project.watchFolderSettings.primaryGradeFolder = url
        }
    }

    private func selectVFXFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select VFX Watch Folder"
        panel.message = "Files in this folder will be imported as VFX segments"

        if panel.runModal() == .OK, let url = panel.url {
            project.watchFolderSettings.vfxFolder = url
        }
    }
}
