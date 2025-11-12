//
//  ProjectManager.swift
//  ProResWriter
//
//  Created by Claude on 25/08/2025.
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers
import SourcePrintCore

// MARK: - Project Manager

class ProjectManager: ObservableObject {

    // MARK: - Published Properties
    @Published var projects: [ProjectViewModel] = []
    @Published var currentProject: ProjectViewModel?
    @Published var recentProjects: [ProjectViewModel] = []
    
    // MARK: - File Management
    private let documentsDirectory: URL
    private let projectsDirectory: URL

    // Serial queue for thread-safe project saves
    private let saveQueue = DispatchQueue(label: "com.sourceprint.projectsave", qos: .userInitiated)
    
    // MARK: - Initialization
    init() {
        NSLog("🚀 ProjectManager init called!")
        // Set up project storage directory
        documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        projectsDirectory = documentsDirectory.appendingPathComponent("ProResWriter Projects")
        
        print("📁 Projects directory: \(projectsDirectory.path)")
        
        // Ensure projects directory exists
        try? FileManager.default.createDirectory(at: projectsDirectory, withIntermediateDirectories: true)
        
        // Load existing projects
        loadProjects()
        print("📊 Loaded \(projects.count) projects, \(recentProjects.count) recent")
    }
    
    // MARK: - Project Creation
    func createNewProject(name: String, outputDirectory: URL, blankRushDirectory: URL) -> ProjectViewModel {
        let viewModel = ProjectViewModel(
            name: name,
            outputDirectory: outputDirectory,
            blankRushDirectory: blankRushDirectory
        )

        projects.append(viewModel)
        currentProject = viewModel
        updateRecentProjects(viewModel)

        // Auto-save new project
        saveProject(viewModel)

        return viewModel
    }
    
    // MARK: - Project Loading/Saving
    private func loadProjects() {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "w2" }) else {
            return
        }
        
        for url in urls {
            if let project = loadProject(from: url) {
                projects.append(project)
                
                // Add to recent projects (sorted by lastModified)
                if recentProjects.count < 10 {
                    recentProjects.append(project)
                }
            }
        }
        
        // Sort recent projects by last modified date
        recentProjects.sort { $0.model.lastModified > $1.model.lastModified }
    }
    
    private func loadProject(from url: URL) -> ProjectViewModel? {
        do {
            NSLog("📖 Loading project from: \(url.path)")
            let data = try Data(contentsOf: url)
            NSLog("📊 File data size: \(data.count) bytes")

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            // Try loading as ProjectViewModel first (new format)
            if let viewModel = try? decoder.decode(ProjectViewModel.self, from: data) {
                NSLog("✅ Successfully decoded ProjectViewModel: \(viewModel.model.name)")

                // Update project name to match filename (without extension)
                let filenameWithoutExtension = url.deletingPathExtension().lastPathComponent
                if viewModel.model.name != filenameWithoutExtension {
                    NSLog("📝 Updating project name from '\(viewModel.model.name)' to '\(filenameWithoutExtension)' (based on filename)")
                    viewModel.model.name = filenameWithoutExtension
                }

                // Set the file URL
                viewModel.model.fileURL = url

                // Validate project integrity
                let validationResult = ProjectValidator.validate(viewModel.model)
                viewModel.validationResult = validationResult

                // Clear stale linking result if needed
                if validationResult.shouldClearLinkingResult {
                    NSLog("🔄 Clearing stale linking result")
                    viewModel.model.linkingResult = nil
                    viewModel.model.updateModified()
                    saveProject(viewModel)
                }

                if !validationResult.isValid {
                    NSLog("⚠️ Project validation found \(validationResult.issues.count) issue(s):")
                    for issue in validationResult.issues {
                        NSLog("  [\(issue.severity == .error ? "ERROR" : "WARNING")] \(issue.message)")
                    }

                    // Show validation alert to user on main thread
                    DispatchQueue.main.async {
                        ProjectAlertHelper.showValidationAlert(for: validationResult, projectName: viewModel.model.name)
                    }
                }

                // Scan for existing blank rushes after loading
                viewModel.scanForExistingBlankRushes()

                // Check for modified segments and update print status
                viewModel.refreshPrintStatus()

                return viewModel
            }

            // Fall back to old Project format for backward compatibility
            NSLog("⚠️ Trying legacy Project format...")
            let oldProject = try decoder.decode(Project.self, from: data)
            NSLog("✅ Successfully decoded legacy Project: \(oldProject.name), migrating to ViewModel")

            // Migrate to ProjectViewModel
            let model = ProjectModel(
                id: oldProject.id,
                name: oldProject.name,
                createdDate: oldProject.createdDate,
                lastModified: oldProject.lastModified,
                ocfFiles: oldProject.ocfFiles,
                segments: oldProject.segments,
                linkingResult: oldProject.linkingResult,
                blankRushStatus: oldProject.blankRushStatus,
                segmentModificationDates: oldProject.segmentModificationDates,
                segmentFileSizes: oldProject.segmentFileSizes,
                offlineMediaFiles: oldProject.offlineMediaFiles,
                offlineFileMetadata: oldProject.offlineFileMetadata,
                lastPrintDate: oldProject.lastPrintDate,
                printHistory: [], // Old PrintRecord format is different, start fresh
                printStatus: oldProject.printStatus,
                outputDirectory: oldProject.outputDirectory,
                blankRushDirectory: oldProject.blankRushDirectory,
                fileURL: url
            )

            // Convert deprecated render queue to new format
            let convertedRenderQueue = oldProject.renderQueue.map { oldItem in
                SourcePrintCore.RenderQueueItem(
                    id: oldItem.id,
                    ocfFileName: oldItem.ocfFileName,
                    addedDate: oldItem.addedDate,
                    status: PersistentRenderStatus(rawValue: oldItem.status.rawValue) ?? .queued
                )
            }

            let viewModel = ProjectViewModel(
                model: model,
                renderQueue: convertedRenderQueue,
                ocfCardExpansionState: oldProject.ocfCardExpansionState,
                watchFolderSettings: oldProject.watchFolderSettings
            )

            NSLog("✅ Migration complete, saving in new format")
            // Save in new format for next time
            saveProject(viewModel)

            return viewModel
        } catch {
            NSLog("❌ Failed to load project from \(url.lastPathComponent): \(error)")
            return nil
        }
    }
    
    func saveProject(_ viewModel: ProjectViewModel, completion: ((Result<Void, Error>) -> Void)? = nil) {
        // Serialize all project saves on a dedicated queue to prevent concurrent access corruption
        saveQueue.async {
            let result = self.saveProjectSync(viewModel)

            // Notify on main thread if completion provided
            if let completion = completion {
                DispatchQueue.main.async {
                    completion(result)
                }
            }
        }
    }

    private func saveProjectSync(_ viewModel: ProjectViewModel) -> Result<Void, Error> {
        // Use the original file location if it exists, otherwise use default directory
        let url: URL
        if let originalFileURL = viewModel.model.fileURL {
            // Check if project name has changed - if so, update filename to match
            let currentFilename = originalFileURL.deletingPathExtension().lastPathComponent
            let expectedFilename = viewModel.model.name  // Keep natural filename with spaces

            if currentFilename != expectedFilename {
                // Project name changed - update filename to match
                let newURL = originalFileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(expectedFilename).w2")

                // Try to rename the file if it's in the same directory
                if originalFileURL.deletingLastPathComponent() == newURL.deletingLastPathComponent() {
                    do {
                        try FileManager.default.moveItem(at: originalFileURL, to: newURL)
                        viewModel.model.fileURL = newURL
                        url = newURL
                        print("📝 Renamed file to match project name: \(newURL.path)")
                    } catch {
                        print("⚠️ Could not rename file, saving to original location: \(error)")
                        url = originalFileURL
                    }
                } else {
                    url = originalFileURL
                }
            } else {
                url = originalFileURL
                print("💾 Saving to original location: \(originalFileURL.path)")
            }
        } else {
            // Create filename from project name, preserving natural spacing
            let filename = "\(viewModel.model.name).w2"
            url = self.projectsDirectory.appendingPathComponent(filename)
            viewModel.model.fileURL = url // Set the file URL for future saves
            print("💾 Saving to default location: \(url.path)")
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = .prettyPrinted

            let data = try encoder.encode(viewModel)

            // ATOMIC WRITE: Write to temporary file first, then replace atomically
            let tempDirectory = url.deletingLastPathComponent()
            let tempURL = tempDirectory.appendingPathComponent(".tmp_\(UUID().uuidString).w2")

            try data.write(to: tempURL, options: .atomic)

            // Replace the original file atomically
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }

            print("✅ Saved project: \(viewModel.model.name)")
            return .success(())
        } catch {
            print("❌ Failed to save project \(viewModel.model.name): \(error)")
            return .failure(error)
        }
    }
    
    func saveCurrentProject() {
        guard let project = currentProject else { return }
        project.updateModified()
        saveProject(project)
        updateRecentProjects(project)
    }

    /// Save project with user feedback on error
    func saveProjectWithErrorHandling(_ viewModel: ProjectViewModel) {
        viewModel.updateModified()
        saveProject(viewModel) { result in
            switch result {
            case .success:
                // Optionally show success feedback (currently silent)
                ProjectAlertHelper.showSaveSuccess(projectName: viewModel.model.name)
            case .failure(let error):
                // Show error alert with retry option
                ProjectAlertHelper.showSaveError(error, projectName: viewModel.model.name) {
                    // Retry the save
                    self.saveProjectWithErrorHandling(viewModel)
                }
            }
        }
        updateRecentProjects(viewModel)
    }
    
    func saveProjectAs(_ viewModel: ProjectViewModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(viewModel.model.name).w2"
        panel.title = "Save ProResWriter Project"
        panel.message = "Choose a location to save your project"

        let result = panel.runModal()
        if result == .OK, let url = panel.url {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = .prettyPrinted

                let data = try encoder.encode(viewModel)
                try data.write(to: url)

                print("✅ Saved project as: \(url.path)")
            } catch {
                print("❌ Failed to save project as \(url.path): \(error)")
            }
        }
    }
    
    // MARK: - Project Management
    func openProject(_ viewModel: ProjectViewModel) {
        NSLog("📂 Opening project: \(viewModel.model.name)")
        NSLog("📊 Project has \(viewModel.model.ocfFiles.count) OCF files and \(viewModel.model.segments.count) segments")

        // Set as current project
        currentProject = viewModel
        updateRecentProjects(viewModel)

        // Trigger UI update
        objectWillChange.send()

        NSLog("✅ Current project set to: \(currentProject?.model.name ?? "nil")")
        NSLog("🔄 UI update triggered")
    }
    
    func openProjectFile() {
        NSLog("🎬 openProjectFile() called!")
        
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.data] // Try allowing all data files first
        // Allow opening from any location
        panel.title = "Open ProResWriter Project"
        panel.message = "Select a .w2 project file to open"
        
        NSLog("🔍 Opening file picker from any location")
        
        let result = panel.runModal()
        NSLog("📋 File picker result: \(result == .OK ? "OK" : "Cancelled")")
        
        if result == .OK, let url = panel.url {
            NSLog("📁 Selected file: \(url.path)")
            NSLog("📂 File extension: \(url.pathExtension)")
            
            if let viewModel = loadProject(from: url) {
                NSLog("✅ Successfully loaded project: \(viewModel.model.name)")

                // Check if already loaded
                if !projects.contains(where: { $0.model.name == viewModel.model.name }) {
                    projects.append(viewModel)
                    NSLog("➕ Added project to list")
                } else {
                    NSLog("ℹ️ Project already in list")
                }

                openProject(viewModel)
                NSLog("🎯 Called openProject()")
            } else {
                NSLog("❌ Failed to load project from file")
            }
        } else {
            NSLog("❌ File picker cancelled or failed")
        }
    }
    
    func closeProject() {
        if let viewModel = currentProject {
            saveProject(viewModel)
        }
        currentProject = nil
    }
    
    func deleteProject(_ viewModel: ProjectViewModel) {
        // Remove from arrays
        projects.removeAll { $0.model.name == viewModel.model.name }
        recentProjects.removeAll { $0.model.name == viewModel.model.name }

        // Close if current
        if currentProject?.model.name == viewModel.model.name {
            currentProject = nil
        }

        // Delete file - use fileURL if available, otherwise construct from name
        let url: URL
        if let fileURL = viewModel.model.fileURL {
            url = fileURL
        } else {
            let filename = "\(viewModel.model.name).w2"
            url = projectsDirectory.appendingPathComponent(filename)
        }
        try? FileManager.default.removeItem(at: url)
    }
    
    func openRecentProject(_ viewModel: ProjectViewModel) {
        // Check if project file still exists
        guard let fileURL = viewModel.model.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path) else {
            NSLog("❌ Recent project file no longer exists, removing from recent list")
            removeFromRecentProjects(viewModel)
            return
        }

        // Load and open the project
        if let loadedProject = loadProject(from: fileURL) {
            // Check if already in projects list
            if !projects.contains(where: { $0.model.name == loadedProject.model.name }) {
                projects.append(loadedProject)
            }
            openProject(loadedProject)
        }
    }

    private func removeFromRecentProjects(_ viewModel: ProjectViewModel) {
        recentProjects.removeAll { $0.model.name == viewModel.model.name }
    }
    
    func clearRecentProjects() {
        recentProjects.removeAll()
        NSLog("🗑️ Cleared recent projects menu")
    }
    
    private func updateRecentProjects(_ viewModel: ProjectViewModel) {
        // Remove if already in recent
        recentProjects.removeAll { $0.model.name == viewModel.model.name }

        // Add to front
        recentProjects.insert(viewModel, at: 0)

        // Keep only 10 most recent
        if recentProjects.count > 10 {
            recentProjects.removeLast()
        }
    }
    
    // MARK: - Import Integration
    func importOCFFiles(for viewModel: ProjectViewModel, from directory: URL) async -> [MediaFileInfo] {
        let importProcess = ImportProcess()

        do {
            let files = try await importProcess.importOriginalCameraFiles(from: directory)
            viewModel.addOCFFiles(files)
            saveProject(viewModel)
            return files
        } catch {
            print("❌ Failed to import OCF files: \(error)")
            return []
        }
    }

    func importSegments(for viewModel: ProjectViewModel, from directory: URL) async -> [MediaFileInfo] {
        let importProcess = ImportProcess()

        do {
            let files = try await importProcess.importGradedSegments(from: directory)
            viewModel.addSegments(files)
            // Refresh print status after adding segments
            viewModel.refreshPrintStatus()
            saveProject(viewModel)
            return files
        } catch {
            print("❌ Failed to import segments: \(error)")
            return []
        }
    }

    func performLinking(for viewModel: ProjectViewModel) {
        guard !viewModel.model.ocfFiles.isEmpty && !viewModel.model.segments.isEmpty else {
            print("⚠️ Need both OCF files and segments to perform linking")
            return
        }

        // Filter out offline segments before linking
        let onlineSegments = viewModel.model.segments.filter { !viewModel.model.offlineMediaFiles.contains($0.fileName) }
        let offlineCount = viewModel.model.segments.count - onlineSegments.count

        if offlineCount > 0 {
            print("⚠️ Skipping \(offlineCount) offline segment(s) during linking")
        }

        guard !onlineSegments.isEmpty else {
            print("⚠️ No online segments available for linking")
            return
        }

        let linker = SegmentOCFLinker()
        let result = linker.linkSegments(onlineSegments, withOCFParents: viewModel.model.ocfFiles)

        viewModel.updateLinkingResult(result)
        // Refresh print status after linking (in case segment files changed)
        viewModel.refreshPrintStatus()
        saveProject(viewModel)

        print("✅ Linking completed: \(result.summary)")
    }

    func createBlankRushes(for viewModel: ProjectViewModel) async {
        guard let linkingResult = viewModel.model.linkingResult else { return }

        let blankRushIntermediate = BlankRushIntermediate(
            projectDirectory: viewModel.model.blankRushDirectory.path
        )

        // Update status to in progress for all parents
        for parent in linkingResult.parentsWithChildren {
            viewModel.updateBlankRushStatus(ocfFileName: parent.ocf.fileName, status: .inProgress)
        }
        saveProject(viewModel)

        let results = await blankRushIntermediate.createBlankRushes(from: linkingResult)

        // Update statuses based on results
        for result in results {
            let status: BlankRushStatus
            if result.success {
                status = .completed(date: Date(), url: result.blankRushURL)
            } else {
                status = .failed(error: result.error ?? "Unknown error")
            }
            viewModel.updateBlankRushStatus(ocfFileName: result.originalOCF.fileName, status: status)
        }

        saveProject(viewModel)
    }
}