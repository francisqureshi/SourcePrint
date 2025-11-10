import XCTest
import SwiftFFmpeg  // For AVRational
@testable import SourcePrintCore

final class ProResWriterCoreTests: XCTestCase {
    
    func testSMPTETimecodeConversion() throws {
        let smpte = SMPTE(fps: 24.0, dropFrame: false)
        
        // Test timecode to frames conversion
        let frames = try smpte.getFrames(tc: "01:00:00:00")
        XCTAssertEqual(frames, 86400) // 1 hour * 60 minutes * 60 seconds * 24 fps
        
        // Test frames to timecode conversion
        let timecode = smpte.getTC(frames: 86400)
        XCTAssertEqual(timecode, "01:00:00:00")
    }
    
    func testSMPTEDropFrameTimecode() throws {
        let smpte = SMPTE(fps: 29.97, dropFrame: true)
        
        // Test drop frame timecode validation
        XCTAssertTrue(smpte.isValidTimecode("01:00:00;02"))
        // Note: SMPTE library accepts both separators for validation
        XCTAssertTrue(smpte.isValidTimecode("01:00:00:02")) // Library accepts both separators
    }
    
    func testImportProcessInitialization() {
        let importer = ImportProcess()
        XCTAssertNotNil(importer)
    }
    
    func testMediaAnalyzerInitialization() {
        let analyzer = MediaAnalyzer()
        XCTAssertNotNil(analyzer)
    }
    
    func testSegmentOCFLinkerInitialization() {
        let linker = SegmentOCFLinker()
        XCTAssertNotNil(linker)
    }
    
    func testLinkingResultInitialization() {
        let linkingResult = LinkingResult(
            ocfParents: [],
            unmatchedSegments: [],
            unmatchedOCFs: []
        )
        
        XCTAssertEqual(linkingResult.totalLinkedSegments, 0)
        XCTAssertEqual(linkingResult.totalSegments, 0)
        XCTAssertEqual(linkingResult.successRate, 0.0)
        XCTAssertTrue(linkingResult.parentsWithChildren.isEmpty)
    }
    
    func testMediaTypeEnum() {
        let ocfType = MediaType.originalCameraFile
        let segmentType = MediaType.gradedSegment
        
        XCTAssertNotEqual(ocfType, segmentType)
    }
    
    func testLinkConfidenceEnum() {
        let highConfidence = LinkConfidence.high
        let lowConfidence = LinkConfidence.low

        XCTAssertNotEqual(highConfidence, lowConfidence)
    }

    // MARK: - Frame Rate Matching Tests

    func testFrameRateMatchingExact() throws {
        let linker = SegmentOCFLinker()

        // Create test OCF and segment with identical frame rates
        let ocf24 = MediaFileInfo(
            fileName: "test_ocf_24.mov",
            url: URL(fileURLWithPath: "/test_ocf_24.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1000),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:01:40:00",
            durationInFrames: 2400,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .originalCameraFile
        )

        let segment24 = MediaFileInfo(
            fileName: "test_ocf_24_segment.mov",
            url: URL(fileURLWithPath: "/test_segment_24.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1000),
            sourceTimecode: "01:00:30:00",
            endTimecode: "01:00:40:00",
            durationInFrames: 240,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .gradedSegment
        )

        // Test exact match
        let result = linker.linkSegments([segment24], withOCFParents: [ocf24])
        XCTAssertEqual(result.totalLinkedSegments, 1, "24fps segment should match 24fps OCF")
        XCTAssertEqual(result.totalSegments, 1)
    }

    func testCriticalFrameRateMismatch24vs23976() throws {
        let linker = SegmentOCFLinker()

        // Create OCF at 24fps and segment at 23.976fps (should NOT match)
        let ocf24 = MediaFileInfo(
            fileName: "test_ocf_24.mov",
            url: URL(fileURLWithPath: "/test_ocf_24.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1000),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:01:40:00",
            durationInFrames: 2400,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .originalCameraFile
        )

        let segment23976 = MediaFileInfo(
            fileName: "test_ocf_23976_segment.mov",
            url: URL(fileURLWithPath: "/test_segment_23976.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1001),
            sourceTimecode: "01:00:30:00",
            endTimecode: "01:00:40:00",
            durationInFrames: 240,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .gradedSegment
        )

        // Test critical mismatch - these should NOT link with new rational arithmetic
        let result = linker.linkSegments([segment23976], withOCFParents: [ocf24])
        XCTAssertEqual(result.totalLinkedSegments, 0, "CRITICAL: 23.976fps segment should NOT match 24fps OCF")
        XCTAssertEqual(result.totalSegments, 1)
        XCTAssertEqual(result.unmatchedSegments.count, 1)
    }

    func testCriticalFrameRateMismatch23976vs24() throws {
        let linker = SegmentOCFLinker()

        // Create OCF at 23.976fps and segment at 24fps (should NOT match)
        let ocf23976 = MediaFileInfo(
            fileName: "test_ocf_23976.mov",
            url: URL(fileURLWithPath: "/test_ocf_23976.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1001),
            sourceTimecode: "01:00:00:00",
            endTimecode: "01:01:40:00",
            durationInFrames: 2398,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .originalCameraFile
        )

        let segment24 = MediaFileInfo(
            fileName: "test_ocf_24_segment.mov",
            url: URL(fileURLWithPath: "/test_segment_24.mov"),
            resolution: Resolution(width: 1920, height: 1080),
            displayResolution: Resolution(width: 1920, height: 1080),
            sampleAspectRatio: "1:1",
            frameRate: AVRational(num: 24000, den: 1000),
            sourceTimecode: "01:00:30:00",
            endTimecode: "01:00:40:00",
            durationInFrames: 240,
            isDropFrame: false,
            reelName: "A001",
            isInterlaced: false,
            fieldOrder: nil,
            mediaType: .gradedSegment
        )

        // Test critical mismatch - these should NOT link with new rational arithmetic
        let result = linker.linkSegments([segment24], withOCFParents: [ocf23976])
        XCTAssertEqual(result.totalLinkedSegments, 0, "CRITICAL: 24fps segment should NOT match 23.976fps OCF")
        XCTAssertEqual(result.totalSegments, 1)
        XCTAssertEqual(result.unmatchedSegments.count, 1)
    }

    // MARK: - FrameRateManager Tests

    func testFrameRateManagerRationalConversion() throws {
        // Test rational conversion with exact NTSC rationals
        let rational23976 = FrameRateManager.convertToRational(frameRate: 23.976)
        XCTAssertEqual(rational23976.num, 24000, "23.976fps should convert to 24000/1001")
        XCTAssertEqual(rational23976.den, 1001, "23.976fps should convert to 24000/1001")

        let rational24 = FrameRateManager.convertToRational(frameRate: 24.0)
        XCTAssertEqual(rational24.num, 24000, "24fps should convert to 24000/1000")
        XCTAssertEqual(rational24.den, 1000, "24fps should convert to 24000/1000")

        let rational2997 = FrameRateManager.convertToRational(frameRate: 29.97)
        XCTAssertEqual(rational2997.num, 30000, "29.97fps should convert to 30000/1001")
        XCTAssertEqual(rational2997.den, 1001, "29.97fps should convert to 30000/1001")
    }

    func testFrameRateManagerCompatibility() throws {
        // Test exact rational matches
        let rational24_1 = AVRational(num: 24000, den: 1000)
        let rational24_2 = AVRational(num: 24000, den: 1000)
        XCTAssertTrue(FrameRateManager.areFrameRatesCompatible(rational24_1, rational24_2), "Identical rationals should match")

        let rational23976_1 = AVRational(num: 23976, den: 1000)
        let rational23976_2 = AVRational(num: 23976, den: 1000)
        XCTAssertTrue(FrameRateManager.areFrameRatesCompatible(rational23976_1, rational23976_2), "Identical 23.976 rationals should match")

        // Test critical mismatches that should NOT match
        let rational24 = AVRational(num: 24000, den: 1000)
        let rational23976 = AVRational(num: 23976, den: 1000)
        XCTAssertFalse(FrameRateManager.areFrameRatesCompatible(rational24, rational23976), "24fps and 23.976fps rationals should NOT match")
        XCTAssertFalse(FrameRateManager.areFrameRatesCompatible(rational23976, rational24), "23.976fps and 24fps rationals should NOT match")

        let rational2997 = AVRational(num: 29970, den: 1000)
        let rational30 = AVRational(num: 30000, den: 1000)
        XCTAssertFalse(FrameRateManager.areFrameRatesCompatible(rational2997, rational30), "29.97fps and 30fps rationals should NOT match")

        // Test legacy Float compatibility (should convert to rationals and compare)
        XCTAssertTrue(FrameRateManager.areFrameRatesCompatible(24.0, 24.0), "Identical float frame rates should match")
        XCTAssertFalse(FrameRateManager.areFrameRatesCompatible(24.0, 23.976), "Different float frame rates should NOT match")
    }

    func testFrameRateManagerDescription() throws {
        // Test professional descriptions with rational notation
        let desc23976 = FrameRateManager.getFrameRateDescription(frameRate: 23.976)
        XCTAssertEqual(desc23976, "23.976025fps (24000/1001)", "Should provide rational notation for 23.976fps")

        let desc24 = FrameRateManager.getFrameRateDescription(frameRate: 24.0)
        XCTAssertEqual(desc24, "24.0fps (24000/1000)", "Should provide 1000-scale rational notation for 24fps")

        let desc25 = FrameRateManager.getFrameRateDescription(frameRate: 25.0)
        XCTAssertEqual(desc25, "25.0fps (25000/1000)", "Should provide 1000-scale rational notation for 25fps")

        let descWithDF = FrameRateManager.getFrameRateDescription(frameRate: 29.97, isDropFrame: true)
        XCTAssertEqual(descWithDF, "29.97003fps (30000/1001) (drop frame)", "Should include drop frame indicator")
    }

    func testFrameRateManagerDropFrameDetection() throws {
        // Test correct drop frame detection
        XCTAssertTrue(FrameRateManager.detectDropFrame(timecode: "01:00:00;00", frameRate: 29.97),
                     "Should detect drop frame with semicolon separator and 29.97fps")

        XCTAssertFalse(FrameRateManager.detectDropFrame(timecode: "01:00:00:00", frameRate: 24.0),
                      "Should detect non-drop frame with colon separator and 24fps")

        // Test inconsistent cases
        let inconsistentDF = FrameRateManager.detectDropFrame(timecode: "01:00:00;00", frameRate: 24.0)
        XCTAssertTrue(inconsistentDF, "Should trust semicolon separator even with non-DF rate")

        let inconsistentNDF = FrameRateManager.detectDropFrame(timecode: "01:00:00:00", frameRate: 29.97)
        XCTAssertFalse(inconsistentNDF, "Should trust colon separator even with DF rate")
    }

    func testFrameRateManagerTimecodeKitIntegration() throws {
        // Test TimecodeKit frame rate conversion
        let timecodeRate23 = FrameRateManager.getTimecodeFrameRate(for: 23)
        XCTAssertEqual(timecodeRate23, .fps23_976, "Should convert 23 to TimecodeKit 23.976")

        let timecodeRate24 = FrameRateManager.getTimecodeFrameRate(for: 24)
        XCTAssertEqual(timecodeRate24, .fps24, "Should convert 24 to TimecodeKit 24fps")

        let timecodeRate29 = FrameRateManager.getTimecodeFrameRate(for: 29)
        XCTAssertEqual(timecodeRate29, .fps29_97, "Should convert 29 to TimecodeKit 29.97")
    }

    func testFrameRateManagerTimescaleCalculation() throws {
        // Test CMTime timescale calculation using rational arithmetic
        let timescale23976 = FrameRateManager.getTimescale(for: 23)
        XCTAssertEqual(timescale23976, 24000, "23.976fps should use 24000 timescale for 24000/1001")

        let timescale24 = FrameRateManager.getTimescale(for: 24)
        XCTAssertEqual(timescale24, 24000, "24fps should use 24000 timescale")

        let timescale2997 = FrameRateManager.getTimescale(for: 29)
        XCTAssertEqual(timescale2997, 30000, "29.97fps should use 30000 timescale for 30000/1001")
    }

    func testFrameRateManagerValidation() throws {
        // Test universal frame rate validation (no more professional restrictions)
        let rational23976 = AVRational(num: 23976, den: 1000)
        XCTAssertTrue(FrameRateManager.isValidFrameRate(rational23976), "23.976fps should be valid frame rate")

        let rational2997 = AVRational(num: 29970, den: 1000)
        XCTAssertTrue(FrameRateManager.isValidFrameRate(rational2997), "29.97fps should be valid frame rate")

        let wildRational = AVRational(num: 27500, den: 1000)  // 27.5fps - now supported!
        XCTAssertTrue(FrameRateManager.isValidFrameRate(wildRational), "27.5fps should be valid frame rate (no more professional restrictions)")

        // Test edge cases
        let tooSlow = AVRational(num: 500, den: 1000)  // 0.5fps
        XCTAssertFalse(FrameRateManager.isValidFrameRate(tooSlow), "0.5fps should be invalid")

        let tooFast = AVRational(num: 1500000, den: 1000)  // 1500fps
        XCTAssertFalse(FrameRateManager.isValidFrameRate(tooFast), "1500fps should be invalid")
    }
}