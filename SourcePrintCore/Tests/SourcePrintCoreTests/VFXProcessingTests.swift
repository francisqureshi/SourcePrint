//
//  VFXProcessingTests.swift
//  ProResWriterCoreTests
//
//  Tests for Frame Ownership Analysis System and VFX Priority
//  Using Theory Holiday test data for comprehensive overlap and VFX validation
//

import XCTest
import SwiftFFmpeg
import AVFoundation
import CoreMedia
import TimecodeKit
@testable import SourcePrintCore

final class VFXProcessingTests: XCTestCase {

    // MARK: - Theory Holiday Test Data

    struct TheoryHolidayTestData {
        static let ocfPath = "/Volumes/EVO-POST/__POST/1677 - THEORY HOLIDAY/02_FOOTAGE/TRANSCODES/WILD ISLAND TRANSCODES/A006C005_250717MC.mov"
        static let gradeSegmentPath = "/Volumes/EVO-POST/__POST/1677 - THEORY HOLIDAY/08_GRADE/02_GRADED CLIPS/03 INTERMEDIATE/G12/V1-0088_A006C005_250717MC.mov"
        static let vfxSegmentPath = "/Volumes/EVO-POST/__POST/1677 - THEORY HOLIDAY/08_GRADE/02_GRADED CLIPS/03 INTERMEDIATE/G12/V1-0223_A006C005_250717MC__S0020_VFX_EX_0821_v1.mov"
        static let outputDirectory = "/Users/mac10/Desktop/OUT"
        static let blankRushDirectory = "/Users/mac10/Desktop/BlankRush"
    }

    // MARK: - Test File Validation

    private func requireTheoryHolidayFixtures() throws {
        let paths = [TheoryHolidayTestData.ocfPath, TheoryHolidayTestData.gradeSegmentPath,
                     TheoryHolidayTestData.vfxSegmentPath]
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
            throw XCTSkip("Requires external Theory Holiday footage on EVO-POST")
        }
    }

    func testTheoryHolidayTestFilesExist() throws {
        try requireTheoryHolidayFixtures()
        let fileManager = FileManager.default

        XCTAssertTrue(
            fileManager.fileExists(atPath: TheoryHolidayTestData.ocfPath),
            "OCF file should exist at: \(TheoryHolidayTestData.ocfPath)"
        )

        XCTAssertTrue(
            fileManager.fileExists(atPath: TheoryHolidayTestData.gradeSegmentPath),
            "Grade segment should exist at: \(TheoryHolidayTestData.gradeSegmentPath)"
        )

        XCTAssertTrue(
            fileManager.fileExists(atPath: TheoryHolidayTestData.vfxSegmentPath),
            "VFX segment should exist at: \(TheoryHolidayTestData.vfxSegmentPath)"
        )
    }

    // MARK: - Frame Ownership Analysis Tests

    func testFrameOwnershipAnalyzer_VFXPriority() throws {
        // Create mock base properties for 1000 frame timeline
        let baseProperties = VideoStreamProperties(
            width: 1920,
            height: 1080,
            frameRate: AVRational(num: 25, den: 1),
            frameRateFloat: 25.0,
            duration: 40.0, // 40 seconds
            timebase: AVRational(num: 1, den: 25),
            timecode: "01:00:00:00"
        )

        // Create grade segment: frames 100-900 (covers most of timeline)
        let gradeSegment = FFmpegGradedSegment(
            url: URL(fileURLWithPath: TheoryHolidayTestData.gradeSegmentPath),
            startTime: CMTime(seconds: 4.0, preferredTimescale: 600), // Frame 100
            duration: CMTime(seconds: 32.0, preferredTimescale: 600), // 800 frames
            sourceStartTime: CMTime.zero,
            isVFXShot: false,
            sourceTimecode: "01:00:04:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        // Create VFX segment: frames 400-500 (inside grade segment)
        let vfxSegment = FFmpegGradedSegment(
            url: URL(fileURLWithPath: TheoryHolidayTestData.vfxSegmentPath),
            startTime: CMTime(seconds: 16.0, preferredTimescale: 600), // Frame 400
            duration: CMTime(seconds: 4.0, preferredTimescale: 600), // 100 frames
            sourceStartTime: CMTime.zero,
            isVFXShot: true, // VFX shot!
            sourceTimecode: "01:00:16:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        let segments = [gradeSegment, vfxSegment]
        let analyzer = FrameOwnershipAnalyzer(
            baseProperties: baseProperties,
            segments: segments,
            totalFrames: 1000,
            verbose: true
        )

        let processingPlan = try analyzer.analyze()

        print("📊 Frame Ownership Analysis Results:")
        print("   Total frames: \(processingPlan.statistics.totalFrames)")
        print("   Segments: \(processingPlan.statistics.segmentCount) (\(processingPlan.statistics.vfxSegmentCount) VFX)")
        print("   Overlaps: \(processingPlan.statistics.overlapCount)")
        print("   VFX frames: \(processingPlan.statistics.vfxFrames)")
        print("   Grade frames: \(processingPlan.statistics.gradeFrames)")

        // Verify statistics
        XCTAssertEqual(processingPlan.statistics.segmentCount, 2)
        XCTAssertEqual(processingPlan.statistics.vfxSegmentCount, 1)
        XCTAssertEqual(processingPlan.statistics.overlapCount, 1) // Grade and VFX overlap
        XCTAssertEqual(processingPlan.statistics.vfxFrames, 100) // VFX is 100 frames
        XCTAssertEqual(processingPlan.statistics.gradeFrames, 700) // Grade minus VFX overlap

        // Should have 3 ranges: Grade[100-400], VFX[400-500], Grade[500-900]
        XCTAssertEqual(processingPlan.consolidatedRanges.count, 3)

        let ranges = processingPlan.consolidatedRanges

        // First range: Grade segment frames 100-400
        XCTAssertEqual(ranges[0].startFrame, 100)
        XCTAssertEqual(ranges[0].endFrame, 400)
        XCTAssertEqual(ranges[0].segmentStartOffset, 0)
        XCTAssertEqual(ranges[0].segment.url.lastPathComponent, "V1-0088_A006C005_250717MC.mov")

        // Second range: VFX segment frames 400-500
        XCTAssertEqual(ranges[1].startFrame, 400)
        XCTAssertEqual(ranges[1].endFrame, 500)
        XCTAssertEqual(ranges[1].segmentStartOffset, 0)
        XCTAssertEqual(ranges[1].segment.url.lastPathComponent, "V1-0223_A006C005_250717MC__S0020_VFX_EX_0821_v1.mov")
        XCTAssertTrue(ranges[1].segment.isVFXShot)

        // Third range: Grade segment frames 500-900 (continues from frame 400 of grade)
        XCTAssertEqual(ranges[2].startFrame, 500)
        XCTAssertEqual(ranges[2].endFrame, 900)
        XCTAssertEqual(ranges[2].segmentStartOffset, 400) // Offset into grade segment!
        XCTAssertEqual(ranges[2].segment.url.lastPathComponent, "V1-0088_A006C005_250717MC.mov")

        print("\n🎬 Processing Ranges:")
        for (index, range) in ranges.enumerated() {
            let vfxTag = range.segment.isVFXShot ? " [VFX]" : ""
            print("   \(index + 1). \(range.description)\(vfxTag)")
        }
    }

    func testFrameOwnershipAnalyzer_ComplexOverlaps() throws {
        // Test complex scenario with multiple overlapping grade segments and VFX priority
        let baseProperties = VideoStreamProperties(
            width: 1920,
            height: 1080,
            frameRate: AVRational(num: 25, den: 1),
            frameRateFloat: 25.0,
            duration: 40.0,
            timebase: AVRational(num: 1, den: 25),
            timecode: "01:00:00:00"
        )

        // Grade1: frames 100-600
        let grade1 = FFmpegGradedSegment(
            url: URL(fileURLWithPath: "/test/Grade1.mov"),
            startTime: CMTime(seconds: 4.0, preferredTimescale: 600),
            duration: CMTime(seconds: 20.0, preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: false,
            sourceTimecode: "01:00:04:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        // VFX1: frames 200-300 (overlaps Grade1)
        let vfx1 = FFmpegGradedSegment(
            url: URL(fileURLWithPath: "/test/VFX1.mov"),
            startTime: CMTime(seconds: 8.0, preferredTimescale: 600),
            duration: CMTime(seconds: 4.0, preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: true,
            sourceTimecode: "01:00:08:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        // Grade2: frames 250-700 (overlaps both Grade1 and VFX1)
        let grade2 = FFmpegGradedSegment(
            url: URL(fileURLWithPath: "/test/Grade2.mov"),
            startTime: CMTime(seconds: 10.0, preferredTimescale: 600),
            duration: CMTime(seconds: 18.0, preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: false,
            sourceTimecode: "01:00:10:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        // VFX2: frames 400-500 (overlaps Grade2)
        let vfx2 = FFmpegGradedSegment(
            url: URL(fileURLWithPath: "/test/VFX2.mov"),
            startTime: CMTime(seconds: 16.0, preferredTimescale: 600),
            duration: CMTime(seconds: 4.0, preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: true,
            sourceTimecode: "01:00:16:00",
            frameRate: 25.0,
            frameRateRational: AVRational(num: 25, den: 1),
            isDropFrame: false
        )

        let segments = [grade1, vfx1, grade2, vfx2]
        let analyzer = FrameOwnershipAnalyzer(
            baseProperties: baseProperties,
            segments: segments,
            totalFrames: 1000,
            verbose: true
        )

        let processingPlan = try analyzer.analyze()

        print("\n📊 Complex Overlap Analysis:")
        print("   Segments: \(processingPlan.statistics.segmentCount) (\(processingPlan.statistics.vfxSegmentCount) VFX)")
        print("   Overlaps: \(processingPlan.statistics.overlapCount)")
        print("   Ranges: \(processingPlan.consolidatedRanges.count)")

        // Expected timeline:
        // 100-200: Grade1
        // 200-250: VFX1 (overwrites Grade1)
        // 250-300: VFX1 continues (overwrites Grade2)
        // 300-400: Grade2 (overwrites Grade1)
        // 400-500: VFX2 (overwrites Grade2)
        // 500-600: Grade2 continues
        // 600-700: Grade2 continues

        XCTAssertEqual(processingPlan.statistics.vfxSegmentCount, 2)
        XCTAssertGreaterThan(processingPlan.statistics.overlapCount, 0)

        // Verify VFX segments are preserved
        let vfx1Range = processingPlan.consolidatedRanges.first { $0.segment.url.lastPathComponent == "VFX1.mov" }
        let vfx2Range = processingPlan.consolidatedRanges.first { $0.segment.url.lastPathComponent == "VFX2.mov" }

        XCTAssertNotNil(vfx1Range, "VFX1 should have a range")
        XCTAssertNotNil(vfx2Range, "VFX2 should have a range")
        XCTAssertEqual(vfx1Range?.frameCount, 100)
        XCTAssertEqual(vfx2Range?.frameCount, 100)

        print("\n🎬 Complex Processing Ranges:")
        for (index, range) in processingPlan.consolidatedRanges.enumerated() {
            let vfxTag = range.segment.isVFXShot ? " [VFX]" : ""
            print("   \(index + 1). \(range.description)\(vfxTag)")
        }
    }

    // MARK: - Real World Theory Holiday Test

    func testTheoryHolidayFrameOwnershipAnalysis() async throws {
        try requireTheoryHolidayFixtures()
        print("🧪 Testing Frame Ownership Analysis with real Theory Holiday files...")

        // Import actual files
        let analyzer = MediaAnalyzer()

        let ocfURL = URL(fileURLWithPath: TheoryHolidayTestData.ocfPath)
        let gradeURL = URL(fileURLWithPath: TheoryHolidayTestData.gradeSegmentPath)
        let vfxURL = URL(fileURLWithPath: TheoryHolidayTestData.vfxSegmentPath)

        let ocfFile = try await analyzer.analyzeMediaFile(at: ocfURL, type: .originalCameraFile)
        let gradeSegment = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        var vfxSegment = try await analyzer.analyzeMediaFile(at: vfxURL, type: .gradedSegment)
        vfxSegment.isVFXShot = true

        print("\n📹 Real Files Analysis:")
        print("   OCF: \(ocfFile.fileName) - \(ocfFile.durationInFrames ?? 0) frames")
        print("   Grade: \(gradeSegment.fileName) - \(gradeSegment.durationInFrames ?? 0) frames")
        print("   VFX: \(vfxSegment.fileName) - \(vfxSegment.durationInFrames ?? 0) frames")

        // Convert to FFmpegGradedSegments for analysis
        let ffmpegGradeSegment = FFmpegGradedSegment(
            url: gradeSegment.url,
            startTime: CMTime.zero,
            duration: CMTime(seconds: Double(gradeSegment.durationInFrames ?? 0) / Double(gradeSegment.frameRate?.floatValue ?? 25.0), preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: false,
            sourceTimecode: gradeSegment.sourceTimecode,
            frameRate: gradeSegment.frameRate?.floatValue,
            frameRateRational: gradeSegment.frameRate,
            isDropFrame: gradeSegment.isDropFrame
        )

        let ffmpegVFXSegment = FFmpegGradedSegment(
            url: vfxSegment.url,
            startTime: CMTime(seconds: 0.76, preferredTimescale: 600), // Approximate 19-frame offset
            duration: CMTime(seconds: Double(vfxSegment.durationInFrames ?? 0) / Double(vfxSegment.frameRate?.floatValue ?? 25.0), preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: true,
            sourceTimecode: vfxSegment.sourceTimecode,
            frameRate: vfxSegment.frameRate?.floatValue,
            frameRateRational: vfxSegment.frameRate,
            isDropFrame: vfxSegment.isDropFrame
        )

        // Create base properties from OCF
        let baseProperties = VideoStreamProperties(
            width: Int(ocfFile.resolution?.width ?? 1920),
            height: Int(ocfFile.resolution?.height ?? 1080),
            frameRate: ocfFile.frameRate ?? AVRational(num: 25, den: 1),
            frameRateFloat: ocfFile.frameRate?.floatValue ?? 25.0,
            duration: Double(ocfFile.durationInFrames ?? 1000) / Double(ocfFile.frameRate?.floatValue ?? 25.0),
            timebase: AVRational(num: 1, den: Int32(ocfFile.frameRate?.floatValue ?? 25.0)),
            timecode: ocfFile.sourceTimecode
        )

        let segments = [ffmpegGradeSegment, ffmpegVFXSegment]
        let totalFrames = Int(ocfFile.durationInFrames ?? 1000)

        let ownershipAnalyzer = FrameOwnershipAnalyzer(
            baseProperties: baseProperties,
            segments: segments,
            totalFrames: totalFrames,
            verbose: true
        )

        let processingPlan = try ownershipAnalyzer.analyze()

        print("\n📊 Theory Holiday Frame Ownership Results:")
        print("   Total frames: \(processingPlan.statistics.totalFrames)")
        print("   Segments: \(processingPlan.statistics.segmentCount) (\(processingPlan.statistics.vfxSegmentCount) VFX)")
        print("   Overlaps: \(processingPlan.statistics.overlapCount)")
        print("   Processing ranges: \(processingPlan.consolidatedRanges.count)")

        // Log warnings
        for warning in processingPlan.overlapWarnings {
            print("   ⚠️ \(warning)")
        }

        // Display processing plan
        print("\n🎬 Theory Holiday Processing Plan:")
        for (index, range) in processingPlan.consolidatedRanges.enumerated() {
            let segmentName = range.segment.url.lastPathComponent
            let vfxTag = range.segment.isVFXShot ? " [VFX]" : " [GRADE]"
            print("   \(index + 1). Frames \(range.startFrame)-\(range.endFrame): \(segmentName)\(vfxTag)")
            if range.segmentStartOffset > 0 {
                print("        ↳ Starting from offset \(range.segmentStartOffset) in source")
            }
        }

        // Verify VFX protection
        XCTAssertEqual(processingPlan.statistics.vfxSegmentCount, 1, "Should have 1 VFX segment")
        XCTAssertGreaterThan(processingPlan.statistics.vfxFrames, 0, "VFX should contribute frames")

        let vfxRange = processingPlan.consolidatedRanges.first { $0.segment.isVFXShot }
        XCTAssertNotNil(vfxRange, "Should have VFX range in processing plan")

        print("✅ Theory Holiday Frame Ownership Analysis completed successfully")
    }

    // MARK: - Print Process Integration Tests

    func testTheoryHolidayPrintProcess() async throws {
        try requireTheoryHolidayFixtures()
        print("🎬 Testing complete print process with Theory Holiday VFX and grade segments...")

        // Import actual files
        let analyzer = MediaAnalyzer()

        let ocfURL = URL(fileURLWithPath: TheoryHolidayTestData.ocfPath)
        let gradeURL = URL(fileURLWithPath: TheoryHolidayTestData.gradeSegmentPath)
        let vfxURL = URL(fileURLWithPath: TheoryHolidayTestData.vfxSegmentPath)

        let ocfFile = try await analyzer.analyzeMediaFile(at: ocfURL, type: .originalCameraFile)
        let gradeSegment = try await analyzer.analyzeMediaFile(at: gradeURL, type: .gradedSegment)
        var vfxSegment = try await analyzer.analyzeMediaFile(at: vfxURL, type: .gradedSegment)
        vfxSegment.isVFXShot = true

        print("\n📹 Setting up print process with:")
        print("   OCF: \(ocfFile.fileName) - \(ocfFile.durationInFrames ?? 0) frames")
        print("   Grade: \(gradeSegment.fileName) - \(gradeSegment.durationInFrames ?? 0) frames")
        print("   VFX: \(vfxSegment.fileName) - \(vfxSegment.durationInFrames ?? 0) frames")

        // Convert to FFmpegGradedSegments with correct timeline positioning
        let gradeStart = CMTime(value: 235, timescale: 24000/1001) // Frame 235 on timeline
        let vfxStart = CMTime(value: 255, timescale: 24000/1001)   // Frame 255 on timeline

        let ffmpegGradeSegment = FFmpegGradedSegment(
            url: gradeSegment.url,
            startTime: gradeStart,
            duration: CMTime(seconds: Double(gradeSegment.durationInFrames ?? 0) / Double(gradeSegment.frameRate?.floatValue ?? 23.976), preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: false,
            sourceTimecode: gradeSegment.sourceTimecode,
            frameRate: gradeSegment.frameRate?.floatValue,
            frameRateRational: gradeSegment.frameRate,
            isDropFrame: gradeSegment.isDropFrame
        )

        let ffmpegVFXSegment = FFmpegGradedSegment(
            url: vfxSegment.url,
            startTime: vfxStart,
            duration: CMTime(seconds: Double(vfxSegment.durationInFrames ?? 0) / Double(vfxSegment.frameRate?.floatValue ?? 23.976), preferredTimescale: 600),
            sourceStartTime: CMTime.zero,
            isVFXShot: true,
            sourceTimecode: vfxSegment.sourceTimecode,
            frameRate: vfxSegment.frameRate?.floatValue,
            frameRateRational: vfxSegment.frameRate,
            isDropFrame: vfxSegment.isDropFrame
        )

        // Check for existing blank rush, or use original OCF for testing
        let blankRushURL = URL(fileURLWithPath: "\(TheoryHolidayTestData.blankRushDirectory)/\(ocfFile.fileName)")
        let blankRushExists = FileManager.default.fileExists(atPath: blankRushURL.path)

        let baseVideoURL: URL
        if blankRushExists {
            print("\n♻️ Using existing blank rush: \(blankRushURL.lastPathComponent)")
            baseVideoURL = blankRushURL
        } else {
            print("\n📹 Using original OCF as base (blank rush not found): \(ocfFile.fileName)")
            baseVideoURL = ocfFile.url
        }

        // Create FFmpeg compositor settings
        let outputURL = URL(fileURLWithPath: "\(TheoryHolidayTestData.outputDirectory)/theory_holiday_vfx_test_output.mov")

        // Ensure output directory exists
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: TheoryHolidayTestData.outputDirectory),
                                               withIntermediateDirectories: true,
                                               attributes: nil)

        let ffmpegSettings = FFmpegCompositorSettings(
            outputURL: outputURL,
            baseVideoURL: baseVideoURL,
            gradedSegments: [ffmpegGradeSegment, ffmpegVFXSegment],
            proResProfile: "4" // ProRes 4444
        )

        print("\n🎯 Print Process Settings:")
        print("   Output: \(outputURL.lastPathComponent)")
        print("   Base video: \(baseVideoURL.lastPathComponent)")
        print("   ProRes profile: \(ffmpegSettings.proResProfile)")
        print("   VFX segments: \(ffmpegSettings.gradedSegments.filter { $0.isVFXShot }.count)")
        print("   Total segments: \(ffmpegSettings.gradedSegments.count)")

        // Run the SwiftFFmpeg print process
        let compositor = SwiftFFmpegProResCompositor()

        print("\n🚀 Starting SwiftFFmpeg print process...")
        let startTime = Date()

        // Set up completion handler to wait for result
        await withCheckedContinuation { continuation in
            compositor.completionHandler = { result in
                continuation.resume()
            }

            compositor.composeVideo(with: ffmpegSettings)
        }

        let processingTime = Date().timeIntervalSince(startTime)
        print("✅ Print process completed in \(String(format: "%.2f", processingTime))s")

        // Verify output file was created
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path), "Output file should exist")

        // Get output file size
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let fileSize = attributes[.size] as? Int64 {
            let fileSizeMB = Double(fileSize) / (1024 * 1024)
            print("📁 Output file: \(String(format: "%.1f", fileSizeMB)) MB")
        }

        print("🎬 Theory Holiday print process with VFX priority system completed successfully!")
        print("   Output location: \(outputURL.path)")
    }

    // MARK: - Performance Tests

    func testFrameOwnershipAnalysisPerformance() throws {
        let baseProperties = VideoStreamProperties(
            width: 1920,
            height: 1080,
            frameRate: AVRational(num: 25, den: 1),
            frameRateFloat: 25.0,
            duration: 3600.0, // 1 hour
            timebase: AVRational(num: 1, den: 25),
            timecode: "01:00:00:00"
        )

        // Create many overlapping segments (stress test)
        var segments: [FFmpegGradedSegment] = []
        for i in 0..<50 {
            let startTime = Double(i * 100) / 25.0 // Every 4 seconds
            let duration = 20.0 // 20 seconds each (overlapping)
            let isVFX = i % 5 == 0 // Every 5th segment is VFX

            let segment = FFmpegGradedSegment(
                url: URL(fileURLWithPath: "/test/Segment\(i).mov"),
                startTime: CMTime(seconds: startTime, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600),
                sourceStartTime: CMTime.zero,
                isVFXShot: isVFX,
                sourceTimecode: nil,
                frameRate: 25.0,
                frameRateRational: AVRational(num: 25, den: 1),
                isDropFrame: false
            )
            segments.append(segment)
        }

        let analyzer = FrameOwnershipAnalyzer(
            baseProperties: baseProperties,
            segments: segments,
            totalFrames: 90000, // 1 hour at 25fps
            verbose: false
        )

        measure {
            do {
                let _ = try analyzer.analyze()
            } catch {
                XCTFail("Analysis failed: \(error)")
            }
        }
    }
}

// MARK: - Helper Extensions

extension MediaFileInfo {
    var frameRateDouble: Double? {
        return frameRate.map { Double($0.floatValue) }
    }
}