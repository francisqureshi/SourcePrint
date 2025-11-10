//
//  OCFParentContextMenu.swift
//  SourcePrint
//
//  Context menu for OCF parent cards
//

import SourcePrintCore
import SwiftUI

struct OCFParentContextMenu: View {
    let parent: OCFParent
    @ObservedObject var project: ProjectViewModel
    @ObservedObject var projectManager: ProjectManager
    let selectedParents: [OCFParent]
    let allParents: [OCFParent]
    
    // Determine which parents to operate on - selected parents if multiple are selected, otherwise just the clicked parent
    private var operatingParents: [OCFParent] {
        return selectedParents.count > 1 ? selectedParents : [parent]
    }
    
    private var isBlankRushReady: Bool {
        if operatingParents.count == 1 {
            return project.blankRushFileExists(for: parent.ocf.fileName)
        } else {
            // For multiple selection, check if ANY have blank rushes ready
            return operatingParents.contains { project.blankRushFileExists(for: $0.ocf.fileName) }
        }
    }
    
    private var isAlreadyInQueue: Bool {
        if operatingParents.count == 1 {
            return project.renderQueue.contains { $0.ocfFileName == parent.ocf.fileName && $0.status != .completed }
        } else {
            // For multiple selection, check if ALL are already in queue
            return operatingParents.allSatisfy { parent in
                project.renderQueue.contains { $0.ocfFileName == parent.ocf.fileName && $0.status != .completed }
            }
        }
    }
    
    private var eligibleParentsForQueue: [OCFParent] {
        return operatingParents.filter { parent in
            project.blankRushFileExists(for: parent.ocf.fileName) &&
            !project.renderQueue.contains { $0.ocfFileName == parent.ocf.fileName && $0.status != .completed }
        }
    }
    
    private var hasModifiedSegments: Bool {
        // Check if any segments for this OCF have been modified since last print
        guard let printStatus = project.model.printStatus[parent.ocf.fileName],
              case .printed(let lastPrintDate, _) = printStatus else {
            return false
        }

        for child in parent.children {
            let segmentFileName = child.segment.fileName
            if let fileModDate = getFileModificationDate(for: child.segment.url),
               fileModDate > lastPrintDate {
                return true
            }
        }
        return false
    }
    
    @ViewBuilder
    var body: some View {
        // Context menu items removed - functionality now available through main UI buttons
        EmptyView()
    }
    
    private func addToRenderQueue() {
        let parentsToAdd = eligibleParentsForQueue
        var addedCount = 0

        for parent in parentsToAdd {
            let queueItem = SourcePrintCore.RenderQueueItem(ocfFileName: parent.ocf.fileName)
            project.renderQueue.append(queueItem)
            addedCount += 1
        }

        projectManager.saveProject(project)

        if addedCount == 1 {
            NSLog("➕ Added \(parentsToAdd.first!.ocf.fileName) to render queue")
        } else {
            NSLog("➕ Added \(addedCount) items to render queue")
        }
    }

    private func regenerateBlankRush() {
        NSLog("🔄 Regenerating blank rush for \(parent.ocf.fileName)")

        // Mark as in progress
        project.model.blankRushStatus[parent.ocf.fileName] = .inProgress
        projectManager.saveProject(project)

        // Create single-file linking result for this OCF
        let singleOCFResult = LinkingResult(
            ocfParents: [parent],
            unmatchedSegments: [],
            unmatchedOCFs: []
        )

        Task {
            let blankRushCreator = BlankRushIntermediate(projectDirectory: project.model.blankRushDirectory.path)

            // Create blank rush
            let results = await blankRushCreator.createBlankRushes(from: singleOCFResult) { clipName, current, total, fps in
                // No progress UI needed for context menu action
            }

            await MainActor.run {
                if let result = results.first {
                    if result.success {
                        project.model.blankRushStatus[result.originalOCF.fileName] = .completed(date: Date(), url: result.blankRushURL)
                        projectManager.saveProject(project)
                        NSLog("✅ Regenerated blank rush for \(parent.ocf.fileName): \(result.blankRushURL.lastPathComponent)")
                    } else {
                        let errorMessage = result.error ?? "Unknown error"
                        project.model.blankRushStatus[result.originalOCF.fileName] = .failed(error: errorMessage)
                        projectManager.saveProject(project)
                        NSLog("❌ Failed to regenerate blank rush for \(parent.ocf.fileName): \(errorMessage)")
                    }
                }
            }
        }
    }

    private func getFileModificationDate(for url: URL) -> Date? {
        do {
            let resourceValues = try url.resourceValues(forKeys: [.contentModificationDateKey])
            return resourceValues.contentModificationDate
        } catch {
            return nil
        }
    }
}

