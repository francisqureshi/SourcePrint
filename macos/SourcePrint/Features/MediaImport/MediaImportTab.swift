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
    @EnvironmentObject var statusBarVM: StatusBarViewModel
    @State private var importingOCF = false
    @State private var isAnalyzing = false
    @State private var selectedOCFFiles: Set<String> = []
    @State private var selectedSegments: Set<String> = []
    @State private var showRemoveOfflineConfirmation = false
    
    var body: some View {
        VStack(spacing: 20) {
            // Watch Folder Section
            WatchFolderSection(project: project)

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
                    .buttonStyle(CompressorButtonStyle(prominent: false))
                }
                .padding()
                .background(Color.orange.opacity(0.1))
                .cornerRadius(6)
                .padding(.horizontal)
            }

            // Media Tables
            HSplitView {
                // OCF Files Table
                MediaFileColumnTableView(
                    files: project.model.ocfFiles,
                    type: .ocf,
                    selectedFiles: $selectedOCFFiles,
                    offlineFiles: project.model.offlineMediaFiles,
                    modificationDates: [:], // OCFs don't track modification dates
                    onVFXToggle: { fileName, isVFX in
                        project.toggleOCFVFXStatus(fileName, isVFX: isVFX)
                        projectManager.saveProject(project)
                    },
                    onRemoveFiles: { fileNames in
                        removeOCFFiles(fileNames)
                        selectedOCFFiles.removeAll()
                    },
                    onImportAction: {
                        importingOCF = true
                        showImportPicker()
                    },
                    isAnalyzing: isAnalyzing
                )
                .frame(minWidth: 400)

                // Segments Table
                MediaFileColumnTableView(
                    files: project.model.segments,
                    type: .segment,
                    selectedFiles: $selectedSegments,
                    offlineFiles: project.model.offlineMediaFiles,
                    modificationDates: project.model.segmentModificationDates,
                    onVFXToggle: { fileName, isVFX in
                        project.toggleSegmentVFXStatus(fileName, isVFX: isVFX)
                        projectManager.saveProject(project)
                    },
                    onRemoveFiles: { fileNames in
                        removeSegments(fileNames)
                        selectedSegments.removeAll()
                    },
                    onImportAction: {
                        importingOCF = false
                        showImportPicker()
                    },
                    isAnalyzing: isAnalyzing
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
    }
    
    private func showImportPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .quickTimeMovie]
        panel.title = importingOCF ? "Import OCF Files or Folders" : "Import Segment Files or Folders"
        panel.message = "Select video files and/or folders. Folders will be scanned recursively for video files."
        
        if panel.runModal() == .OK {
            let selectedURLs = panel.urls
            guard !selectedURLs.isEmpty else { return }
            
            // Automatically handle mixed selection of files and folders
            Task {
                var allVideoFiles: [URL] = []
                
                for url in selectedURLs {
                    var isDirectory: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                        if isDirectory.boolValue {
                            // It's a folder - scan recursively
                            let folderVideoFiles = await scanFolderForVideoFiles(url)
                            allVideoFiles.append(contentsOf: folderVideoFiles)
                        } else {
                            // It's a file - add directly if it's a video file
                            let fileExtension = url.pathExtension.lowercased()
                            let videoExtensions = ["mov", "mp4", "m4v", "mxf", "prores"]
                            if videoExtensions.contains(fileExtension) {
                                allVideoFiles.append(url)
                            }
                        }
                    }
                }
                
                await MainActor.run {
                    if !allVideoFiles.isEmpty {
                        importMediaFiles(urls: allVideoFiles, isOCF: importingOCF)
                    } else {
                        print("No video files found in selection")
                    }
                }
            }
        }
    }
    
    private func scanFolderForVideoFiles(_ folderURL: URL) async -> [URL] {
        return await withTaskGroup(of: [URL].self) { taskGroup in
            taskGroup.addTask {
                await self.getAllVideoFiles(from: folderURL)
            }
            
            var allFiles: [URL] = []
            for await files in taskGroup {
                allFiles.append(contentsOf: files)
            }
            return allFiles
        }
    }
    
    private func getAllVideoFiles(from directoryURL: URL) async -> [URL] {
        do {
            return try await VideoFileDiscovery.discoverVideoFiles(in: directoryURL)
        } catch {
            print("⚠️ Failed to discover video files: \(error)")
            return []
        }
    }
    
    private func importMediaFiles(urls: [URL], isOCF: Bool) {
        isAnalyzing = true

        statusBarVM.updateImportProgress(
            currentFile: 0,
            totalFiles: urls.count,
            fileName: "Starting analysis..."
        )

        Task {
            let mediaFiles = await analyzeMediaFilesInParallel(urls: urls, isOCF: isOCF)

            await MainActor.run {
                if isOCF {
                    project.addOCFFiles(mediaFiles)
                } else {
                    project.addSegments(mediaFiles)
                }

                projectManager.saveProject(project)
                isAnalyzing = false

                // Update status bar with completion
                statusBarVM.completeOperation(summary: "Imported \(mediaFiles.count) \(isOCF ? "OCF" : "segment") file\(mediaFiles.count == 1 ? "" : "s")")

                NSLog("✅ Imported \(mediaFiles.count) \(isOCF ? "OCF" : "segment") files")
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
    
    // MARK: - File Removal Methods
    
    private func removeSelectedOCFFiles() {
        guard !selectedOCFFiles.isEmpty else { return }
        let fileNames = Array(selectedOCFFiles)
        removeOCFFiles(fileNames)
        selectedOCFFiles.removeAll()
    }
    
    private func removeSelectedSegments() {
        guard !selectedSegments.isEmpty else { return }
        let fileNames = Array(selectedSegments)
        removeSegments(fileNames)
        selectedSegments.removeAll()
    }
    
    private func removeOCFFiles(_ fileNames: [String]) {
        project.removeOCFFiles(fileNames)
        projectManager.saveProject(project)
        NSLog("🗑️ Removed \(fileNames.count) OCF file(s): \(fileNames.joined(separator: ", "))")
    }
    
    private func removeSegments(_ fileNames: [String]) {
        project.removeSegments(fileNames)
        projectManager.saveProject(project)
        NSLog("🗑️ Removed \(fileNames.count) segment(s): \(fileNames.joined(separator: ", "))")
    }
}

// MARK: - Watch Folder Section

struct WatchFolderSection: View {
    @ObservedObject var project: ProjectViewModel

    var body: some View {
        GroupBox("🔍 Watch Folders") {
            VStack(spacing: 12) {
                // Master toggle
                HStack {
                    Toggle("Enable auto-import from watch folders", isOn: $project.watchFolderSettings.isEnabled)
                        .toggleStyle(SwitchToggleStyle())
                    Spacer()
                }

                // Grade folder row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("📁 Grade Folder")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let folder = project.watchFolderSettings.primaryGradeFolder {
                            Text(folder.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text(folder.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No folder selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }

                    Spacer()

                    Button("Select Grade Folder") {
                        selectGradeFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // VFX folder row
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("🎬 VFX Folder")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let folder = project.watchFolderSettings.vfxFolder {
                            Text(folder.lastPathComponent)
                                .font(.caption)
                                .foregroundColor(.primary)
                            Text(folder.path)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } else {
                            Text("No folder selected")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                        }
                    }

                    Spacer()

                    Button("Select VFX Folder") {
                        selectVFXFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal)
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