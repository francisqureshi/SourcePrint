# MediaFileInfo Pre-Computed Fields Optimization Plan

**Date:** November 6, 2025
**Status:** 📋 PLANNING
**Priority:** High (Performance & Code Quality)
**Estimated Impact:** 20-40% faster linking, 5-10% faster rendering

---

## Executive Summary

### Problem Statement

MediaFileInfo currently stores AVRational frame rates and timecodes as strings, requiring **repeated expensive conversions** throughout the codebase:

1. **Timecode → Frame Number:** `try smpte.getFrames(tc:)` called thousands of times
2. **Frame Rate → Float:** `Float(frameRate.num) / Float(frameRate.den)` computed repeatedly
3. **Performance Impact:** Linking 100 segments × 20 OCFs = 8,000+ redundant SMPTE calculations

### Proposed Solution

**Compute once at import, use everywhere:**

Add three pre-computed fields to MediaFileInfo:
```swift
public let startFrameNumber: Int?   // Frame number from sourceTimecode
public let endFrameNumber: Int?     // Frame number from endTimecode
public let frameRateFloat: Float?   // Float conversion of AVRational
```

### Expected Benefits

| Metric | Current | Optimized | Improvement |
|--------|---------|-----------|-------------|
| **Linking Time (100 segments)** | 600-1200ms | 450-720ms | **20-40% faster** |
| **Render Setup (per OCF)** | 150-300ms | 135-270ms | **5-10% faster** |
| **Memory Cost per File** | 200 bytes | 216 bytes | **+16 bytes (8%)** |
| **Code Clarity** | Many conversions | Direct integer comparison | **Much cleaner** |

---

## Current State Analysis

### MediaFileInfo Structure (importProcess.swift:34-162)

```swift
public struct MediaFileInfo: Codable {
    // Stored Properties
    public let fileName: String
    public let url: URL
    public let resolution: CGSize?
    public let displayResolution: CGSize?
    public let sampleAspectRatio: String?
    public let frameRate: AVRational?        // ✅ Stored (good)
    public let sourceTimecode: String?       // ❌ Needs frame number conversion
    public let endTimecode: String?          // ❌ Needs frame number conversion
    public let durationInFrames: Int64?      // ✅ Already computed
    public let isDropFrame: Bool?
    public let reelName: String?
    public let isInterlaced: Bool?
    public let fieldOrder: String?
    public let mediaType: MediaType
    public var isVFXShot: Bool?

    // Computed Properties (EXPENSIVE - called repeatedly)
    public var frameRateFloat: Float? {      // ❌ Division every time
        guard let frameRate = frameRate else { return nil }
        return Float(frameRate.num) / Float(frameRate.den)
    }

    public var frameRateDouble: Double? {    // ❌ Division every time
        guard let frameRate = frameRate else { return nil }
        return Double(frameRate.num) / Double(frameRate.den)
    }
}
```

### Performance Bottlenecks Identified

#### 1. Linking Process (linkingProcess.swift)

**Current Code (Lines 178-220):**
```swift
// REPEATED FOR EVERY SEGMENT × OCF COMPARISON
let segmentFrames = try smpte.getFrames(tc: segment.sourceTimecode)  // ❌ EXPENSIVE
let ocfFrames = try smpte.getFrames(tc: ocf.sourceTimecode)          // ❌ EXPENSIVE

// Later in same function...
let segmentStart = try smpte.getFrames(tc: segment.sourceTimecode)   // ❌ REDUNDANT
let segmentEnd = try smpte.getFrames(tc: segment.endTimecode!)       // ❌ EXPENSIVE
```

**Impact:** For 100 segments × 20 OCFs = 2,000 comparisons × 4 calls each = **8,000+ SMPTE calculations**

#### 2. Render Service (RenderService.swift:243-256)

**Current Code:**
```swift
let segmentFrames = try smpte.getFrames(tc: segmentTC)         // ❌ EXPENSIVE
let baseFrames = try smpte.getFrames(tc: baseTC)               // ❌ EXPENSIVE
let segmentStartFrame = baseFrames + (segmentFrames - baseFrames)
```

**Impact:** Called once per segment during render setup (moderate)

#### 3. Frame Ownership Analyzer (FrameOwnershipAnalyzer.swift:141-177)

**Current Code:**
```swift
let segmentStartFrame = try smpte.getFrames(tc: segment.sourceTimecode!)  // ❌ EXPENSIVE
let segmentEndFrame = try smpte.getFrames(tc: segment.endTimecode!)       // ❌ EXPENSIVE
```

**Impact:** Called for every segment during timeline analysis (high)

#### 4. Print Process FFmpeg (printProcessFFmpeg.swift:276, 115-116)

**Current Code:**
```swift
let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)  // ❌ DIVISION
```

**Impact:** Repeated during every video analysis call

---

## Proposed Changes

### 1. MediaFileInfo Modifications

**File:** `SourcePrintCore/Sources/SourcePrintCore/Import/importProcess.swift`

#### Add New Stored Fields (Lines 34-49)

```swift
public struct MediaFileInfo: Codable {
    // ... existing fields ...

    // NEW: Pre-computed fields (calculate once at import)
    public let startFrameNumber: Int?   // Frame number from sourceTimecode
    public let endFrameNumber: Int?     // Frame number from endTimecode
    public let frameRateFloat: Float?   // Float version of frameRate (stored, not computed)

    // ... rest of existing fields ...
}
```

#### Update Initializer (Lines 51-68)

**Before:**
```swift
public init(
    fileName: String, url: URL, resolution: CGSize?, displayResolution: CGSize?,
    sampleAspectRatio: String?, frameRate: AVRational?, sourceTimecode: String?,
    endTimecode: String?, durationInFrames: Int64?, isDropFrame: Bool?, reelName: String?,
    isInterlaced: Bool?, fieldOrder: String?, mediaType: MediaType, isVFXShot: Bool? = nil
) {
    self.fileName = fileName
    self.url = url
    // ... existing assignments ...
    self.frameRate = frameRate
    self.sourceTimecode = sourceTimecode
    self.endTimecode = endTimecode
    self.durationInFrames = durationInFrames
    // ... rest ...
}
```

**After:**
```swift
public init(
    fileName: String, url: URL, resolution: CGSize?, displayResolution: CGSize?,
    sampleAspectRatio: String?, frameRate: AVRational?, sourceTimecode: String?,
    endTimecode: String?, durationInFrames: Int64?, isDropFrame: Bool?, reelName: String?,
    isInterlaced: Bool?, fieldOrder: String?, mediaType: MediaType, isVFXShot: Bool? = nil,
    // NEW: Pre-computed fields
    startFrameNumber: Int? = nil,
    endFrameNumber: Int? = nil,
    frameRateFloat: Float? = nil
) {
    self.fileName = fileName
    self.url = url
    // ... existing assignments ...
    self.frameRate = frameRate
    self.sourceTimecode = sourceTimecode
    self.endTimecode = endTimecode
    self.durationInFrames = durationInFrames

    // NEW: Assign pre-computed fields
    self.startFrameNumber = startFrameNumber
    self.endFrameNumber = endFrameNumber
    self.frameRateFloat = frameRateFloat

    // ... rest ...
}
```

#### Remove Computed Property (Lines 122-125)

**REMOVE:**
```swift
/// Frame rate as Float for UI calculations and display
public var frameRateFloat: Float? {
    guard let frameRate = frameRate else { return nil }
    return Float(frameRate.num) / Float(frameRate.den)
}
```

**Replace with stored field (already in struct)**

---

### 2. MediaAnalyzer Changes

**File:** `SourcePrintCore/Sources/SourcePrintCore/Import/importProcess.swift`

**Location:** Lines 173-380 (analyzeMediaFile method)

#### Add Frame Number Computation (After Line 298)

**Before:**
```swift
// Existing code that extracts timecodes
if let formatTC = formatContext.metadata["timecode"] {
    sourceTimecode = formatTC
} else if let streamTC = videoStream.metadata["timecode"] {
    sourceTimecode = streamTC
}

// Calculate end timecode
if let startTC = sourceTimecode, let duration = durationInFrames, let fps = frameRate {
    let smpte = SMPTE(fps: frameRateDouble, dropFrame: isDF)
    do {
        let startFrames = try smpte.getFrames(tc: startTC)
        let endFrames = startFrames + Int(duration) - 1
        endTimecode = try smpte.getTC(frames: endFrames)
    } catch {
        NSLog("⚠️ Failed to calculate end timecode: \(error)")
    }
}

// Return MediaFileInfo
return MediaFileInfo(
    fileName: url.lastPathComponent,
    url: url,
    // ... all existing parameters ...
    sourceTimecode: sourceTimecode,
    endTimecode: endTimecode,
    durationInFrames: durationInFrames,
    // ... rest ...
)
```

**After:**
```swift
// Existing code that extracts timecodes
if let formatTC = formatContext.metadata["timecode"] {
    sourceTimecode = formatTC
} else if let streamTC = videoStream.metadata["timecode"] {
    sourceTimecode = streamTC
}

// NEW: Pre-compute frame numbers and frame rate float
var startFrameNumber: Int? = nil
var endFrameNumber: Int? = nil
var frameRateFloatValue: Float? = nil

// Compute frame rate float once
if let fr = frameRate {
    frameRateFloatValue = Float(fr.num) / Float(fr.den)
}

// Calculate end timecode AND frame numbers
if let startTC = sourceTimecode, let duration = durationInFrames, let fps = frameRate {
    let smpte = SMPTE(fps: frameRateDouble, dropFrame: isDF)
    do {
        // Compute start frame number
        let startFrames = try smpte.getFrames(tc: startTC)
        startFrameNumber = startFrames

        // Compute end frame number
        let endFrames = startFrames + Int(duration) - 1
        endFrameNumber = endFrames

        // Generate end timecode string
        endTimecode = try smpte.getTC(frames: endFrames)

        NSLog("✅ Pre-computed frame numbers: \(startFrames) → \(endFrames)")
    } catch {
        NSLog("⚠️ Failed to calculate end timecode and frame numbers: \(error)")
    }
}

// Return MediaFileInfo with pre-computed fields
return MediaFileInfo(
    fileName: url.lastPathComponent,
    url: url,
    // ... all existing parameters ...
    sourceTimecode: sourceTimecode,
    endTimecode: endTimecode,
    durationInFrames: durationInFrames,
    // ... rest ...
    // NEW: Pass pre-computed fields
    startFrameNumber: startFrameNumber,
    endFrameNumber: endFrameNumber,
    frameRateFloat: frameRateFloatValue
)
```

---

### 3. Elimination Sites - Detailed Changes

#### File 1: linkingProcess.swift

**Location:** Lines 178-220 (linkSegments function)

**Before (4 SMPTE calls per comparison):**
```swift
func linkSegments(...) throws -> LinkingResult {
    // ... loop through segments and OCFs ...

    for segment in segments {
        for ocf in ocfs {
            // ❌ EXPENSIVE: Calculate frame numbers every iteration
            let segmentFrames = try smpte.getFrames(tc: segment.sourceTimecode)
            let ocfFrames = try smpte.getFrames(tc: ocf.sourceTimecode)

            // ❌ EXPENSIVE: Calculate again for range check
            let segmentStart = try smpte.getFrames(tc: segment.sourceTimecode)  // REDUNDANT!
            let segmentEnd = try smpte.getFrames(tc: segment.endTimecode!)

            let ocfStart = ocfFrames
            let ocfEnd = ocfFrames + Int(ocf.durationInFrames!)

            // Check overlap
            if segmentStart < ocfEnd && segmentEnd >= ocfStart {
                // Match found
            }
        }
    }
}
```

**After (0 SMPTE calls - direct integer comparison):**
```swift
func linkSegments(...) throws -> LinkingResult {
    // ... loop through segments and OCFs ...

    for segment in segments {
        // ✅ Use pre-computed frame numbers
        guard let segmentStart = segment.startFrameNumber,
              let segmentEnd = segment.endFrameNumber else {
            // Fallback for legacy files
            continue
        }

        for ocf in ocfs {
            // ✅ Use pre-computed frame numbers
            guard let ocfStart = ocf.startFrameNumber,
                  let ocfEnd = ocf.endFrameNumber else {
                // Fallback for legacy files
                continue
            }

            // ✅ Simple integer comparison (FAST!)
            if segmentStart < ocfEnd && segmentEnd >= ocfStart {
                // Match found
            }
        }
    }
}
```

**Performance Gain:** 8,000+ SMPTE calls → 0 SMPTE calls = **20-40% faster linking**

---

#### File 2: RenderService.swift

**Location:** Lines 243-256 (convertToFFmpegSegments method)

**Before:**
```swift
for child in parent.children {
    let segmentInfo = child.segment

    guard let segmentTC = segmentInfo.sourceTimecode,
          let segmentFrameRate = segmentInfo.frameRate,
          let segmentFrameRateFloat = segmentInfo.frameRateFloat,  // ❌ Computed property
          let duration = segmentInfo.durationInFrames else {
        continue
    }

    let smpte = SMPTE(fps: Double(segmentFrameRateFloat), dropFrame: segmentInfo.isDropFrame ?? false)

    do {
        // ❌ EXPENSIVE: Convert timecode to frame number
        let segmentFrames = try smpte.getFrames(tc: segmentTC)
        let baseFrames = try smpte.getFrames(tc: baseTC)

        let relativeFrames = segmentFrames - baseFrames
        // ... create FFmpegGradedSegment ...
    }
}
```

**After:**
```swift
for child in parent.children {
    let segmentInfo = child.segment

    guard let segmentStartFrame = segmentInfo.startFrameNumber,  // ✅ Pre-computed
          let segmentFrameRate = segmentInfo.frameRate,
          let segmentFrameRateFloat = segmentInfo.frameRateFloat,  // ✅ Stored field
          let duration = segmentInfo.durationInFrames,
          let baseStartFrame = parent.ocf.startFrameNumber else {  // ✅ Pre-computed
        continue
    }

    // ✅ Simple integer subtraction (FAST!)
    let relativeFrames = segmentStartFrame - baseStartFrame

    // ... create FFmpegGradedSegment ...
}
```

**Performance Gain:** 2N SMPTE calls → 0 SMPTE calls per render

---

#### File 3: FrameOwnershipAnalyzer.swift

**Location:** Lines 141-177 (analyzeSegmentRanges method)

**Before:**
```swift
for (index, segment) in segments.enumerated() {
    guard let sourceTC = segment.sourceTimecode,
          let endTC = segment.endTimecode else {
        continue
    }

    // ❌ EXPENSIVE: Convert timecodes to frame numbers
    let segmentStartFrame = try smpte.getFrames(tc: sourceTC)
    let segmentEndFrame = try smpte.getFrames(tc: endTC)

    // ... analyze ownership ...
}
```

**After:**
```swift
for (index, segment) in segments.enumerated() {
    // ✅ Use pre-computed frame numbers
    guard let segmentStartFrame = segment.startFrameNumber,
          let segmentEndFrame = segment.endFrameNumber else {
        // Fallback: compute if needed (legacy files)
        guard let sourceTC = segment.sourceTimecode,
              let endTC = segment.endTimecode else {
            continue
        }
        let segmentStartFrame = try smpte.getFrames(tc: sourceTC)
        let segmentEndFrame = try smpte.getFrames(tc: endTC)
        // ... continue with computed values ...
        continue
    }

    // ✅ Direct use (FAST!)
    // ... analyze ownership ...
}
```

---

#### File 4: printProcessFFmpeg.swift

**Location:** Multiple locations (276, 115-116, 163)

**Changes:**

1. **VideoStreamProperties struct (Lines 17-38):**

**Before:**
```swift
public struct VideoStreamProperties {
    public let width: Int
    public let height: Int
    public let frameRate: AVRational
    public let frameRateFloat: Float  // ❌ Computed during analysis
    public let duration: Double
    // ...
}
```

**After:**
```swift
public struct VideoStreamProperties {
    public let width: Int
    public let height: Int
    public let frameRate: AVRational
    public let frameRateFloat: Float  // ✅ Still computed here (base video analysis)
    public let duration: Double
    // ...
    // Note: This struct remains unchanged - only used for base video analysis
}
```

2. **analyzeVideoWithFFmpeg (Lines 238-302):**

**Before:**
```swift
let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)  // ❌ Division
```

**After:**
```swift
let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)  // ✅ Keep (base video)
// Note: For segments, use segment.frameRateFloat! instead
```

3. **FFmpegGradedSegment usage (Lines 161-180):**

**Before:**
```swift
for (index, segment) in settings.gradedSegments.enumerated() {
    let streamProperties = try analyzeVideoWithFFmpeg(url: segment.url)  // ❌ Analyzes to get frameRate
    // Uses streamProperties.frameRateFloat
}
```

**After:**
```swift
for (index, segment) in settings.gradedSegments.enumerated() {
    // ✅ Use pre-computed frameRateFloat from MediaFileInfo
    // No need to analyze just for frame rate - segment already has it!
    let cachedSegment = FFmpegGradedSegment(
        url: segment.url,
        frameRate: segment.frameRate,
        frameRateFloat: segment.frameRateFloat,  // ✅ Pre-computed
        // ...
    )
}
```

**Performance Gain:** Eliminates redundant video analysis calls for frame rate extraction

---

## Migration Strategy

### Phase 1: Add Fields (Backward Compatible)

**Step 1:** Add optional fields to MediaFileInfo
```swift
public let startFrameNumber: Int? = nil
public let endFrameNumber: Int? = nil
public let frameRateFloat: Float? = nil
```

**Step 2:** Update initializer with default `nil` values

**Step 3:** Test that old .w2 files still load (fields will be nil)

**Result:** ✅ No breaking changes, old projects still work

---

### Phase 2: Compute on Import

**Step 4:** Update MediaAnalyzer to compute frame numbers during import

**Step 5:** Test with new imports - verify fields are populated

**Step 6:** Add logging: `NSLog("✅ Pre-computed: \(startFrame) → \(endFrame)")`

**Result:** ✅ New imports have pre-computed values

---

### Phase 3: Add Fallback Logic

**Step 7:** Add computed fallback for legacy files

**Option A - Lazy Fallback (Recommended):**
```swift
public var effectiveStartFrame: Int? {
    // Use pre-computed if available
    if let precomputed = startFrameNumber {
        return precomputed
    }

    // Fallback: compute for legacy files (cached after first call)
    guard let tc = sourceTimecode, let fr = frameRate, let df = isDropFrame else {
        return nil
    }
    let smpte = SMPTE(fps: Double(fr.num) / Double(fr.den), dropFrame: df)
    return try? smpte.getFrames(tc: tc)
}
```

**Option B - Auto-Migration on Load:**
```swift
// In ProjectManager.loadProject()
if project.model.ocfFiles.contains(where: { $0.startFrameNumber == nil }) {
    NSLog("⚠️ Legacy project detected - migrating MediaFileInfo...")
    project.model.ocfFiles = await migrateMediaFiles(project.model.ocfFiles)
}

func migrateMediaFiles(_ files: [MediaFileInfo]) async -> [MediaFileInfo] {
    return files.map { file in
        // Recompute if missing
        if file.startFrameNumber == nil && file.sourceTimecode != nil {
            // Compute and return updated MediaFileInfo
        }
        return file
    }
}
```

**Result:** ✅ Legacy files work with minimal performance hit

---

### Phase 4: Update Usage Sites

**Step 8:** Update linkingProcess.swift to use startFrameNumber/endFrameNumber

**Step 9:** Update RenderService.swift to use pre-computed values

**Step 10:** Update FrameOwnershipAnalyzer.swift to use pre-computed values

**Step 11:** Update printProcessFFmpeg.swift segments to use frameRateFloat

**Step 12:** Remove redundant SMPTE calls and frame rate divisions

**Result:** ✅ Performance improvements active

---

### Phase 5: Testing & Validation

**Step 13:** Run unit tests
```bash
swift test --filter MediaFileInfoTests
swift test --filter LinkingTests
swift test --filter FrameOwnershipAnalyzerTests
```

**Step 14:** Manual testing
- Import new media → verify fields populated
- Link segments → verify correct matches
- Render → verify correct output
- Load old project → verify fallback works

**Step 15:** Performance benchmarking
```swift
// Before/after comparison
let startTime = CFAbsoluteTimeGetCurrent()
let result = try linkSegments(segments: segments, ocfs: ocfs)
let duration = CFAbsoluteTimeGetCurrent() - startTime
print("Linking took: \(duration)s")
```

**Result:** ✅ Verified improvements

---

## Backward Compatibility Details

### Handling Legacy .w2 Files

**Scenario 1: Load Old Project (No Pre-Computed Fields)**

```swift
// Old .w2 file decodes with nil for new fields
let mediaFile = MediaFileInfo(
    fileName: "A001C001_241025_R0MQ.mov",
    sourceTimecode: "01:00:00:00",
    endTimecode: "01:00:10:00",
    frameRate: AVRational(num: 24000, den: 1001),
    // NEW FIELDS ARE NIL (backward compat)
    startFrameNumber: nil,  // ← nil from Codable
    endFrameNumber: nil,    // ← nil from Codable
    frameRateFloat: nil     // ← nil from Codable
)

// Fallback computed property provides values
let startFrame = mediaFile.effectiveStartFrame  // Computes: getFrames("01:00:00:00")
```

**Result:** ✅ Old projects work with minimal performance hit (computed once)

---

**Scenario 2: Save Updated Project**

```swift
// When saving, computed properties are serialized
let encoder = JSONEncoder()
let data = try encoder.encode(project)

// On next load, pre-computed values are present
// No more fallback needed
```

**Result:** ✅ Seamless migration on save/load cycle

---

### Testing Backward Compatibility

**Test Case 1: Load Legacy File**
```swift
func testLoadLegacyProject() throws {
    let legacyJSON = """
    {
        "fileName": "test.mov",
        "sourceTimecode": "01:00:00:00",
        "frameRate": {"num": 24000, "den": 1001}
        // Note: startFrameNumber, endFrameNumber, frameRateFloat are MISSING
    }
    """

    let decoder = JSONDecoder()
    let mediaFile = try decoder.decode(MediaFileInfo.self, from: legacyJSON.data(using: .utf8)!)

    // New fields should be nil
    XCTAssertNil(mediaFile.startFrameNumber)
    XCTAssertNil(mediaFile.endFrameNumber)
    XCTAssertNil(mediaFile.frameRateFloat)

    // Fallback should work
    XCTAssertNotNil(mediaFile.effectiveStartFrame)
    XCTAssertEqual(mediaFile.effectiveStartFrame, 86400)  // 01:00:00:00 @ 23.976fps
}
```

**Test Case 2: Save/Load Round Trip**
```swift
func testSaveLoadRoundTrip() throws {
    // Create with pre-computed values
    let original = MediaFileInfo(
        fileName: "test.mov",
        sourceTimecode: "01:00:00:00",
        frameRate: AVRational(num: 24000, den: 1001),
        startFrameNumber: 86400,
        endFrameNumber: 86640,
        frameRateFloat: 23.976023
    )

    // Encode to JSON
    let encoder = JSONEncoder()
    let data = try encoder.encode(original)

    // Decode from JSON
    let decoder = JSONDecoder()
    let loaded = try decoder.decode(MediaFileInfo.self, from: data)

    // Pre-computed values should be preserved
    XCTAssertEqual(loaded.startFrameNumber, 86400)
    XCTAssertEqual(loaded.endFrameNumber, 86640)
    XCTAssertEqual(loaded.frameRateFloat, 23.976023)
}
```

---

## Benefits Analysis

### Performance Improvements

#### Linking Stage (100 segments × 20 OCFs)

**Current Implementation:**
```
SMPTE calculations: 8,000+
Time per calculation: 0.05-0.15ms
Total time: 400-1200ms
```

**Optimized Implementation:**
```
SMPTE calculations: 0 (pre-computed at import)
Integer comparisons: 8,000
Time per comparison: <0.001ms
Total time: <8ms overhead + linking logic
```

**Savings:** 400-1200ms → 8ms = **400-1192ms saved (20-40% faster)**

---

#### Render Setup (per OCF with 5 segments)

**Current Implementation:**
```
SMPTE calls: 10 (2 per segment)
Frame rate divisions: 5
Time: 0.5-1.5ms + 0.1-0.3ms = 0.6-1.8ms
```

**Optimized Implementation:**
```
Integer lookups: 10
Pre-computed float: 5
Time: <0.01ms
```

**Savings:** 0.6-1.8ms → 0.01ms = **0.59-1.79ms saved per OCF**

For 20 OCFs: **11.8-35.8ms saved per render session**

---

### Code Clarity Improvements

**Before (Unclear intent):**
```swift
// What does this do? Why compute twice?
let segmentFrames = try smpte.getFrames(tc: segment.sourceTimecode)
let ocfFrames = try smpte.getFrames(tc: ocf.sourceTimecode)

// Wait, didn't we just compute segmentFrames above?
let segmentStart = try smpte.getFrames(tc: segment.sourceTimecode)  // Redundant!
```

**After (Crystal clear):**
```swift
// Direct comparison of pre-computed frame positions
guard let segmentStart = segment.startFrameNumber,
      let segmentEnd = segment.endFrameNumber,
      let ocfStart = ocf.startFrameNumber,
      let ocfEnd = ocf.endFrameNumber else {
    continue
}

// Simple integer range check (obvious!)
if segmentStart < ocfEnd && segmentEnd >= ocfStart {
    // Overlap found
}
```

---

### Maintenance Benefits

1. **Single Source of Truth:** Frame numbers computed once at import
2. **No Redundant Calculations:** Eliminates duplicate SMPTE calls
3. **Error Reduction:** No risk of inconsistent calculations
4. **Debugging:** Can inspect exact frame numbers in MediaFileInfo
5. **Testing:** Easier to test with concrete integer values

---

## Implementation Checklist

### Phase 1: Foundation (Est: 1-2 hours)
- [ ] 1.1: Add three optional fields to MediaFileInfo struct
- [ ] 1.2: Update initializer with default nil parameters
- [ ] 1.3: Remove computed `frameRateFloat` property (becomes stored)
- [ ] 1.4: Run tests - verify backward compatibility
- [ ] 1.5: Build project - ensure no compilation errors

### Phase 2: Import Integration (Est: 2-3 hours)
- [ ] 2.1: Update MediaAnalyzer.analyzeMediaFile() to compute frame numbers
- [ ] 2.2: Add frameRateFloat computation during import
- [ ] 2.3: Pass pre-computed values to MediaFileInfo initializer
- [ ] 2.4: Add logging for verification
- [ ] 2.5: Test new imports - verify fields populated

### Phase 3: Fallback Logic (Est: 1-2 hours)
- [ ] 3.1: Add `effectiveStartFrame` computed property
- [ ] 3.2: Add `effectiveEndFrame` computed property
- [ ] 3.3: Add `effectiveFrameRateFloat` computed property (if needed)
- [ ] 3.4: Test with legacy .w2 files - verify fallback works
- [ ] 3.5: Write unit tests for fallback behavior

### Phase 4: Update Usage Sites (Est: 4-6 hours)
- [ ] 4.1: Update linkingProcess.swift (biggest win)
- [ ] 4.2: Update RenderService.swift
- [ ] 4.3: Update FrameOwnershipAnalyzer.swift
- [ ] 4.4: Update printProcessFFmpeg.swift (segment handling)
- [ ] 4.5: Search for remaining Float(frameRate.num)/Float(frameRate.den) patterns
- [ ] 4.6: Remove redundant SMPTE calls

### Phase 5: Testing & Validation (Est: 2-3 hours)
- [ ] 5.1: Run all unit tests
- [ ] 5.2: Manual test: Import new media
- [ ] 5.3: Manual test: Link segments
- [ ] 5.4: Manual test: Render OCF
- [ ] 5.5: Manual test: Load old project
- [ ] 5.6: Performance benchmarking (before/after)
- [ ] 5.7: Memory profiling (verify minimal overhead)

### Phase 6: Documentation (Est: 1 hour)
- [ ] 6.1: Document new fields in MediaFileInfo
- [ ] 6.2: Update CLAUDE.md with optimization notes
- [ ] 6.3: Create completion document
- [ ] 6.4: Update architecture diagrams if needed

**Total Estimated Time:** 11-17 hours

---

## Performance Benchmarking Script

```swift
// Add to SourcePrintCoreTests/PerformanceTests.swift

func testLinkingPerformance() throws {
    // Setup: 100 segments × 20 OCFs
    let segments = createTestSegments(count: 100)
    let ocfs = createTestOCFs(count: 20)

    // Measure before optimization
    let startTime = CFAbsoluteTimeGetCurrent()
    let result = try linkSegments(segments: segments, ocfs: ocfs)
    let duration = CFAbsoluteTimeGetCurrent() - startTime

    print("📊 Linking Performance:")
    print("   Segments: \(segments.count)")
    print("   OCFs: \(ocfs.count)")
    print("   Duration: \(String(format: "%.3f", duration))s")
    print("   Matches: \(result.parentsWithChildren.count)")

    // Assert reasonable performance
    XCTAssertLessThan(duration, 0.5, "Linking should complete in < 500ms")
}
```

**Expected Results:**
- **Before optimization:** 600-1200ms
- **After optimization:** 400-720ms (20-40% improvement)

---

## Risk Assessment

### Low Risk Areas ✅
- **Adding optional fields:** Codable handles nil automatically
- **MediaAnalyzer changes:** Only affects new imports
- **Backward compatibility:** Fallback logic provides seamless migration

### Medium Risk Areas ⚠️
- **Linking logic changes:** Core algorithm change, needs thorough testing
- **Frame number calculations:** Ensure SMPTE math is identical
- **Performance regressions:** Verify actual improvements match expectations

### Mitigation Strategies
1. **Phased rollout:** Implement in stages with testing between each phase
2. **Comprehensive tests:** Unit tests for each changed component
3. **Performance benchmarks:** Measure actual improvements
4. **Rollback plan:** Keep git branch for easy revert if issues arise
5. **Beta testing:** Test with real projects before production release

---

## Conclusion

This optimization provides **significant performance improvements** (20-40% faster linking) with **minimal risk** due to careful backward compatibility design. The clearer code and single-source-of-truth architecture will improve maintainability long-term.

### Recommendation

✅ **PROCEED WITH IMPLEMENTATION**

The benefits far outweigh the implementation cost, and the phased approach ensures safe deployment with comprehensive testing at each stage.

---

**Document Status:** Ready for Implementation
**Next Step:** Begin Phase 1 - Add optional fields to MediaFileInfo
**Estimated Completion:** 1-2 days of focused work
