//
//  FilneMonitorWatchFolder.swift
//  SourcePrintCore
//
//  Created by Claude on 29/09/2025.
//  Rewritten with FileMonitor on 21/10/2025.
//  Watch folder service supporting multiple folders with different behaviors
//

#if canImport(FileMonitor)
import FileMonitor
#endif
import Foundation

/// Watch folder service supporting multiple folders with different behaviors
/// Note: Only available on macOS (uses FSEvents via FileMonitor)
#if canImport(FileMonitor)
public class FileMonitorWatchFolder {
    private var gradeMonitor: FileMonitor?
    private var vfxMonitor: FileMonitor?
    private var monitorTasks: [Task<Void, Never>] = []
    private var isActive = false

    /// Store watched folder paths for polling
    private var gradePath: String?
    private var vfxPath: String?

    /// Callback for when video files are detected (URLs, isVFX)
    public var onVideoFilesDetected: (([URL], Bool) -> Void)?

    /// Callback for when video files are deleted (file names, isVFX)
    public var onVideoFilesDeleted: (([String], Bool) -> Void)?

    /// Callback for when video files are modified (file names, isVFX)
    public var onVideoFilesModified: (([String], Bool) -> Void)?

    /// Pending files waiting for copy completion (filePath -> (lastModified, isVFX))
    private var pendingFiles: [String: (Date, Bool)] = [:]

    /// Track imported files to distinguish modifications from new files
    private var importedFiles: Set<String> = []

    private var debounceTimer: Timer?
    private let debounceInterval: TimeInterval = 3.0  // Wait 3 seconds after last change

    /// Polling timer for network volumes (FSEvents doesn't work well on network drives)
    private var pollingTimer: Timer?
    private let pollingInterval: TimeInterval = 5.0  // Check every 5 seconds
    private var lastKnownFileSizes: [String: Int64] = [:]  // Track file sizes to detect changes

    /// Video file extensions to monitor
    private let videoExtensions = ["mov", "mp4", "m4v", "mxf", "prores"]

    public init() {}

    /// Start monitoring multiple folders
    public func startWatching(gradePath: String?, vfxPath: String?) {
        NSLog("🔍 WatchFolder: Starting to watch folders...")

        guard !isActive else {
            NSLog("⚠️ Already watching - stop first")
            return
        }

        isActive = true

        // Store paths for polling
        self.gradePath = gradePath
        self.vfxPath = vfxPath

        // Start monitoring grade folder
        if let gradePath = gradePath {
            NSLog("📁 Monitoring grade folder: %@", gradePath)
            startMonitoring(path: gradePath, isVFX: false)
            // Scan for existing files
            scanExistingFiles(in: gradePath, isVFX: false)
        }

        // Start monitoring VFX folder
        if let vfxPath = vfxPath {
            NSLog("🎬 Monitoring VFX folder: %@", vfxPath)
            startMonitoring(path: vfxPath, isVFX: true)
            // Scan for existing files
            scanExistingFiles(in: vfxPath, isVFX: true)
        }

        if gradePath == nil && vfxPath == nil {
            NSLog("⚠️ No folders specified for monitoring")
            isActive = false
            return
        }

        // Start polling timer for network volumes (FSEvents doesn't work reliably on network drives)
        startPolling()
    }

    /// Start polling timer to check for file modifications (for network volumes)
    private func startPolling() {
        NSLog("🔄 Starting polling timer (every %.1f seconds) for network volume support", pollingInterval)
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            self?.checkForFileModifications()
        }
    }

    /// Check all tracked files for modifications by comparing file sizes
    private func checkForFileModifications() {
        let gradePath = self.gradePath
        let vfxPath = self.vfxPath

        // Check grade folder
        if let gradePath = gradePath {
            checkFilesInFolder(path: gradePath, isVFX: false)
        }

        // Check VFX folder
        if let vfxPath = vfxPath {
            checkFilesInFolder(path: vfxPath, isVFX: true)
        }
    }

    /// Check all video files in a folder for modifications
    private func checkFilesInFolder(path: String, isVFX: Bool) {
        let folderURL = URL(fileURLWithPath: path)

        guard let fileURLs = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for fileURL in fileURLs {
            let fileName = fileURL.lastPathComponent
            let filePath = fileURL.path
            let fileExtension = fileURL.pathExtension.lowercased()

            // Only check video files
            guard videoExtensions.contains(fileExtension) else { continue }

            // Only check files we're tracking as imported
            guard importedFiles.contains(filePath) else { continue }

            // Get current file size
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                guard let currentSize = attributes[.size] as? Int64 else { continue }

                // Check if size changed
                if let lastSize = lastKnownFileSizes[filePath] {
                    if currentSize != lastSize {
                        NSLog("📝 POLLING: File size changed for %@: %lld -> %lld bytes", fileName, lastSize, currentSize)
                        // Update stored size
                        lastKnownFileSizes[filePath] = currentSize
                        // Notify modification
                        onVideoFilesModified?([fileName], isVFX)
                    }
                } else {
                    // First time seeing this file - just store its size
                    lastKnownFileSizes[filePath] = currentSize
                }
            } catch {
                // Ignore errors (file might have been deleted)
                continue
            }
        }
    }

    /// Start monitoring a specific path
    private func startMonitoring(path: String, isVFX: Bool) {
        do {
            let monitor = try FileMonitor(directory: URL(fileURLWithPath: path))

            // Store monitor reference
            if isVFX {
                vfxMonitor = monitor
            } else {
                gradeMonitor = monitor
            }

            // Start the monitor
            try monitor.start()
            NSLog("✅ Started FileMonitor for %@ folder", isVFX ? "VFX" : "grade")

            // Create task to consume events
            let task = Task {
                await self.consumeEvents(from: monitor, isVFX: isVFX)
            }
            monitorTasks.append(task)

        } catch {
            NSLog("❌ Failed to start monitoring %@: %@", path, error.localizedDescription)
        }
    }

    /// Consume events from FileMonitor stream
    private func consumeEvents(from monitor: FileMonitor, isVFX: Bool) async {
        for await event in monitor.stream {
            // Run on main thread since we use Timer and callbacks
            await MainActor.run {
                self.handleEvent(event, isVFX: isVFX)
            }
        }
    }

    /// Handle individual file change event
    private func handleEvent(_ event: FileChange, isVFX: Bool) {
        let fileURL: URL
        let pathString: String
        let fileName: String

        switch event {
        case .added(let file):
            fileURL = file
            pathString = fileURL.path
            fileName = fileURL.lastPathComponent

            // Skip hidden files
            if fileName.hasPrefix(".") {
                return
            }

            // Check if it's a video file
            let fileExtension = fileURL.pathExtension.lowercased()
            guard videoExtensions.contains(fileExtension) else {
                return
            }

            NSLog("🎬 %@ FILE CREATED: %@", isVFX ? "VFX" : "GRADE", fileName)

            // Add to pending files with current timestamp and VFX flag
            pendingFiles[pathString] = (Date(), isVFX)

            // Reset debounce timer
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false)
            { [weak self] _ in
                self?.processCompletedFiles()
            }

            NSLog(
                "⏳ File added to pending queue. Will process in %.1f seconds if no more changes...",
                debounceInterval)

        case .changed(let file):
            fileURL = file
            pathString = fileURL.path
            fileName = fileURL.lastPathComponent

            NSLog("🔔 CHANGED EVENT: %@ (path: %@)", fileName, pathString)

            // Skip hidden files
            if fileName.hasPrefix(".") {
                NSLog("   ⏩ Skipping hidden file")
                return
            }

            let fileExtension = fileURL.pathExtension.lowercased()
            guard videoExtensions.contains(fileExtension) else {
                NSLog("   ⏩ Skipping non-video file (extension: %@)", fileExtension)
                return
            }

            // Check if file still exists - "changed" can mean deleted when multiple files are deleted
            if !FileManager.default.fileExists(atPath: pathString) {
                // File was deleted (reported as "changed" by FileMonitor for batch deletes)
                NSLog("🗑️ %@ FILE DELETED (via change event): %@", isVFX ? "VFX" : "GRADE", fileName)
                onVideoFilesDeleted?([fileName], isVFX)

                // Remove from pending if it was there
                pendingFiles.removeValue(forKey: pathString)
                return
            }

            // File exists - check if it's a modification or new file
            if FileManager.default.fileExists(atPath: pathString) {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: pathString)
                    if let fileSize = attributes[.size] as? Int64, fileSize > 0 {
                        // Check if this file has been imported before
                        if importedFiles.contains(pathString) {
                            // File was previously imported - this is a modification
                            NSLog("📝 %@ FILE MODIFIED: %@ (path: %@, tracked: %d files)", isVFX ? "VFX" : "GRADE", fileName, pathString, importedFiles.count)
                            onVideoFilesModified?([fileName], isVFX)
                        } else if pendingFiles[pathString] == nil {
                            // New file moved in - treat as creation
                            NSLog("🎬 %@ FILE MOVED IN: %@", isVFX ? "VFX" : "GRADE", fileName)

                            // Add to pending files with current timestamp and VFX flag
                            pendingFiles[pathString] = (Date(), isVFX)

                            // Reset debounce timer
                            debounceTimer?.invalidate()
                            debounceTimer = Timer.scheduledTimer(
                                withTimeInterval: debounceInterval, repeats: false
                            ) { [weak self] _ in
                                self?.processCompletedFiles()
                            }

                            NSLog(
                                "⏳ Moved-in file added to pending queue. Will process in %.1f seconds if no more changes...",
                                debounceInterval)
                        } else {
                            // File is in pending queue and was updated again - update timestamp
                            pendingFiles[pathString] = (Date(), isVFX)
                            NSLog("⏳ Pending file updated: %@ - resetting timer", fileName)

                            // Reset debounce timer
                            debounceTimer?.invalidate()
                            debounceTimer = Timer.scheduledTimer(
                                withTimeInterval: debounceInterval, repeats: false
                            ) { [weak self] _ in
                                self?.processCompletedFiles()
                            }
                        }
                    }
                } catch {
                    NSLog(
                        "⚠️ Cannot read modified file attributes: %@ - %@", fileName,
                        error.localizedDescription)
                }
            }

        case .deleted(let file):
            fileURL = file
            pathString = fileURL.path
            fileName = fileURL.lastPathComponent

            // Skip hidden files
            if fileName.hasPrefix(".") {
                return
            }

            let fileExtension = fileURL.pathExtension.lowercased()
            guard videoExtensions.contains(fileExtension) else {
                return
            }

            NSLog("🗑️ %@ FILE DELETED: %@", isVFX ? "VFX" : "GRADE", fileName)
            onVideoFilesDeleted?([fileName], isVFX)

            // Remove from pending and imported tracking
            pendingFiles.removeValue(forKey: pathString)
            importedFiles.remove(pathString)
        }
    }

    /// Stop monitoring
    public func stopWatching() {
        NSLog("🛑 WatchFolder: Stopping watch")

        guard isActive else {
            NSLog("⚠️ Not currently watching")
            return
        }

        // Cancel all monitor tasks
        for task in monitorTasks {
            task.cancel()
        }
        monitorTasks.removeAll()

        // Stop monitors
        gradeMonitor?.stop()
        vfxMonitor?.stop()
        gradeMonitor = nil
        vfxMonitor = nil

        // Clear stored paths
        gradePath = nil
        vfxPath = nil

        // Clean up debounce timer and pending files
        debounceTimer?.invalidate()
        debounceTimer = nil
        pendingFiles.removeAll()
        importedFiles.removeAll()

        // Clean up polling timer
        pollingTimer?.invalidate()
        pollingTimer = nil
        lastKnownFileSizes.removeAll()

        isActive = false
        NSLog("✅ WatchFolder: Stopped")
    }

    /// Scan for existing files in a folder on startup
    private func scanExistingFiles(in folderPath: String, isVFX: Bool) {
        NSLog("📂 Scanning existing files in %@ folder: %@", isVFX ? "VFX" : "grade", folderPath)

        let folderURL = URL(fileURLWithPath: folderPath)

        do {
            let fileURLs = try FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])

            var existingVideoFiles: [URL] = []

            for fileURL in fileURLs {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])

                if resourceValues.isRegularFile == true {
                    let fileExtension = fileURL.pathExtension.lowercased()

                    if videoExtensions.contains(fileExtension) {
                        NSLog(
                            "📄 Found existing %@ file: %@", isVFX ? "VFX" : "grade",
                            fileURL.lastPathComponent)
                        existingVideoFiles.append(fileURL)

                        // Track existing files as imported
                        let filePath = fileURL.path
                        importedFiles.insert(filePath)

                        // Store initial file size for polling
                        if let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
                           let fileSize = attributes[.size] as? Int64 {
                            lastKnownFileSizes[filePath] = fileSize
                        }
                    }
                }
            }

            if !existingVideoFiles.isEmpty {
                NSLog(
                    "🎬 Found %d existing %@ files to import", existingVideoFiles.count,
                    isVFX ? "VFX" : "grade")

                // Import existing files immediately (they're already complete)
                onVideoFilesDetected?(existingVideoFiles, isVFX)
            } else {
                NSLog("📭 No existing video files found in %@ folder", isVFX ? "VFX" : "grade")
            }
        } catch {
            NSLog("❌ Error scanning folder %@: %@", folderPath, error.localizedDescription)
        }
    }

    /// Process files that haven't been modified for the debounce interval
    private func processCompletedFiles() {
        NSLog("🔄 Processing completed files...")

        let now = Date()
        var gradeFiles: [URL] = []
        var vfxFiles: [URL] = []
        var filesToRemove: [String] = []

        for (filePath, (lastModified, isVFX)) in pendingFiles {
            let timeSinceModified = now.timeIntervalSince(lastModified)

            if timeSinceModified >= debounceInterval {
                // File hasn't been modified for debounce interval - should be complete
                if FileManager.default.fileExists(atPath: filePath) {
                    let fileURL = URL(fileURLWithPath: filePath)

                    // Double-check file is readable and has size > 0
                    do {
                        let attributes = try FileManager.default.attributesOfItem(atPath: filePath)
                        if let fileSize = attributes[.size] as? Int64, fileSize > 0 {
                            NSLog(
                                "✅ File ready for import: %@ (size: %lld bytes) [%@]",
                                fileURL.lastPathComponent, fileSize, isVFX ? "VFX" : "GRADE")

                            if isVFX {
                                vfxFiles.append(fileURL)
                            } else {
                                gradeFiles.append(fileURL)
                            }

                            // Track this file as imported
                            importedFiles.insert(filePath)

                            filesToRemove.append(filePath)
                        } else {
                            NSLog(
                                "⚠️ File has zero size, waiting longer: %@",
                                fileURL.lastPathComponent)
                        }
                    } catch {
                        NSLog(
                            "⚠️ Cannot read file attributes: %@ - %@", fileURL.lastPathComponent,
                            error.localizedDescription)
                        filesToRemove.append(filePath)  // Remove problematic files
                    }
                } else {
                    NSLog("⚠️ File no longer exists: %@", filePath)
                    filesToRemove.append(filePath)
                }
            }
        }

        // Remove processed files from pending queue
        for filePath in filesToRemove {
            pendingFiles.removeValue(forKey: filePath)
        }

        // Import completed files by type
        if !gradeFiles.isEmpty {
            NSLog("📢 Importing %d completed grade files", gradeFiles.count)
            onVideoFilesDetected?(gradeFiles, false)
        }

        if !vfxFiles.isEmpty {
            NSLog("📢 Importing %d completed VFX files", vfxFiles.count)
            onVideoFilesDetected?(vfxFiles, true)
        }

        // If there are still pending files, schedule another check
        if !pendingFiles.isEmpty {
            NSLog("⏳ %d files still pending, scheduling another check...", pendingFiles.count)
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceInterval, repeats: false)
            { [weak self] _ in
                self?.processCompletedFiles()
            }
        }
    }

    deinit {
        stopWatching()
    }
}
#endif // canImport(FileMonitor)
