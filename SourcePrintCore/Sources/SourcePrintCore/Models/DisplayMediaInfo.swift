//
//  DisplayMediaInfo.swift
//  SourcePrintCore
//
//  GUI-appropriate media file information abstraction
//  Eliminates SwiftFFmpeg dependencies from the UI layer
//

import Foundation

/// GUI-optimized media file information with display-ready formats
/// Abstraction layer between MediaFileInfo (with SwiftFFmpeg) and UI components
public struct DisplayMediaInfo: Identifiable, Hashable, Codable {
    public let id: String
    public let fileName: String
    public let url: URL

    // Resolution info
    public let resolution: Resolution?
    public let displayResolution: Resolution?
    public let sampleAspectRatio: String?

    // Frame rate info - GUI optimized
    public let frameRateDisplay: String      // "23.976fps (24000/1001)"
    public let frameRateValue: Double        // 23.976 (for calculations)
    public let isDropFrame: Bool

    // Timing info
    public let sourceTimecode: String?
    public let endTimecode: String?
    public let durationInFrames: Int64?
    public let durationSeconds: Double?      // Calculated duration for display

    // Additional metadata
    public let reelName: String?
    public let isInterlaced: Bool
    public let fieldOrder: String?
    public let mediaType: MediaType

    // VFX workflow
    public let isVFXShot: Bool

    public init(
        fileName: String,
        url: URL,
        resolution: Resolution?,
        displayResolution: Resolution?,
        sampleAspectRatio: String?,
        frameRateDisplay: String,
        frameRateValue: Double,
        isDropFrame: Bool,
        sourceTimecode: String?,
        endTimecode: String?,
        durationInFrames: Int64?,
        durationSeconds: Double?,
        reelName: String?,
        isInterlaced: Bool,
        fieldOrder: String?,
        mediaType: MediaType,
        isVFXShot: Bool = false
    ) {
        self.id = fileName
        self.fileName = fileName
        self.url = url
        self.resolution = resolution
        self.displayResolution = displayResolution
        self.sampleAspectRatio = sampleAspectRatio
        self.frameRateDisplay = frameRateDisplay
        self.frameRateValue = frameRateValue
        self.isDropFrame = isDropFrame
        self.sourceTimecode = sourceTimecode
        self.endTimecode = endTimecode
        self.durationInFrames = durationInFrames
        self.durationSeconds = durationSeconds
        self.reelName = reelName
        self.isInterlaced = isInterlaced
        self.fieldOrder = fieldOrder
        self.mediaType = mediaType
        self.isVFXShot = isVFXShot
    }
}

// MARK: - Display Helpers

extension DisplayMediaInfo {
    /// Formatted resolution string for display
    public var resolutionDisplay: String {
        if let displayRes = displayResolution {
            return displayRes.description
        } else if let res = resolution {
            return res.description
        }
        return "—"
    }

    /// Formatted duration for display
    public var durationDisplay: String {
        if let duration = durationSeconds {
            return String(format: "%.2fs", duration)
        }
        return "—"
    }

    /// Formatted frame count for display
    public var frameCountDisplay: String {
        if let frames = durationInFrames {
            return "\(frames)"
        }
        return "—"
    }

    /// Combined metadata string for compact display
    public var metadataDisplay: String {
        var parts: [String] = []

        parts.append(resolutionDisplay)
        parts.append(frameRateDisplay)

        if let reel = reelName {
            parts.append("Reel: \(reel)")
        }

        return parts.joined(separator: " • ")
    }

    /// Timecode range for display
    public var timecodeRangeDisplay: String {
        if let start = sourceTimecode, let end = endTimecode {
            return "\(start) → \(end)"
        } else if let start = sourceTimecode {
            return start
        }
        return "—"
    }

    /// Media type display name
    public var mediaTypeDisplay: String {
        switch mediaType {
        case .originalCameraFile:
            return "OCF"
        case .gradedSegment:
            return "Segment"
        }
    }
}

// MARK: - VFX Workflow

extension DisplayMediaInfo {
    /// Computed property for VFX status - matches MediaFileInfo.isVFX for compatibility
    public var isVFX: Bool {
        return isVFXShot
    }
}

// MARK: - MediaFileInfo Conversion

/// Extension to convert MediaFileInfo to GUI-friendly DisplayMediaInfo
/// Eliminates SwiftFFmpeg dependencies from the UI layer
extension MediaFileInfo {

    /// Convert to display-optimized format for GUI consumption
    /// Formats all technical data into display-ready strings and values
    public func toDisplayInfo() -> DisplayMediaInfo {
        // Create formatted frame rate display
        let frameRateDisplay: String
        let frameRateValue: Double

        if let frameRate = self.frameRate {
            frameRateDisplay = FrameRateManager.getFrameRateDescription(frameRate: frameRate, isDropFrame: self.isDropFrame)
            frameRateValue = Double(frameRate.floatValue)
        } else {
            frameRateDisplay = "Unknown"
            frameRateValue = 0.0
        }

        // Calculate duration in seconds for display
        let durationSeconds: Double?
        if let frames = self.durationInFrames, frameRateValue > 0 {
            durationSeconds = Double(frames) / frameRateValue
        } else {
            durationSeconds = nil
        }

        return DisplayMediaInfo(
            fileName: self.fileName,
            url: self.url,
            resolution: self.resolution,
            displayResolution: self.displayResolution,
            sampleAspectRatio: self.sampleAspectRatio,
            frameRateDisplay: frameRateDisplay,
            frameRateValue: frameRateValue,
            isDropFrame: self.isDropFrame ?? false,
            sourceTimecode: self.sourceTimecode,
            endTimecode: self.endTimecode,
            durationInFrames: self.durationInFrames,
            durationSeconds: durationSeconds,
            reelName: self.reelName,
            isInterlaced: self.isInterlaced ?? false,
            fieldOrder: self.fieldOrder,
            mediaType: self.mediaType,
            isVFXShot: self.isVFXShot ?? false
        )
    }
}

/// Batch conversion helper for arrays of MediaFileInfo
extension Array where Element == MediaFileInfo {

    /// Convert array of MediaFileInfo to DisplayMediaInfo for GUI consumption
    public func toDisplayInfo() -> [DisplayMediaInfo] {
        return self.map { $0.toDisplayInfo() }
    }
}