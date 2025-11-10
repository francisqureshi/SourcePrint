//
//  ProjectHierarchy.swift
//  ProResWriter
//
//  Created by Claude on 25/08/2025.
//

import Foundation
import SwiftUI
import SourcePrintCore

// MARK: - Hierarchical Data Models for UI

/// Represents a hierarchical item in the project outline view
protocol HierarchicalItem: Identifiable, ObservableObject {
    var id: String { get }
    var displayName: String { get }
    var children: [any HierarchicalItem]? { get }
    var statusIcon: String { get }
    var metadata: String { get }
    var timecodeRange: String { get }
}

// MARK: - OCF Parent Item

class OCFParentItem: HierarchicalItem, ObservableObject {
    let id: String
    let ocfFile: MediaFileInfo
    let linkedSegments: [LinkedSegment]
    let blankRushStatus: BlankRushStatus
    
    init(ocfFile: MediaFileInfo, linkedSegments: [LinkedSegment], blankRushStatus: BlankRushStatus) {
        self.id = ocfFile.fileName
        self.ocfFile = ocfFile
        self.linkedSegments = linkedSegments
        self.blankRushStatus = blankRushStatus
    }
    
    var displayName: String {
        ocfFile.fileName
    }
    
    var children: [any HierarchicalItem]? {
        linkedSegments.map { linkedSegment in
            // Check if this segment has been modified (would come from Project)
            let isModified = false  // This would be set by ProjectHierarchy.updateFromProject()
            let modDate: Date? = nil  // This would come from Project.segmentModificationDates
            
            return SegmentChildItem(
                segment: linkedSegment.segment, 
                linkConfidence: linkedSegment.linkConfidence,
                modificationDate: modDate,
                isModified: isModified
            )
        }
    }
    
    var statusIcon: String {
        blankRushStatus.statusIcon
    }
    
    var metadata: String {
        var parts: [String] = []
        
        if let resolution = ocfFile.displayResolution ?? ocfFile.resolution {
            parts.append("\(Int(resolution.width))x\(Int(resolution.height))")
        }
        
        if let frameRate = ocfFile.frameRate {
            parts.append(FrameRateManager.getFrameRateDescription(frameRate: frameRate, isDropFrame: ocfFile.isDropFrame))
        }
        
        if let reel = ocfFile.reelName {
            parts.append("Reel: \(reel)")
        }
        
        return parts.joined(separator: " • ")
    }
    
    var timecodeRange: String {
        guard let startTC = ocfFile.sourceTimecode,
              let frameRate = ocfFile.frameRate,
              let frameCount = ocfFile.durationInFrames else {
            return "Unknown"
        }
        
        // Calculate end timecode using SMPTE
        let smpte = SMPTE(fps: Double(frameRate.floatValue), dropFrame: ocfFile.isDropFrame ?? false)
        
        do {
            let startFrames = try smpte.getFrames(tc: startTC)
            let endFrames = startFrames + Int(frameCount)
            let endTC = smpte.getTC(frames: endFrames)
            
            return "\(startTC) → \(endTC)"
        } catch {
            return startTC
        }
    }
}

// MARK: - Segment Child Item

class SegmentChildItem: HierarchicalItem, ObservableObject {
    let id: String
    let segment: MediaFileInfo
    let linkConfidence: LinkConfidence
    let modificationDate: Date?
    let isModified: Bool
    
    init(segment: MediaFileInfo, linkConfidence: LinkConfidence, modificationDate: Date? = nil, isModified: Bool = false) {
        self.id = segment.fileName
        self.segment = segment
        self.linkConfidence = linkConfidence
        self.modificationDate = modificationDate
        self.isModified = isModified
    }
    
    var displayName: String {
        segment.fileName
    }
    
    var children: [any HierarchicalItem]? {
        nil // Segments don't have children
    }
    
    var statusIcon: String {
        if isModified {
            return "🔶"  // Orange diamond for modified files
        }
        
        switch linkConfidence {
        case .high: return "🟢"
        case .medium: return "🟡" 
        case .low, .none: return "🔴"
        }
    }
    
    var metadata: String {
        var parts: [String] = []
        
        if let resolution = segment.displayResolution ?? segment.resolution {
            parts.append("\(Int(resolution.width))x\(Int(resolution.height))")
        }
        
        if let frameRate = segment.frameRate {
            parts.append(FrameRateManager.getFrameRateDescription(frameRate: frameRate, isDropFrame: segment.isDropFrame))
        }
        parts.append("Confidence: \(linkConfidence)")
        
        if isModified {
            parts.append("MODIFIED")
        }
        
        if let modDate = modificationDate {
            let formatter = DateFormatter.short
            parts.append("Modified: \(formatter.string(from: modDate))")
        }
        
        return parts.joined(separator: " • ")
    }
    
    var timecodeRange: String {
        guard let startTC = segment.sourceTimecode,
              let frameRate = segment.frameRate,
              let frameCount = segment.durationInFrames else {
            return "Unknown"
        }
        
        // Calculate end timecode using SMPTE
        let smpte = SMPTE(fps: Double(frameRate.floatValue), dropFrame: segment.isDropFrame ?? false)
        
        do {
            let startFrames = try smpte.getFrames(tc: startTC)
            let endFrames = startFrames + Int(frameCount)
            let endTC = smpte.getTC(frames: endFrames)
            
            return "\(startTC) → \(endTC)"
        } catch {
            return startTC
        }
    }
}

// MARK: - Enhanced OCF Parent Item with Modification Tracking

class OCFParentItemWithModification: HierarchicalItem, ObservableObject {
    let id: String
    let ocfFile: MediaFileInfo
    let childrenItems: [SegmentChildItem]
    let blankRushStatus: BlankRushStatus
    
    init(ocfFile: MediaFileInfo, childrenItems: [SegmentChildItem], blankRushStatus: BlankRushStatus) {
        self.id = ocfFile.fileName
        self.ocfFile = ocfFile
        self.childrenItems = childrenItems
        self.blankRushStatus = blankRushStatus
    }
    
    var displayName: String {
        ocfFile.fileName
    }
    
    var children: [any HierarchicalItem]? {
        childrenItems
    }
    
    var statusIcon: String {
        // Check if any children are modified and show warning
        if childrenItems.contains(where: { $0.isModified }) {
            return "🔶⚫"  // Modified children indicator + blank rush status
        }
        return blankRushStatus.statusIcon
    }
    
    var metadata: String {
        var parts: [String] = []
        
        if let resolution = ocfFile.displayResolution ?? ocfFile.resolution {
            parts.append("\(Int(resolution.width))x\(Int(resolution.height))")
        }
        
        if let frameRate = ocfFile.frameRate {
            parts.append(FrameRateManager.getFrameRateDescription(frameRate: frameRate, isDropFrame: ocfFile.isDropFrame))
        }
        
        if let reel = ocfFile.reelName {
            parts.append("Reel: \(reel)")
        }
        
        // Add modification warning if any children modified
        let modifiedCount = childrenItems.filter { $0.isModified }.count
        if modifiedCount > 0 {
            parts.append("\(modifiedCount) segment\(modifiedCount == 1 ? "" : "s") modified")
        }
        
        return parts.joined(separator: " • ")
    }
    
    var timecodeRange: String {
        guard let startTC = ocfFile.sourceTimecode,
              let frameRate = ocfFile.frameRate,
              let frameCount = ocfFile.durationInFrames else {
            return "Unknown"
        }
        
        // Calculate end timecode using SMPTE
        let smpte = SMPTE(fps: Double(frameRate.floatValue), dropFrame: ocfFile.isDropFrame ?? false)
        
        do {
            let startFrames = try smpte.getFrames(tc: startTC)
            let endFrames = startFrames + Int(frameCount)
            let endTC = smpte.getTC(frames: endFrames)
            
            return "\(startTC) → \(endTC)"
        } catch {
            return startTC
        }
    }
}

// MARK: - Project Hierarchy Builder

class ProjectHierarchy: ObservableObject {
    @Published var items: [any HierarchicalItem] = []
    
    func updateFromProject(_ project: ProjectViewModel) {
        guard let linkingResult = project.model.linkingResult else {
            items = []
            return
        }
        
        items = linkingResult.ocfParents.compactMap { parent in
            guard parent.hasChildren else { return nil }
            
            let blankRushStatus = project.model.blankRushStatus[parent.ocf.fileName] ?? .notCreated

            // Create children with modification tracking
            let childrenWithModification = parent.children.map { linkedSegment in
                let segmentFileName = linkedSegment.segment.fileName
                let trackedModDate = project.model.segmentModificationDates[segmentFileName]
                let isModified = project.model.offlineMediaFiles.contains(segmentFileName)
                
                return SegmentChildItem(
                    segment: linkedSegment.segment,
                    linkConfidence: linkedSegment.linkConfidence,
                    modificationDate: trackedModDate,
                    isModified: isModified
                )
            }
            
            return OCFParentItemWithModification(
                ocfFile: parent.ocf,
                childrenItems: childrenWithModification,
                blankRushStatus: blankRushStatus
            )
        }
    }
}

// MARK: - UI Helpers

extension HierarchicalItem {
    var isExpandable: Bool {
        children?.isEmpty == false
    }
    
    var childCount: Int {
        children?.count ?? 0
    }
}

// MARK: - Type-Erased Wrapper for SwiftUI

class AnyHierarchicalItem: HierarchicalItem, ObservableObject {
    let id: String
    let displayName: String
    let children: [any HierarchicalItem]?
    let statusIcon: String
    let metadata: String
    let timecodeRange: String
    
    private let _item: any HierarchicalItem
    
    init<T: HierarchicalItem>(_ item: T) {
        self._item = item
        self.id = item.id
        self.displayName = item.displayName
        self.children = item.children
        self.statusIcon = item.statusIcon
        self.metadata = item.metadata
        self.timecodeRange = item.timecodeRange
    }
}