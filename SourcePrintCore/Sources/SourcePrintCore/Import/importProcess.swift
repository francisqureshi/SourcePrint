//
//  importProcess.swift
//  ProResWriter
//
//  Created by francisqureshi on 15/08/2025.
//

import Foundation
import SwiftFFmpeg
import TimecodeKit

// MARK: - AVRational Codable Support
extension AVRational: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let num = try container.decode(Int32.self, forKey: .num)
        let den = try container.decode(Int32.self, forKey: .den)
        self.init(num: num, den: den)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(num, forKey: .num)
        try container.encode(den, forKey: .den)
    }

    private enum CodingKeys: String, CodingKey {
        case num
        case den
    }
}

// MARK: - Media File Information
public struct MediaFileInfo: Codable {
    public let fileName: String
    public let url: URL
    public let resolution: CGSize?  // Coded resolution (actual pixel dimensions)
    public let displayResolution: CGSize?  // Display resolution (SAR-corrected)
    public let sampleAspectRatio: String?  // SAR like "139:140"
    public let frameRate: AVRational?  // nil = unknown, direct rational for perfect precision
    public let sourceTimecode: String?
    public let endTimecode: String?  // Calculated end timecode
    public let durationInFrames: Int64?  // Duration in frames
    public let isDropFrame: Bool?  // nil = unknown, true = drop frame, false = non-drop frame
    public let reelName: String?
    public let isInterlaced: Bool?  // nil = unknown, true = interlaced, false = progressive
    public let fieldOrder: String?
    public let mediaType: MediaType
    public var isVFXShot: Bool?  // VFX shot flag (can be modified by user)

    // MARK: - Pre-Computed Fields (Performance Optimization)
    // Computed once at import to eliminate redundant SMPTE/frame rate/string conversions
    public let startFrameNumber: Int?  // Frame number from sourceTimecode (via SMPTE)
    public let endFrameNumber: Int?    // Frame number from endTimecode (via SMPTE)
    public let frameRateFloat: Float?  // Float conversion of frameRate (num/den)
    public let fileNameLower: String   // Lowercase filename for case-insensitive comparisons
    public let reelNameLower: String?  // Lowercase reel name for case-insensitive comparisons

    public init(fileName: String, url: URL, resolution: CGSize?, displayResolution: CGSize?, sampleAspectRatio: String?, frameRate: AVRational?, sourceTimecode: String?, endTimecode: String?, durationInFrames: Int64?, isDropFrame: Bool?, reelName: String?, isInterlaced: Bool?, fieldOrder: String?, mediaType: MediaType, isVFXShot: Bool? = nil, startFrameNumber: Int? = nil, endFrameNumber: Int? = nil, frameRateFloat: Float? = nil, fileNameLower: String? = nil, reelNameLower: String? = nil) {
        self.fileName = fileName
        self.url = url
        self.resolution = resolution
        self.displayResolution = displayResolution
        self.sampleAspectRatio = sampleAspectRatio
        self.frameRate = frameRate
        self.sourceTimecode = sourceTimecode
        self.endTimecode = endTimecode
        self.durationInFrames = durationInFrames
        self.isDropFrame = isDropFrame
        self.reelName = reelName
        self.isInterlaced = isInterlaced
        self.fieldOrder = fieldOrder
        self.mediaType = mediaType
        // Auto-detect VFX from filename if not explicitly set
        self.isVFXShot = isVFXShot
        // Pre-computed fields (performance optimization)
        self.startFrameNumber = startFrameNumber
        self.endFrameNumber = endFrameNumber
        self.frameRateFloat = frameRateFloat
        self.fileNameLower = fileNameLower ?? fileName.lowercased()
        self.reelNameLower = reelNameLower ?? reelName?.lowercased()
    }

    // MARK: - Computed Properties
    
    /// Returns true if this is marked as a VFX shot (with filename fallback for legacy files)
    public var isVFX: Bool {
        return isVFXShot ?? fileName.uppercased().contains("VFX")
    }

    /// Effective display resolution (SAR-corrected for ARRI, or coded resolution for others)
    public var effectiveDisplayResolution: CGSize? {
        if let displayRes = displayResolution {
            return displayRes
        }
        // Calculate from SAR if we have sensor cropping data but missing displayResolution
        if let resolution = resolution, let sar = sampleAspectRatio, sar != "1:1" {
            let components = sar.split(separator: ":")
            if components.count == 2,
                let num = Float(components[0]),
                let den = Float(components[1])
            {
                let displayWidth = Float(resolution.width) * num / den
                return CGSize(width: CGFloat(displayWidth), height: resolution.height)
            }
        }
        return resolution
    }

    /// Does this file have sensor cropping/padding?
    public var hasSensorCropping: Bool {
        return sampleAspectRatio != "1:1" && sampleAspectRatio != nil
    }

    /// Scan type description
    public var scanTypeDescription: String {
        guard let isInterlaced = isInterlaced else { return "Unknown" }
        return isInterlaced ? "Interlaced" : "Progressive"
    }

    /// Frame rate description with precision info and drop frame indication
    /// Uses pre-computed float value to avoid redundant divisions
    public var frameRateDescription: String {
        guard let frameRate = frameRate,
              let floatValue = effectiveFrameRateFloat else { return "Unknown" }

        let dropFrameInfo = isDropFrame == true ? " (drop frame)" : ""
        let rationalNotation = "\(frameRate.num)/\(frameRate.den)"

        return "\(floatValue)fps (\(rationalNotation))\(dropFrameInfo)"
    }

    /// Frame rate as Double for SMPTE and precise calculations
    /// Uses pre-computed float value to avoid redundant divisions
    public var frameRateDouble: Double? {
        guard let floatValue = effectiveFrameRateFloat else { return nil }
        return Double(floatValue)
    }

    /// Duration in seconds for display
    /// Uses pre-computed frame rate to avoid redundant divisions
    public var durationInSeconds: Double? {
        guard let frames = durationInFrames,
              let fps = frameRateDouble,
              fps > 0 else { return nil }
        return Double(frames) / fps
    }

    // MARK: - Performance Optimization: Effective Frame Numbers with Fallback

    /// Start frame number with fallback for legacy files
    /// Returns pre-computed value if available, otherwise computes on-the-fly
    public var effectiveStartFrame: Int? {
        // Fast path: use pre-computed value (files imported with optimization)
        if let precomputed = startFrameNumber {
            return precomputed
        }

        // Fallback path: compute on-the-fly for legacy .w2 files
        guard let startTC = sourceTimecode,
              let fps = effectiveFrameRateFloat,
              let dropFrame = isDropFrame else {
            return nil
        }

        let smpte = SMPTE(fps: Double(fps), dropFrame: dropFrame)
        return try? smpte.getFrames(tc: startTC)
    }

    /// End frame number with fallback for legacy files
    /// Returns pre-computed value if available, otherwise computes on-the-fly
    public var effectiveEndFrame: Int? {
        // Fast path: use pre-computed value (files imported with optimization)
        if let precomputed = endFrameNumber {
            return precomputed
        }

        // Fallback path: compute on-the-fly for legacy .w2 files
        guard let endTC = endTimecode,
              let fps = effectiveFrameRateFloat,
              let dropFrame = isDropFrame else {
            return nil
        }

        let smpte = SMPTE(fps: Double(fps), dropFrame: dropFrame)
        return try? smpte.getFrames(tc: endTC)
    }

    /// Effective frame rate float with fallback for legacy files
    /// Returns pre-computed value if available, otherwise computes on-the-fly
    public var effectiveFrameRateFloat: Float? {
        // Fast path: use pre-computed value (files imported with optimization)
        if let precomputed = frameRateFloat {
            return precomputed
        }

        // Fallback path: compute on-the-fly for legacy .w2 files
        guard let fps = frameRate else { return nil }
        return Float(fps.num) / Float(fps.den)
    }

    /// Technical summary for display
    public var technicalSummary: String {
        var summary: [String] = []

        if let resolution = resolution {
            summary.append("📐 \(Int(resolution.width))x\(Int(resolution.height))")
        }

        if hasSensorCropping, let effectiveRes = effectiveDisplayResolution {
            summary.append("📺 \(Int(effectiveRes.width))x\(Int(effectiveRes.height)) (cropped)")
        }

        summary.append("🎬 \(frameRateDescription)")
        summary.append("📺 \(scanTypeDescription)")

        if let timecode = sourceTimecode {
            summary.append("⏰ \(timecode)")
        }

        return summary.joined(separator: " • ")
    }
}

public enum MediaType: Codable {
    case gradedSegment
    case originalCameraFile
}

// MARK: - Media Analysis
public class MediaAnalyzer {
    public init() {}

    public func analyzeMediaFile(at url: URL, type: MediaType) async throws -> MediaFileInfo {
        // Extract properties using SwiftFFmpeg - no fallbacks, only real data
        var resolution: CGSize? = nil
        var displayResolution: CGSize? = nil
        var sampleAspectRatio: String? = nil
        var frameRate: AVRational? = nil
        var frameRateFloat: Float? = nil  // Pre-computed to avoid redundant divisions
        var sourceTimecode: String? = nil
        var endTimecode: String? = nil
        var durationInFrames: Int64? = nil
        var isDropFrame: Bool? = nil  // unknown until determined by timecode analysis
        var reelName: String? = nil
        var isInterlaced: Bool? = nil  // unknown until determined by FFmpeg
        var fieldOrder: String? = nil

        do {
            let fmtCtx = try AVFormatContext(url: url.path)
            try fmtCtx.findStreamInfo()

            // Find video stream manually since the API seems different
            for i in 0..<fmtCtx.streamCount {
                let stream = fmtCtx.streams[Int(i)]
                let codecPar = stream.codecParameters

                // Check if this is a video stream by checking if it has width/height
                if codecPar.width > 0 && codecPar.height > 0 {
                    resolution = CGSize(
                        width: CGFloat(codecPar.width), height: CGFloat(codecPar.height))

                    // Extract Sample Aspect Ratio and calculate display resolution
                    let sar = stream.sampleAspectRatio
                    if sar.den > 0 && sar.num > 0 {
                        sampleAspectRatio = "\(sar.num):\(sar.den)"
                        print(
                            "    📐 Sample Aspect Ratio: \(sampleAspectRatio!) (sensor crop/padding)"
                        )
                        
                        // Calculate display resolution (SAR-corrected) during import
                        if sampleAspectRatio != "1:1" {
                            let displayWidth = Float(resolution!.width) * Float(sar.num) / Float(sar.den)
                            displayResolution = CGSize(width: CGFloat(displayWidth), height: resolution!.height)
                            print(
                                "    📺 SAR-corrected display resolution: \(Int(displayResolution!.width))x\(Int(displayResolution!.height))"
                            )
                        }
                    }

                    // Extract frame rate - store original AVRational for perfect precision
                    // Try realFramerate first (equivalent to r_frame_rate - most accurate)
                    let realFR = stream.realFramerate
                    if realFR.den > 0 {
                        frameRate = realFR  // Store original rational directly!
                        let floatValue = Float(realFR.num) / Float(realFR.den)
                        print("    📊 realFramerate: \(floatValue)fps (\(realFR.num)/\(realFR.den)) - stored as exact rational")
                    } else {
                        // Fallback to averageFramerate if realFramerate is unavailable
                        let avgFR = stream.averageFramerate
                        if avgFR.den > 0 {
                            frameRate = avgFR  // Store original rational directly!
                            let floatValue = Float(avgFR.num) / Float(avgFR.den)
                            print(
                                "    📊 averageFramerate (fallback): \(floatValue)fps (\(avgFR.num)/\(avgFR.den)) - stored as exact rational"
                            )
                        }
                    }

                    // Explore additional stream properties
                    print("    🔍 Additional stream info:")

                    // frameCount
                    print("    🎞️ frameCount: \(stream.frameCount)")

                    // startTime
                    print("    🚀 startTime: \(stream.startTime)")

                    // duration
                    print("    ⏱️ duration: \(stream.duration)")

                    // Stream metadata
                    if !stream.metadata.isEmpty {
                        print("    📋 Stream metadata:")
                        for (key, value) in stream.metadata {
                            print("      \(key): \(value)")
                        }
                    } else {
                        print("    📋 No stream metadata found")
                    }

                    // Pre-compute frame rate float once to avoid redundant divisions during analysis
                    if let fps = frameRate {
                        frameRateFloat = Float(fps.num) / Float(fps.den)
                    }

                    // Extract timecode using same approach as ffmpeg script
                    sourceTimecode = extractTimecode(from: fmtCtx)

                    // Detect drop frame from timecode format and frame rate
                    if let timecode = sourceTimecode, let floatFps = frameRateFloat {
                        isDropFrame = detectDropFrame(timecode: timecode, frameRate: floatFps)
                    }

                    // Calculate end timecode and duration
                    // MXF files often have unreliable frameCount metadata, calculate from duration and framerate
                    if stream.frameCount > 0 {
                        durationInFrames = Int64(stream.frameCount)
                        print("    📊 Using stream frameCount: \(durationInFrames) frames")
                    } else if let floatFps = frameRateFloat, stream.duration > 0 {
                        // For MXF files, duration is often in frame units already, despite timebase
                        // Try direct duration first, then fallback to timebase calculation
                        if stream.timebase.num == 1001 && (stream.timebase.den == 24000 || stream.timebase.den == 30000 || stream.timebase.den == 60000) {
                            // Common professional timebase - duration is likely already in frame units
                            durationInFrames = Int64(stream.duration)
                            print("    📊 Using duration directly as frame count: \(durationInFrames) frames (professional timebase \(stream.timebase))")
                        } else {
                            // Calculate frames from duration and framerate for other cases
                            let timebaseSeconds = Double(stream.duration) * Double(stream.timebase.num) / Double(stream.timebase.den)
                            durationInFrames = Int64(round(timebaseSeconds * Double(floatFps)))
                            print("    📊 Calculated from duration: \(durationInFrames) frames (duration=\(stream.duration) timebase=\(stream.timebase) fps=\(floatFps))")
                        }
                    } else {
                        durationInFrames = 0
                        print("    ⚠️ Cannot determine frame count - insufficient duration/framerate info")
                    }

                    if let startTC = sourceTimecode, let floatFps = frameRateFloat, let frames = durationInFrames, frames > 0 {
                        endTimecode = calculateEndTimecode(startTimecode: startTC, frameRate: floatFps, durationFrames: frames)
                    }

                    // Extract reel name from metadata
                    reelName = extractReelName(from: fmtCtx)

                    // Detect interlaced vs progressive
                    let (interlaced, order) = detectInterlacing(from: stream)
                    isInterlaced = interlaced
                    fieldOrder = order

                    break
                }
            }
        } catch {
            print("    ⚠️ FFmpeg analysis failed: \(error) - no media properties available")
        }

        // MARK: - Pre-Compute Frame Numbers
        // Compute frame numbers once at import to eliminate redundant SMPTE calculations during linking
        var startFrameNumber: Int? = nil
        var endFrameNumber: Int? = nil

        // frameRateFloat was already computed during analysis above (or is nil if analysis failed)
        // No need to recompute here

        // Compute start and end frame numbers using SMPTE
        if let startTC = sourceTimecode, let fps = frameRateFloat, let dropFrame = isDropFrame {
            let smpte = SMPTE(fps: Double(fps), dropFrame: dropFrame)

            do {
                // Convert start timecode to frame number
                startFrameNumber = try smpte.getFrames(tc: startTC)
                print("    🎯 Pre-computed startFrameNumber: \(startFrameNumber!) (from \(startTC))")

                // Convert end timecode to frame number if available
                if let endTC = endTimecode {
                    endFrameNumber = try smpte.getFrames(tc: endTC)
                    print("    🎯 Pre-computed endFrameNumber: \(endFrameNumber!) (from \(endTC))")
                }
            } catch let error as SMPTEError {
                print("    ⚠️ Failed to pre-compute frame numbers: \(error.localizedDescription)")
            } catch {
                print("    ⚠️ Unexpected error computing frame numbers: \(error)")
            }
        }

        // Pre-compute normalized strings for case-insensitive comparisons
        let fileName = url.lastPathComponent
        let fileNameLower = fileName.lowercased()
        let reelNameLower = reelName?.lowercased()

        return MediaFileInfo(
            fileName: fileName,
            url: url,
            resolution: resolution,
            displayResolution: displayResolution,
            sampleAspectRatio: sampleAspectRatio,
            frameRate: frameRate,
            sourceTimecode: sourceTimecode,
            endTimecode: endTimecode,
            durationInFrames: durationInFrames,
            isDropFrame: isDropFrame,
            reelName: reelName,
            isInterlaced: isInterlaced,
            fieldOrder: fieldOrder,
            mediaType: type,
            isVFXShot: nil,
            startFrameNumber: startFrameNumber,
            endFrameNumber: endFrameNumber,
            frameRateFloat: frameRateFloat,
            fileNameLower: fileNameLower,
            reelNameLower: reelNameLower
        )
    }

    private func calculateEndTimecode(startTimecode: String, frameRate: Float, durationFrames: Int64) -> String? {
        // Use SMPTE library for professional timecode calculation
        let isDropFrame = startTimecode.contains(";")
        let smpte = SMPTE(fps: Double(frameRate), dropFrame: isDropFrame)
        
        do {
            // Use SMPTE library to add frames to the start timecode
            let endTimecode = try smpte.addFrames(to: startTimecode, frames: Int(durationFrames))
            let dropFrameInfo = isDropFrame ? " (drop frame)" : ""
            print("    ⏰ Calculated end timecode: \(endTimecode) (duration: \(durationFrames) frames)\(dropFrameInfo)")
            return endTimecode
            
        } catch let error as SMPTEError {
            print("    ⚠️ SMPTE timecode calculation error: \(error.localizedDescription)")
            return nil
        } catch {
            print("    ⚠️ Unexpected timecode calculation error: \(error)")
            return nil
        }
    }
    
    private func detectDropFrame(timecode: String, frameRate: Float) -> Bool {
        // Use centralized FrameRateManager for professional drop frame detection
        return FrameRateManager.detectDropFrame(timecode: timecode, frameRate: frameRate)
    }

    private func extractTimecode(from formatContext: AVFormatContext) -> String? {
        // Method 1: Check format metadata first (like ffprobe format_tags=timecode)
        if let timecode = formatContext.metadata["timecode"] {
            print("    🎬 Found timecode in format metadata: \(timecode)")
            return timecode
        }

        // Method 2: Check ALL streams for timecode metadata (especially data streams like rtmd)
        for i in 0..<formatContext.streamCount {
            let stream = formatContext.streams[Int(i)]
            
            // Check for timecode in stream metadata
            if let timecode = stream.metadata["timecode"] {
                print("    🎬 Found timecode in stream \(i) metadata: \(timecode)")
                return timecode
            }
        }

        // Method 3: Check additional common timecode metadata keys
        let timecodeKeys = ["SMPTE_time_code", "tc", "TimeCode", "start_timecode"]

        // Check format level first
        for key in timecodeKeys {
            if let value = formatContext.metadata[key] {
                print("    🎬 Found timecode in format metadata (\(key)): \(value)")
                return value
            }
        }

        // Then check all streams for additional keys
        for i in 0..<formatContext.streamCount {
            let stream = formatContext.streams[Int(i)]
            for key in timecodeKeys {
                if let value = stream.metadata[key] {
                    print("    🎬 Found timecode in stream \(i) metadata (\(key)): \(value)")
                    return value
                }
            }
        }

        print("    ⚠️ No timecode found in metadata")
        return nil
    }

    private func extractReelName(from formatContext: AVFormatContext) -> String? {
        // Common reel name metadata keys
        let reelKeys = ["reel", "reel_name", "tape_name", "source_reel", "camera_name"]

        for key in reelKeys {
            if let value = formatContext.metadata[key] {
                return value
            }
        }

        return nil
    }

    private func detectInterlacing(from stream: AVStream) -> (Bool?, String?) {
        // Method 1: Check codec parameters for field order - most reliable
        let codecPar = stream.codecParameters

        if codecPar.fieldOrder.rawValue != 0 {  // AV_FIELD_UNKNOWN = 0
            let fieldOrderName = getFieldOrderName(codecPar.fieldOrder)
            let isInterlaced = fieldOrderName != "progressive" && fieldOrderName != "unknown"

            print("    🎬 Field order from codec: \(fieldOrderName) (interlaced: \(isInterlaced))")
            return (isInterlaced, fieldOrderName)
        }

        // Method 2: Check metadata for explicit interlacing information
        let interlacedKeys = ["field_order", "interlaced", "scan_type", "progressive"]

        for key in interlacedKeys {
            if let value = stream.metadata[key] {
                print("    🎬 Found scan info in stream metadata (\(key)): \(value)")

                if let isInterlaced = determineInterlacingFromMetadata(key: key, value: value) {
                    return (isInterlaced, value)
                }
            }
        }

        // No definitive interlacing information found in FFmpeg data
        print("    ⚠️ No definitive interlacing information found in FFmpeg")
        return (nil, nil)
    }

    private func getFieldOrderName(_ fieldOrder: AVFieldOrder) -> String {
        // Use numeric values instead of constants for compatibility
        switch fieldOrder.rawValue {
        case 1:  // Progressive
            return "progressive"
        case 2:  // Top field first
            return "top_field_first"
        case 3:  // Bottom field first
            return "bottom_field_first"
        case 4:  // Top then bottom
            return "top_bottom"
        case 5:  // Bottom then top
            return "bottom_top"
        default:
            return "unknown"
        }
    }

    private func determineInterlacingFromMetadata(key: String, value: String) -> Bool? {
        let lowerValue = value.lowercased()

        switch key {
        case "progressive":
            if lowerValue == "0" || lowerValue == "false" {
                return true  // progressive=false means interlaced
            } else if lowerValue == "1" || lowerValue == "true" {
                return false  // progressive=true means not interlaced
            }
        case "interlaced":
            if lowerValue == "1" || lowerValue == "true" {
                return true  // interlaced=true
            } else if lowerValue == "0" || lowerValue == "false" {
                return false  // interlaced=false
            }
        case "scan_type":
            if lowerValue.contains("interlac") {
                return true
            } else if lowerValue.contains("prog") {
                return false
            }
        case "field_order":
            if lowerValue.contains("prog") {
                return false  // progressive
            } else if lowerValue.contains("top") || lowerValue.contains("bottom") {
                return true  // has field order info = interlaced
            }
        default:
            break
        }

        // Return nil if we can't definitively determine from the metadata value
        return nil
    }
}

enum MediaAnalysisError: Error {
    case noVideoTrack
    case unsupportedFormat
    case fileNotFound
}

// MARK: - Import Process
public class ImportProcess {
    private let analyzer = MediaAnalyzer()

    public init() {}

    // Import graded segments from a directory
    public func importGradedSegments(from directoryURL: URL) async throws -> [MediaFileInfo] {
        print("🎬 Importing graded segments from: \(directoryURL.path)")
        return try await importMediaFiles(from: directoryURL, type: .gradedSegment)
    }

    // Import original camera files from a directory
    public func importOriginalCameraFiles(from directoryURL: URL) async throws -> [MediaFileInfo] {
        print("📹 Importing original camera files from: \(directoryURL.path)")
        return try await importMediaFiles(from: directoryURL, type: .originalCameraFile)
    }

    // Import original camera files from multiple directories
    public func importOriginalCameraFiles(from directoryURLs: [URL]) async throws -> [MediaFileInfo] {
        print("📹 Importing original camera files from \(directoryURLs.count) directories...")
        var allMediaFiles: [MediaFileInfo] = []
        
        for directoryURL in directoryURLs {
            print("📂 Processing directory: \(directoryURL.lastPathComponent)")
            let mediaFiles = try await importMediaFiles(from: directoryURL, type: .originalCameraFile)
            allMediaFiles.append(contentsOf: mediaFiles)
        }
        
        print("✅ Total imported: \(allMediaFiles.count) original camera files from all directories")
        return allMediaFiles
    }

    // Generic function to import media files
    private func importMediaFiles(from directoryURL: URL, type: MediaType) async throws
        -> [MediaFileInfo]
    {
        let fileManager = FileManager.default

        // Get all video files from directory recursively
        let fileURLs = try getAllVideoFiles(from: directoryURL, fileManager: fileManager)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var mediaFiles: [MediaFileInfo] = []

        for url in fileURLs {
            print("  📂 Processing: \(url.lastPathComponent)")

            do {
                let mediaInfo = try await analyzer.analyzeMediaFile(at: url, type: type)
                mediaFiles.append(mediaInfo)

                // Print extracted info
                if let resolution = mediaInfo.resolution {
                    print("    Resolution: \(Int(resolution.width))x\(Int(resolution.height))")
                } else {
                    print("    Resolution: Unknown (no info from FFmpeg)")
                }
                if let sar = mediaInfo.sampleAspectRatio {
                    print("    Sample Aspect Ratio: \(sar)")
                }
                if let frameRate = mediaInfo.frameRate {
                    let floatValue = Float(frameRate.num) / Float(frameRate.den)
                    print("    Frame Rate: \(floatValue)fps (\(frameRate.num)/\(frameRate.den))")
                } else {
                    print("    Frame Rate: Unknown (no info from FFmpeg)")
                }
                if let isInterlaced = mediaInfo.isInterlaced {
                    print("    Scan Type: \(isInterlaced ? "Interlaced" : "Progressive")")
                } else {
                    print("    Scan Type: Unknown (no definitive info from FFmpeg)")
                }
                if let fieldOrder = mediaInfo.fieldOrder {
                    print("    Field Order: \(fieldOrder)")
                }
                if let timecode = mediaInfo.sourceTimecode {
                    print("    Source Timecode: \(timecode)")
                }
                if let endTimecode = mediaInfo.endTimecode {
                    print("    End Timecode: \(endTimecode)")
                }
                if let duration = mediaInfo.durationInFrames {
                    print("    Duration: \(duration) frames")
                }
                if let reel = mediaInfo.reelName {
                    print("    Reel Name: \(reel)")
                }

            } catch {
                print("    ⚠️ Failed to analyze: \(error)")
            }
        }

        print(
            "✅ Imported \(mediaFiles.count) \(type == .gradedSegment ? "graded segments" : "original camera files")"
        )
        return mediaFiles
    }

    // Recursively get all video files from directory and subdirectories
    private func getAllVideoFiles(from directoryURL: URL, fileManager: FileManager) throws -> [URL] {
        var videoFiles: [URL] = []
        
        // Get directory enumerator for recursive traversal
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MediaAnalysisError.fileNotFound
        }
        
        print("🔍 Recursively scanning directory: \(directoryURL.path)")
        
        for case let fileURL as URL in enumerator {
            do {
                let resourceValues = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                
                // Only process regular files (not directories)
                if resourceValues.isRegularFile == true && isVideoFile(fileURL) {
                    videoFiles.append(fileURL)
                    
                    // Print relative path for cleaner output
                    let relativePath = fileURL.path.replacingOccurrences(of: directoryURL.path + "/", with: "")
                    print("  🎬 Found video file: \(relativePath)")
                }
            } catch {
                print("  ⚠️ Error checking file \(fileURL.lastPathComponent): \(error)")
            }
        }
        
        print("🔍 Found \(videoFiles.count) video files total")
        return videoFiles
    }

    // Check if file is a supported video format
    private func isVideoFile(_ url: URL) -> Bool {
        let videoExtensions = ["mov", "mp4", "mxf", "avi", "mkv", "m4v", "prores"]
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext)
    }
}
