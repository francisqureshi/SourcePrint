//
//  pairingProcess.swift
//  ProResWriter
//
//  Created by mac10 on 15/08/2025.
//

import Foundation
import SwiftFFmpeg  // For AVRational

// MARK: - Parent-Child Linking Data Structures

public struct LinkedSegment: Codable {
    public let segment: MediaFileInfo
    public let linkConfidence: LinkConfidence
    public let linkMethod: String           // "filename", "metadata", "manual"
    
    public init(segment: MediaFileInfo, linkConfidence: LinkConfidence, linkMethod: String) {
        self.segment = segment
        self.linkConfidence = linkConfidence
        self.linkMethod = linkMethod
    }
}

public struct OCFParent: Codable {
    public let ocf: MediaFileInfo
    public let children: [LinkedSegment]
    
    public var childCount: Int {
        return children.count
    }
    
    public var hasChildren: Bool {
        return !children.isEmpty
    }
    
    public init(ocf: MediaFileInfo, children: [LinkedSegment]) {
        self.ocf = ocf
        self.children = children
    }
}

public enum LinkConfidence: Codable {
    case high       // OCF filename contained in segment filename + tech specs
    case medium     // Good technical specs match (resolution + fps)
    case low        // Partial match or fallback
    case none       // No match found
}

public struct LinkingResult: Codable {
    public let ocfParents: [OCFParent]
    public let unmatchedSegments: [MediaFileInfo]
    public let unmatchedOCFs: [MediaFileInfo]
    
    public init(ocfParents: [OCFParent], unmatchedSegments: [MediaFileInfo], unmatchedOCFs: [MediaFileInfo]) {
        self.ocfParents = ocfParents
        self.unmatchedSegments = unmatchedSegments
        self.unmatchedOCFs = unmatchedOCFs
    }
    
    public var totalLinkedSegments: Int {
        return ocfParents.reduce(0) { $0 + $1.childCount }
    }
    
    public var totalSegments: Int {
        return totalLinkedSegments + unmatchedSegments.count
    }
    
    public var successRate: Double {
        guard totalSegments > 0 else { return 0.0 }
        return Double(totalLinkedSegments) / Double(totalSegments)
    }
    
    public var summary: String {
        let parentCount = ocfParents.filter { $0.hasChildren }.count
        return "\(parentCount) OCF parents with \(totalLinkedSegments) child segments (\(Int(successRate * 100))% success)"
    }
}

// MARK: - Parent-Child Linking Engine

public class SegmentOCFLinker {
    
    public init() {}
    
    public func linkSegments(_ segments: [MediaFileInfo], withOCFParents ocfs: [MediaFileInfo]) -> LinkingResult {
        print("🔗 Linking \(segments.count) segments with \(ocfs.count) OCF parent files...")
        
        // Dictionary to group children by OCF parent (using full path as unique key)
        var ocfToChildren: [String: [LinkedSegment]] = [:]
        var unmatchedSegments: [MediaFileInfo] = []
        var usedOCFs: Set<String> = []
        
        // Initialize dictionary with empty arrays for all OCFs (using full path as key)
        for ocf in ocfs {
            ocfToChildren[ocf.url.path] = []
        }
        
        // Link each segment to its best parent OCF
        for segment in segments {
            if let (matchedOCF, confidence, method) = findBestMatch(for: segment, in: ocfs) {
                let linkedSegment = LinkedSegment(
                    segment: segment,
                    linkConfidence: confidence,
                    linkMethod: method
                )
                
                ocfToChildren[matchedOCF.url.path]?.append(linkedSegment)
                usedOCFs.insert(matchedOCF.fileName)
                
                print("  ✅ \(segment.fileName) → \(matchedOCF.fileName) (\(confidence), \(method))")
            } else {
                unmatchedSegments.append(segment)
                print("  ❌ \(segment.fileName) → No parent OCF found")
            }
        }
        
        // Build OCFParent structures
        var ocfParents: [OCFParent] = []
        for ocf in ocfs {
            let children = ocfToChildren[ocf.url.path] ?? []
            let parent = OCFParent(ocf: ocf, children: children)
            ocfParents.append(parent)
        }
        
        // Calculate which OCF files were never used
        let unmatchedOCFs = ocfs.filter { !usedOCFs.contains($0.fileName) }
        
        let result = LinkingResult(
            ocfParents: ocfParents,
            unmatchedSegments: unmatchedSegments,
            unmatchedOCFs: unmatchedOCFs
        )
        
        print("🔗 Linking complete: \(result.summary)")
        
        return result
    }
    
    private func findBestMatch(for segment: MediaFileInfo, in ocfs: [MediaFileInfo]) -> (MediaFileInfo, LinkConfidence, String)? {
        var validMatches: [(MediaFileInfo, LinkConfidence, String)] = []
        
        // Try to match with each OCF using strict validation
        for ocf in ocfs {
            if let matchResult = validateStrictMatch(segment: segment, ocf: ocf) {
                validMatches.append(matchResult)
            }
        }
        
        // Return the best match if we have any
        // Prefer high confidence, then medium, then low
        if let highConfMatch = validMatches.first(where: { $0.1 == .high }) {
            return highConfMatch
        } else if let medConfMatch = validMatches.first(where: { $0.1 == .medium }) {
            return medConfMatch
        } else if let lowConfMatch = validMatches.first(where: { $0.1 == .low }) {
            return lowConfMatch
        }
        
        return nil
    }
    
    private func validateStrictMatch(segment: MediaFileInfo, ocf: MediaFileInfo) -> (MediaFileInfo, LinkConfidence, String)? {
        var matchCriteria: [String] = []
        
        // STEP 1: Hard Requirements - Resolution & FPS must match
        // Check resolution (using effective display resolution)
        guard let segmentRes = segment.effectiveDisplayResolution,
              let ocfRes = ocf.effectiveDisplayResolution else {
            return nil // No resolution info = no match
        }
        
        // Resolution must match EXACTLY
        if segmentRes.width != ocfRes.width || segmentRes.height != ocfRes.height {
            // Resolution mismatch = instant disqualification
            return nil
        }
        matchCriteria.append("resolution")
        
        // Check FPS
        guard let segmentFR = segment.frameRate, 
              let ocfFR = ocf.frameRate else {
            return nil // No frame rate info = no match
        }
        
        if !FrameRateManager.areFrameRatesCompatible(segmentFR, ocfFR) {
            // FPS mismatch = instant disqualification (using centralized rational arithmetic)
            return nil
        }
        matchCriteria.append("fps")
        
        // STEP 2: Detect if this is a consumer camera
        let isConsumerCamera = isConsumerCameraOCF(ocf)
        
        // STEP 3: Check filename matching using pre-computed lowercase strings
        let ocfBaseName = (ocf.fileName as NSString).deletingPathExtension
        let ocfBaseNameLower = ocfBaseName.lowercased()
        let hasFilenameMatch = segment.fileNameLower.contains(ocfBaseNameLower)
        
        if hasFilenameMatch {
            matchCriteria.append("filename_contains")
        }
        
        // STEP 4: Apply different rules based on camera type
        if isConsumerCamera {
            // Consumer camera (00:00:00:00) - STRICTEST verification
            
            // Must have filename match (even for VFX shots)
            if !hasFilenameMatch {
                return nil
            }
            
            // Additional validation: Check reel name if available (using pre-computed lowercase)
            if let segmentReelLower = segment.reelNameLower,
               let ocfReelLower = ocf.reelNameLower,
               segmentReelLower == ocfReelLower {
                matchCriteria.append("reel")
            }
            
            // Additional validation: Segment can't be longer than OCF
            if let segmentDuration = segment.durationInFrames,
               let ocfDuration = ocf.durationInFrames,
               segmentDuration > ocfDuration {
                // Segment longer than OCF = not possible
                return nil
            }
            
            // Consumer camera matches always get LOW confidence as a warning
            matchCriteria.append("consumer_camera")
            let description = matchCriteria.joined(separator: "+")
            return (ocf, .low, description)
            
        } else {
            // Professional camera - check timecode

            // Validate timecode range using pre-computed frame numbers
            let inRange = isSegmentInOCFRange(segment: segment, ocf: ocf)

            if !inRange {
                // Timecode not in range = no match for professional cameras
                return nil
            }
            matchCriteria.append("timecode_range")

            // Check if this is a VFX shot
            let isVFXShot = segment.isVFX == true
            
            // For professional cameras: require filename match unless VFX
            if !isVFXShot && !hasFilenameMatch {
                return nil
            }
            
            if isVFXShot && !hasFilenameMatch {
                matchCriteria.append("vfx_exemption")
            }
            
            // Check reel name for additional confidence (using pre-computed lowercase)
            if let segmentReelLower = segment.reelNameLower,
               let ocfReelLower = ocf.reelNameLower,
               segmentReelLower == ocfReelLower {
                matchCriteria.append("reel")
            }
            
            // Determine confidence for professional camera
            let confidence: LinkConfidence
            if hasFilenameMatch && matchCriteria.contains("timecode_range") {
                confidence = .high // Has everything
            } else if matchCriteria.contains("timecode_range") && isVFXShot {
                confidence = .medium // VFX with valid timecode
            } else {
                confidence = .low // Shouldn't happen with our strict rules
            }
            
            let description = matchCriteria.joined(separator: "+")
            return (ocf, confidence, description)
        }
    }
    
    private func isConsumerCameraOCF(_ ocf: MediaFileInfo) -> Bool {
        // Check if start timecode is 00:00:00:00 or 00:00:00;00
        if let startTC = ocf.sourceTimecode {
            let cleanTC = startTC.replacingOccurrences(of: ";", with: ":")
            return cleanTC == "00:00:00:00"
        }
        return false
    }
    
    private func isSegmentInOCFRange(segment: MediaFileInfo, ocf: MediaFileInfo) -> Bool {
        // 🚀 PERFORMANCE OPTIMIZATION: Use pre-computed frame numbers
        // This eliminates 8000+ redundant SMPTE conversions during linking

        guard let segmentStartFrame = segment.effectiveStartFrame,
              let segmentEndFrame = segment.effectiveEndFrame,
              let ocfStartFrame = ocf.effectiveStartFrame,
              let ocfEndFrame = ocf.effectiveEndFrame else {
            print("    ⚠️ Missing frame numbers for range check")
            return false
        }

        // Check if entire segment duration falls within OCF range
        let segmentStartInRange = segmentStartFrame >= ocfStartFrame && segmentStartFrame <= ocfEndFrame
        let segmentEndInRange = segmentEndFrame >= ocfStartFrame && segmentEndFrame <= ocfEndFrame
        let entireSegmentInRange = segmentStartInRange && segmentEndInRange

        // Get drop frame info for logging
        let isDropFrame = segment.isDropFrame ?? ocf.isDropFrame ?? false
        let dropFrameInfo = isDropFrame ? " (drop frame)" : ""

        // Use timecode strings for logging (still available)
        let segmentStartTC = segment.sourceTimecode ?? "?"
        let segmentEndTC = segment.endTimecode ?? "?"
        let ocfStartTC = ocf.sourceTimecode ?? "?"
        let ocfEndTC = ocf.endTimecode ?? "?"

        if entireSegmentInRange {
            print("    ✅ Segment range \(segmentStartTC)-\(segmentEndTC) (frames \(segmentStartFrame)-\(segmentEndFrame)) within OCF range \(ocfStartTC)-\(ocfEndTC) (frames \(ocfStartFrame)-\(ocfEndFrame))\(dropFrameInfo)")
        } else {
            print("    ❌ Segment range \(segmentStartTC)-\(segmentEndTC) (frames \(segmentStartFrame)-\(segmentEndFrame)) NOT within OCF range \(ocfStartTC)-\(ocfEndTC) (frames \(ocfStartFrame)-\(ocfEndFrame))\(dropFrameInfo)")
        }

        return entireSegmentInRange
    }
    
}
