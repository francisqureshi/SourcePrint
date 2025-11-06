//
//  StatusBarViewModel.swift
//  SourcePrint
//
//  Centralized progress aggregator for the chin status bar UI
//

import Foundation
import Combine

/// Types of operations that can show progress in the status bar
enum OperationType: Equatable {
    case idle
    case importing
    case linking
    case generatingBlankRush
    case rendering
    case watchFolderImport
}

/// Detailed progress information for expanded view
struct DetailedProgress {
    let fileName: String?
    let currentItem: Int?
    let totalItems: Int?
    let fps: Double?
    let percentage: String?
    let timeRemaining: String?
    let additionalInfo: String?
}

/// Observable ViewModel for the status bar - aggregates progress from all operations
@MainActor
class StatusBarViewModel: ObservableObject {

    // MARK: - Published Properties

    /// Current operation type
    @Published var currentOperation: OperationType = .idle

    /// Main status text (e.g., "Rendering 3 of 12 items")
    @Published var statusText: String = "Ready"

    /// Progress value (0.0 to 1.0)
    @Published var progressValue: Double = 0.0

    /// Whether progress is indeterminate (shows spinner instead of bar)
    @Published var isIndeterminate: Bool = false

    /// Detailed information for expanded view
    @Published var detailedInfo: DetailedProgress? = nil

    /// Whether the status bar is expanded
    @Published var isExpanded: Bool = false

    /// Last completed operation (for idle state)
    @Published var lastCompletedOperation: String? = nil

    /// Timestamp of last completed operation
    @Published var lastCompletedTime: Date? = nil

    // MARK: - Progress Update Methods

    /// Update import progress
    func updateImportProgress(currentFile: Int, totalFiles: Int, fileName: String) {
        currentOperation = .importing
        statusText = "Importing media files... (\(currentFile)/\(totalFiles))"
        progressValue = Double(currentFile) / Double(totalFiles)
        isIndeterminate = false

        detailedInfo = DetailedProgress(
            fileName: fileName,
            currentItem: currentFile,
            totalItems: totalFiles,
            fps: nil,
            percentage: String(format: "%.0f%%", progressValue * 100),
            timeRemaining: nil,
            additionalInfo: nil
        )
    }

    /// Update linking progress
    func updateLinkingProgress(
        currentFile: Int,
        totalFiles: Int,
        fileName: String,
        fps: Double?,
        percentage: Double
    ) {
        currentOperation = .linking
        statusText = "Linking segments... (\(currentFile)/\(totalFiles))"
        progressValue = percentage
        isIndeterminate = false

        detailedInfo = DetailedProgress(
            fileName: fileName,
            currentItem: currentFile,
            totalItems: totalFiles,
            fps: fps,
            percentage: String(format: "%.0f%%", percentage * 100),
            timeRemaining: nil,
            additionalInfo: nil
        )
    }

    /// Update blank rush generation progress
    func updateBlankRushProgress(
        currentFile: Int,
        totalFiles: Int,
        fileName: String,
        fps: Double?
    ) {
        currentOperation = .generatingBlankRush
        statusText = "Generating blank rushes... (\(currentFile)/\(totalFiles))"
        progressValue = Double(currentFile) / Double(totalFiles)
        isIndeterminate = false

        detailedInfo = DetailedProgress(
            fileName: fileName,
            currentItem: currentFile,
            totalItems: totalFiles,
            fps: fps,
            percentage: String(format: "%.0f%%", progressValue * 100),
            timeRemaining: nil,
            additionalInfo: nil
        )
    }

    /// Update render queue progress
    func updateRenderProgress(
        currentItem: Int,
        totalItems: Int,
        fileName: String,
        progress: String
    ) {
        currentOperation = .rendering
        statusText = "Rendering... (\(currentItem)/\(totalItems))"

        // Parse progress string if possible (e.g., "45.2%")
        if let percentValue = parsePercentage(from: progress) {
            progressValue = percentValue / 100.0
            isIndeterminate = false
        } else {
            isIndeterminate = true
        }

        detailedInfo = DetailedProgress(
            fileName: fileName,
            currentItem: currentItem,
            totalItems: totalItems,
            fps: nil,
            percentage: progress,
            timeRemaining: nil,
            additionalInfo: nil
        )
    }

    /// Update watch folder auto-import progress
    func updateWatchFolderProgress(fileCount: Int) {
        currentOperation = .watchFolderImport
        statusText = "Auto-importing \(fileCount) file\(fileCount == 1 ? "" : "s")..."
        isIndeterminate = true

        detailedInfo = nil
    }

    /// Mark operation as complete
    func completeOperation(summary: String) {
        lastCompletedOperation = summary
        lastCompletedTime = Date()

        // Reset to idle after a brief moment
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.reset()
        }
    }

    /// Reset to idle state
    func reset() {
        currentOperation = .idle
        progressValue = 0.0
        isIndeterminate = false
        detailedInfo = nil

        // Update status text based on last operation
        if let lastOp = lastCompletedOperation, let lastTime = lastCompletedTime {
            let timeAgo = formatTimeAgo(lastTime)
            statusText = "Ready • Last: \(lastOp) (\(timeAgo))"
        } else {
            statusText = "Ready"
        }
    }

    /// Toggle expanded state
    func toggleExpanded() {
        isExpanded.toggle()
    }

    // MARK: - Helper Methods

    /// Parse percentage from string (e.g., "45.2%" -> 45.2)
    private func parsePercentage(from string: String) -> Double? {
        let cleaned = string.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    /// Format time ago (e.g., "2 minutes ago", "just now")
    private func formatTimeAgo(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)

        if seconds < 10 {
            return "just now"
        } else if seconds < 60 {
            return "\(Int(seconds)) seconds ago"
        } else if seconds < 3600 {
            let minutes = Int(seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        } else {
            let hours = Int(seconds / 3600)
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
    }
}
