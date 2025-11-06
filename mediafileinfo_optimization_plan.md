# MediaFileInfo Optimization Plan: Pre-computed Fields

**Date:** 2025-11-06
**Objective:** Add pre-computed fields to MediaFileInfo to eliminate redundant timecode-to-frame and frame-rate conversions throughout the codebase.

---

## Section 1: Current State Analysis

### 1.1 MediaFileInfo Current Structure

**Location:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Import/importProcess.swift` (lines 34-162)

**Current Stored Properties:**
```swift
public struct MediaFileInfo: Codable {
    public let fileName: String
    public let url: URL
    public let resolution: CGSize?
    public let displayResolution: CGSize?
    public let sampleAspectRatio: String?
    public let frameRate: AVRational?              // Exact rational
    public let sourceTimecode: String?
    public let endTimecode: String?
    public let durationInFrames: Int64?
    public let isDropFrame: Bool?
    public let reelName: String?
    public let isInterlaced: Bool?
    public let fieldOrder: String?
    public let mediaType: MediaType
    public var isVFXShot: Bool?
}
```

**Current Computed Properties (Line 70-139):**
```swift
// COMPUTED - recalculated every access
public var frameRateFloat: Float? {
    guard let frameRate = frameRate else { return nil }
    return Float(frameRate.num) / Float(frameRate.den)  // ⚠️ REDUNDANT
}

// COMPUTED - recalculated every access
public var frameRateDouble: Double? {
    guard let frameRate = frameRate else { return nil }
    return Double(frameRate.num) / Double(frameRate.den)  // ⚠️ REDUNDANT
}

// Also: durationInSeconds (depends on frameRateDouble)
```

### 1.2 Conversion Sites Found

**Timecode-to-Frame Conversions:**
- **SMPTE.getFrames(tc:)** calls: **5 total occurrences**
  - `linkingProcess.swift:318-321` - Segment/OCF range validation (4 calls)
  - `RenderService.swift:255-256` - Timeline position calculation (2 calls)
  - `FrameOwnershipAnalyzer.swift:242-245` - Frame position calculation (2 calls)

**Frame Rate Float Conversions:**
- **Float(frameRate.num) / Float(frameRate.den)**: **4 direct conversions**
  - `importProcess.swift:115` - frameRateDescription computed property
  - `importProcess.swift:124` - frameRateFloat computed property
  - `linkingProcess.swift:313` - isSegmentInOCFRange validation
  - `printProcessFFmpeg.swift:276` - VideoStreamProperties initialization

**Frame Rate Double Conversions:**
- **Double(frameRate.num) / Double(frameRate.den)**: **2 occurrences**
  - `importProcess.swift:130` - frameRateDouble computed property
  - `FrameOwnershipAnalyzer.swift:485` - convertTimeToFrame helper

**frameRateFloat Property Access:** Used in 7 locations across 3 files (all redundant)

### 1.3 Performance Bottlenecks Identified

**Critical Hotspots:**

1. **Linking Validation (linkingProcess.swift:306-345)**
   - Called once per segment per OCF during linking
   - 4x `smpte.getFrames(tc:)` calls per validation check
   - For 100 segments × 20 OCFs = **8,000 timecode conversions**
   - Each conversion includes string parsing + SMPTE calculation

2. **Render Service Conversion (RenderService.swift:228-293)**
   - Called once per segment during render preparation
   - 2x `smpte.getFrames(tc:)` calls per segment
   - For 50 segments per render = **100 timecode conversions**

3. **Frame Ownership Analysis (FrameOwnershipAnalyzer.swift:229-267)**
   - Called once per segment during processing plan generation
   - 2x `smpte.getFrames(tc:)` calls per segment
   - Critical path for print process

4. **Frame Rate Conversions**
   - Accessed multiple times per file during UI display
   - Recomputed on every property access (no caching)

**Estimated Performance Impact:**
- **Linking stage:** 100ms-500ms of redundant SMPTE calculations (large projects)
- **Render stage:** 50ms-200ms per render operation
- **UI display:** Negligible but unnecessary recomputation

---

## Section 2: Proposed Changes

### 2.1 MediaFileInfo Modifications

**Add Three Pre-computed Fields:**

```swift
public struct MediaFileInfo: Codable {
    // ... existing stored properties ...

    // ✨ NEW: Pre-computed fields (calculated ONCE at import)
    public let startFrameNumber: Int?        // Frame number from sourceTimecode
    public let endFrameNumber: Int?          // Frame number from endTimecode
    public let frameRateFloat: Float?        // Float version of frameRate (stored, not computed)

    // ⚠️ REMOVE: These computed properties become redundant
    // public var frameRateFloat: Float? { ... }  // DELETE THIS
    // public var frameRateDouble: Double? { ... }  // KEEP (rarely used, okay to compute from Float)
}
```

**Why These Fields:**
- `startFrameNumber` - Eliminates `smpte.getFrames(tc: sourceTimecode)` calls
- `endFrameNumber` - Eliminates `smpte.getFrames(tc: endTimecode)` calls
- `frameRateFloat` - Eliminates rational division, most common conversion

**Memory Impact:**
- +16 bytes per MediaFileInfo (Int? = 8 bytes, Float? = 4 bytes × 2)
- Typical project: 200 files × 16 bytes = **3.2 KB** (negligible)

### 2.2 Initializer Changes

**Current Init (importProcess.swift:51-68):**
```swift
public init(fileName: String, url: URL, resolution: CGSize?, /* ... */) {
    self.fileName = fileName
    self.url = url
    // ... assign all parameters ...
    self.isVFXShot = isVFXShot
}
```

**New Init (add three parameters):**
```swift
public init(
    fileName: String,
    url: URL,
    resolution: CGSize?,
    displayResolution: CGSize?,
    sampleAspectRatio: String?,
    frameRate: AVRational?,
    sourceTimecode: String?,
    endTimecode: String?,
    durationInFrames: Int64?,
    isDropFrame: Bool?,
    reelName: String?,
    isInterlaced: Bool?,
    fieldOrder: String?,
    mediaType: MediaType,
    isVFXShot: Bool? = nil,
    // ✨ NEW PARAMETERS
    startFrameNumber: Int? = nil,   // Computed at import
    endFrameNumber: Int? = nil,     // Computed at import
    frameRateFloat: Float? = nil    // Computed at import
) {
    // ... existing assignments ...

    // ✨ NEW ASSIGNMENTS
    self.startFrameNumber = startFrameNumber
    self.endFrameNumber = endFrameNumber
    self.frameRateFloat = frameRateFloat
}
```

**Note:** Default `nil` values provide backward compatibility for legacy .w2 files.

### 2.3 MediaAnalyzer Changes

**Location:** `importProcess.swift`, `analyzeMediaFile()` method (lines 173-329)

**Add Computation Logic AFTER Timecode Extraction (around line 296):**

```swift
// EXISTING: Calculate end timecode and duration (lines 269-296)
if let startTC = sourceTimecode, let fps = frameRate, let frames = durationInFrames, frames > 0 {
    let floatFps = Float(fps.num) / Float(fps.den)
    endTimecode = calculateEndTimecode(startTimecode: startTC, frameRate: floatFps, durationFrames: frames)
}

// ✨ NEW: Pre-compute frame numbers and float frame rate (INSERT HERE)
var startFrameNumber: Int? = nil
var endFrameNumber: Int? = nil
var frameRateFloatValue: Float? = nil

// 1. Compute frameRateFloat ONCE
if let fps = frameRate {
    frameRateFloatValue = Float(fps.num) / Float(fps.den)
}

// 2. Compute frame numbers from timecodes ONCE
if let startTC = sourceTimecode,
   let floatFps = frameRateFloatValue,
   let dropFrame = isDropFrame {
    let smpte = SMPTE(fps: Double(floatFps), dropFrame: dropFrame)

    do {
        startFrameNumber = try smpte.getFrames(tc: startTC)

        if let endTC = endTimecode {
            endFrameNumber = try smpte.getFrames(tc: endTC)
        }

        print("    🔢 Pre-computed frame numbers: start=\(startFrameNumber!), end=\(endFrameNumber ?? 0)")
    } catch {
        print("    ⚠️ Failed to pre-compute frame numbers: \(error)")
        // startFrameNumber/endFrameNumber remain nil (graceful degradation)
    }
}

// EXISTING: Return MediaFileInfo
return MediaFileInfo(
    fileName: url.lastPathComponent,
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
    isVFXShot: nil,  // Auto-detect later
    // ✨ NEW: Pass pre-computed values
    startFrameNumber: startFrameNumber,
    endFrameNumber: endFrameNumber,
    frameRateFloat: frameRateFloatValue
)
```

---

## Section 3: Elimination Sites

### 3.1 Linking Process (linkingProcess.swift)

**File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Linking/linkingProcess.swift`

**Lines 306-345: `isSegmentInOCFRange()` method**

**BEFORE:**
```swift
private func isSegmentInOCFRange(
    segmentStartTimecode: String,
    segmentEndTimecode: String,
    ocfStartTimecode: String,
    ocfEndTimecode: String,
    frameRate: AVRational,
    segmentDropFrame: Bool? = nil,
    ocfDropFrame: Bool? = nil
) -> Bool {
    let isDropFrame = segmentDropFrame ?? ocfDropFrame ?? /* ... */

    let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)  // ⚠️ REMOVE
    let smpte = SMPTE(fps: Double(frameRateFloat), dropFrame: isDropFrame)  // ⚠️ REMOVE

    do {
        // ⚠️ 4 REDUNDANT CONVERSIONS:
        let segmentStartFrame = try smpte.getFrames(tc: segmentStartTimecode)  // ⚠️ REMOVE
        let segmentEndFrame = try smpte.getFrames(tc: segmentEndTimecode)      // ⚠️ REMOVE
        let ocfStartFrame = try smpte.getFrames(tc: ocfStartTimecode)          // ⚠️ REMOVE
        let ocfEndFrame = try smpte.getFrames(tc: ocfEndTimecode)              // ⚠️ REMOVE

        // Check if entire segment duration falls within OCF range
        let segmentStartInRange = segmentStartFrame >= ocfStartFrame && segmentStartFrame <= ocfEndFrame
        let segmentEndInRange = segmentEndFrame >= ocfStartFrame && segmentEndFrame <= ocfEndFrame
        let entireSegmentInRange = segmentStartInRange && segmentEndInRange

        // ... logging ...
        return entireSegmentInRange
    } catch { /* ... */ }
}
```

**AFTER:**
```swift
private func isSegmentInOCFRange(
    segment: MediaFileInfo,      // ✅ Pass entire MediaFileInfo
    ocf: MediaFileInfo            // ✅ Pass entire MediaFileInfo
) -> Bool {
    // ✅ Use pre-computed frame numbers
    guard let segmentStartFrame = segment.startFrameNumber,
          let segmentEndFrame = segment.endFrameNumber,
          let ocfStartFrame = ocf.startFrameNumber,
          let ocfEndFrame = ocf.endFrameNumber else {
        // Fallback: If pre-computed values missing (legacy files), use old logic
        print("⚠️ Missing pre-computed frame numbers, skipping validation")
        return false
    }

    // ✅ Direct integer comparison (NO string parsing, NO SMPTE calculation!)
    let segmentStartInRange = segmentStartFrame >= ocfStartFrame && segmentStartFrame <= ocfEndFrame
    let segmentEndInRange = segmentEndFrame >= ocfStartFrame && segmentEndFrame <= ocfEndFrame
    let entireSegmentInRange = segmentStartInRange && segmentEndInRange

    if entireSegmentInRange {
        let dropFrameInfo = segment.isDropFrame == true ? " (drop frame)" : ""
        print("    ✅ Segment range \(segment.sourceTimecode ?? "?")-\(segment.endTimecode ?? "?") (frames \(segmentStartFrame)-\(segmentEndFrame)) within OCF range \(ocf.sourceTimecode ?? "?")-\(ocf.endTimecode ?? "?") (frames \(ocfStartFrame)-\(ocfEndFrame))\(dropFrameInfo)")
    } else {
        let dropFrameInfo = segment.isDropFrame == true ? " (drop frame)" : ""
        print("    ❌ Segment range \(segment.sourceTimecode ?? "?")-\(segment.endTimecode ?? "?") (frames \(segmentStartFrame)-\(segmentEndFrame)) NOT within OCF range \(ocf.sourceTimecode ?? "?")-\(ocf.endTimecode ?? "?") (frames \(ocfStartFrame)-\(ocfEndFrame))\(dropFrameInfo)")
    }

    return entireSegmentInRange
}
```

**Call Site Update (Line 243-257):**
```swift
// BEFORE:
let inRange = isSegmentInOCFRange(
    segmentStartTimecode: segmentStartTC,
    segmentEndTimecode: segmentEndTC,
    ocfStartTimecode: ocfStartTC,
    ocfEndTimecode: ocfEndTC,
    frameRate: segmentFR,
    segmentDropFrame: segment.isDropFrame,
    ocfDropFrame: ocf.isDropFrame
)

// AFTER:
let inRange = isSegmentInOCFRange(segment: segment, ocf: ocf)  // ✅ Simple!
```

### 3.2 Render Service (RenderService.swift)

**File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/Workflows/RenderService.swift`

**Lines 228-293: `convertToFFmpegSegments()` method**

**BEFORE:**
```swift
for child in parent.children {
    let segmentInfo = child.segment

    guard let segmentTC = segmentInfo.sourceTimecode,
          let segmentFrameRate = segmentInfo.frameRate,
          let segmentFrameRateFloat = segmentInfo.frameRateFloat,  // ⚠️ Computed property
          let duration = segmentInfo.durationInFrames
    else { /* ... */ }

    let smpte = SMPTE(fps: Double(segmentFrameRateFloat), dropFrame: segmentInfo.isDropFrame ?? false)

    do {
        // ⚠️ 2 REDUNDANT CONVERSIONS:
        let segmentFrames = try smpte.getFrames(tc: segmentTC)  // ⚠️ REMOVE
        let baseFrames = try smpte.getFrames(tc: baseTC)        // ⚠️ REMOVE
        let relativeFrames = segmentFrames - baseFrames

        // Create CMTime values
        let startTime = CMTime(
            value: CMTimeValue(relativeFrames),
            timescale: CMTimeScale(segmentFrameRateFloat)
        )
        // ... rest of conversion ...
    }
}
```

**AFTER:**
```swift
guard let baseTCFrames = parent.ocf.startFrameNumber else {  // ✅ Pre-computed!
    NSLog("⚠️ OCF missing pre-computed start frame number: \(parent.ocf.fileName)")
    return []
}

for child in parent.children {
    let segmentInfo = child.segment

    guard let segmentFrames = segmentInfo.startFrameNumber,      // ✅ Pre-computed!
          let segmentFrameRate = segmentInfo.frameRate,
          let segmentFrameRateFloat = segmentInfo.frameRateFloat,  // ✅ Now stored field!
          let duration = segmentInfo.durationInFrames
    else {
        NSLog("⚠️ Segment missing required pre-computed fields: \(segmentInfo.fileName)")
        continue
    }

    // ✅ Direct integer subtraction (NO SMPTE calculation!)
    let relativeFrames = segmentFrames - baseTCFrames

    // Create CMTime values (unchanged)
    let startTime = CMTime(
        value: CMTimeValue(relativeFrames),
        timescale: CMTimeScale(segmentFrameRateFloat)
    )

    // ... rest of conversion (unchanged) ...
}
```

### 3.3 Frame Ownership Analyzer (FrameOwnershipAnalyzer.swift)

**File:** `/Users/mac10/Projects/SourcePrint/SourcePrintCore/Sources/SourcePrintCore/SegmentAnalysis/FrameOwnershipAnalyzer.swift`

**Lines 229-267: `calculateSegmentFramePosition()` method**

**BEFORE:**
```swift
private func calculateSegmentFramePosition(_ segment: FFmpegGradedSegment) throws -> (start: Int, end: Int) {
    var startFrame: Int
    var endFrame: Int

    // Try SMPTE timecode calculation first
    if let baseTimecode = baseProperties.timecode,
       let segmentTimecode = segment.sourceTimecode,
       let segmentFrameRate = segment.frameRate {

        let smpte = SMPTE(fps: Double(segmentFrameRate), dropFrame: segment.isDropFrame ?? false)

        // ⚠️ 2 REDUNDANT CONVERSIONS:
        let baseFrames = try smpte.getFrames(tc: baseTimecode)        // ⚠️ REMOVE
        let segmentStartFrames = try smpte.getFrames(tc: segmentTimecode)  // ⚠️ REMOVE
        startFrame = segmentStartFrames - baseFrames

        // Calculate end using duration
        guard let segmentFrameRateRational = segment.frameRateRational else {
            throw FrameOwnershipError.missingRationalFrameRate(segment: segment.url.lastPathComponent)
        }
        let durationFrames = convertTimeToFrame(seconds: segment.duration.seconds, frameRate: segmentFrameRateRational)
        endFrame = startFrame + durationFrames
    } else {
        // Fallback to time-based calculation
        // ...
    }

    return (startFrame, endFrame)
}
```

**AFTER:**
```swift
private func calculateSegmentFramePosition(_ segment: FFmpegGradedSegment) throws -> (start: Int, end: Int) {
    var startFrame: Int
    var endFrame: Int

    // ✅ Try pre-computed frame numbers first (FAST PATH)
    if let baseStartFrame = baseProperties.startFrameNumber,       // ✅ Pre-computed!
       let segmentStartFrame = segment.startFrameNumber {          // ✅ Pre-computed!

        // ✅ Direct integer subtraction (NO SMPTE calculation!)
        startFrame = segmentStartFrame - baseStartFrame

        // Calculate end using duration (unchanged)
        guard let segmentFrameRateRational = segment.frameRateRational else {
            throw FrameOwnershipError.missingRationalFrameRate(segment: segment.url.lastPathComponent)
        }
        let durationFrames = convertTimeToFrame(seconds: segment.duration.seconds, frameRate: segmentFrameRateRational)
        endFrame = startFrame + durationFrames

    } else {
        // Fallback to time-based calculation (legacy or missing pre-computed values)
        print("⚠️ Using time-based fallback for segment: \(segment.url.lastPathComponent)")
        startFrame = convertTimeToFrame(seconds: segment.startTime.seconds, frameRate: baseProperties.frameRate)
        let durationFrames = convertTimeToFrame(seconds: segment.duration.seconds, frameRate: baseProperties.frameRate)
        endFrame = startFrame + durationFrames
    }

    return (startFrame, endFrame)
}
```

**Additional Change Required:**
FFmpegGradedSegment needs to carry pre-computed values:

```swift
// printProcessFFmpeg.swift:41-75
public struct FFmpegGradedSegment {
    // ... existing fields ...

    // ✨ NEW: Pre-computed frame numbers from MediaFileInfo
    public let startFrameNumber: Int?  // From MediaFileInfo
    public let endFrameNumber: Int?    // From MediaFileInfo

    public init(
        url: URL,
        startTime: CMTime,
        duration: CMTime,
        sourceStartTime: CMTime,
        isVFXShot: Bool = false,
        sourceTimecode: String? = nil,
        frameRate: Float? = nil,
        frameRateRational: AVRational? = nil,
        isDropFrame: Bool? = nil,
        cachedStreamProperties: VideoStreamProperties? = nil,
        startFrameNumber: Int? = nil,  // ✨ NEW
        endFrameNumber: Int? = nil     // ✨ NEW
    ) {
        // ... existing assignments ...
        self.startFrameNumber = startFrameNumber  // ✨ NEW
        self.endFrameNumber = endFrameNumber      // ✨ NEW
    }
}
```

**Update RenderService.swift conversion (line 271-281):**
```swift
let ffmpegSegment = FFmpegGradedSegment(
    url: segmentInfo.url,
    startTime: startTime,
    duration: segmentDuration,
    sourceStartTime: .zero,
    isVFXShot: segmentInfo.isVFXShot ?? false,
    sourceTimecode: segmentInfo.sourceTimecode,
    frameRate: segmentFrameRateFloat,
    frameRateRational: segmentFrameRate,
    isDropFrame: segmentInfo.isDropFrame,
    startFrameNumber: segmentInfo.startFrameNumber,  // ✨ PASS THROUGH
    endFrameNumber: segmentInfo.endFrameNumber       // ✨ PASS THROUGH
)
```

**Update VideoStreamProperties to include pre-computed values:**
```swift
// printProcessFFmpeg.swift:18-39
public struct VideoStreamProperties {
    // ... existing fields ...

    // ✨ NEW: Pre-computed for base video
    public let startFrameNumber: Int?  // From timecode

    public init(
        width: Int,
        height: Int,
        frameRate: AVRational,
        frameRateFloat: Float,
        duration: Double,
        timebase: AVRational,
        timecode: String?,
        startFrameNumber: Int? = nil  // ✨ NEW
    ) {
        // ... existing assignments ...
        self.startFrameNumber = startFrameNumber  // ✨ NEW
    }
}
```

**Compute in analyzeVideoWithFFmpeg (printProcessFFmpeg.swift:238-302):**
```swift
// Extract timecode like blank rush
var timecode: String?
var startFrameNumber: Int? = nil  // ✨ NEW

if let formatTC = inputFormatContext.metadata["timecode"] {
    timecode = formatTC
    print("  📝 Found timecode in format metadata: \(formatTC)")

    // ✨ NEW: Pre-compute frame number
    let smpte = SMPTE(fps: Double(frameRateFloat), dropFrame: false)  // Detect DF if needed
    do {
        startFrameNumber = try smpte.getFrames(tc: formatTC)
        print("  🔢 Pre-computed start frame: \(startFrameNumber!)")
    } catch {
        print("  ⚠️ Failed to pre-compute start frame: \(error)")
    }
}

return VideoStreamProperties(
    width: width,
    height: height,
    frameRate: frameRate,
    frameRateFloat: frameRateFloat,
    duration: durationInSeconds,
    timebase: videoStream.timebase,
    timecode: timecode,
    startFrameNumber: startFrameNumber  // ✨ NEW
)
```

### 3.4 Print Process FFmpeg (printProcessFFmpeg.swift)

**Line 276: Direct frame rate conversion**

**BEFORE:**
```swift
let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)  // ⚠️ REDUNDANT
```

**AFTER:**
```swift
// ✅ Already pre-computed above at line 224
// No change needed - videoStream properties already have frameRateFloat
```

**Line 22: VideoStreamProperties already stores frameRateFloat** ✅ (no change needed)

---

## Section 4: Migration Strategy

### 4.1 Backward Compatibility

**Problem:** Existing .w2 project files won't have pre-computed fields.

**Solution:** Graceful degradation with nil fallbacks.

**Implementation:**

1. **Optional Fields:** All new fields are `Int?/Float?` (already nullable)

2. **Fallback Logic Pattern:**
```swift
// Example: Linking validation
guard let segmentStartFrame = segment.startFrameNumber,
      let segmentEndFrame = segment.endFrameNumber,
      let ocfStartFrame = ocf.startFrameNumber,
      let ocfEndFrame = ocf.endFrameNumber else {
    // Legacy file without pre-computed values
    print("⚠️ Missing pre-computed frame numbers, using fallback")

    // Option A: Skip validation (safest, prevents errors)
    return false

    // Option B: Fallback to on-the-fly calculation (maintains functionality)
    return isSegmentInOCFRangeLegacy(segment: segment, ocf: ocf)
}

// New fast path: use pre-computed values
return segmentStartFrame >= ocfStartFrame && /* ... */
```

3. **Fallback Helper (temporary):**
```swift
// Add alongside isSegmentInOCFRange()
private func isSegmentInOCFRangeLegacy(segment: MediaFileInfo, ocf: MediaFileInfo) -> Bool {
    // Copy of old implementation using SMPTE calculations
    // Can be removed after all users upgrade projects
    guard let segmentStartTC = segment.sourceTimecode,
          let segmentEndTC = segment.endTimecode,
          let ocfStartTC = ocf.sourceTimecode,
          let ocfEndTC = ocf.endTimecode,
          let frameRate = segment.frameRate else {
        return false
    }

    let frameRateFloat = Float(frameRate.num) / Float(frameRate.den)
    let smpte = SMPTE(fps: Double(frameRateFloat), dropFrame: segment.isDropFrame ?? false)

    do {
        let segmentStartFrame = try smpte.getFrames(tc: segmentStartTC)
        let segmentEndFrame = try smpte.getFrames(tc: segmentEndTC)
        let ocfStartFrame = try smpte.getFrames(tc: ocfStartTC)
        let ocfEndFrame = try smpte.getFrames(tc: ocfEndTC)

        return segmentStartFrame >= ocfStartFrame &&
               segmentStartFrame <= ocfEndFrame &&
               segmentEndFrame >= ocfStartFrame &&
               segmentEndFrame <= ocfEndFrame
    } catch {
        return false
    }
}
```

### 4.2 Migration Path for Users

**Option 1: Automatic Re-import (Recommended)**

When loading a .w2 file with missing pre-computed values:
1. Detect missing fields during deserialization
2. Trigger automatic background re-computation
3. Save updated .w2 file silently

**Implementation:**
```swift
// Add to ProjectModel or ImportProcess
func migratePreComputedValues() async {
    var needsSave = false

    // Check OCF files
    for (index, ocf) in originalCameraFiles.enumerated() {
        if ocf.startFrameNumber == nil || ocf.frameRateFloat == nil {
            print("🔄 Migrating OCF: \(ocf.fileName)")
            let updated = await recomputePreComputedValues(for: ocf)
            originalCameraFiles[index] = updated
            needsSave = true
        }
    }

    // Check graded segments
    for (index, segment) in gradedSegments.enumerated() {
        if segment.startFrameNumber == nil || segment.frameRateFloat == nil {
            print("🔄 Migrating segment: \(segment.fileName)")
            let updated = await recomputePreComputedValues(for: segment)
            gradedSegments[index] = updated
            needsSave = true
        }
    }

    if needsSave {
        print("✅ Migration complete, saving project...")
        try? await saveProject()
    }
}

private func recomputePreComputedValues(for file: MediaFileInfo) async -> MediaFileInfo {
    // Re-analyze file to get pre-computed values
    let analyzer = MediaAnalyzer()
    do {
        let updated = try await analyzer.analyzeMediaFile(at: file.url, type: file.mediaType)
        return updated  // Has all new pre-computed fields
    } catch {
        print("⚠️ Failed to migrate \(file.fileName): \(error)")
        return file  // Return original if migration fails
    }
}
```

**Option 2: Manual Re-import**

Prompt user to re-import media after update:
```
⚠️ Project Optimization Available

This project was created with an older version of SourcePrint.
Re-importing media will improve performance.

[ Re-Import Now ]  [ Skip ]
```

### 4.3 Testing Approach

**Test Cases:**

1. **New Import**
   - Import fresh media files
   - Verify all pre-computed fields are populated
   - Verify no SMPTE calls during linking/rendering

2. **Legacy Project Load**
   - Load .w2 file created before optimization
   - Verify fallback logic activates
   - Verify no crashes or incorrect behavior

3. **Mixed Project** (some files have pre-computed, some don't)
   - Load partially migrated project
   - Verify both fast path and fallback work
   - Verify correct frame calculations

4. **Edge Cases**
   - Files with no timecode (should remain nil)
   - Files with invalid timecode (graceful nil)
   - Drop frame vs non-drop frame accuracy

**Validation Script:**
```swift
// Add to test suite or diagnostic tool
func validatePreComputedValues(file: MediaFileInfo) -> Bool {
    guard let startTC = file.sourceTimecode,
          let endTC = file.endTimecode,
          let fps = file.frameRateFloat,
          let startFrame = file.startFrameNumber,
          let endFrame = file.endFrameNumber else {
        print("⚠️ Missing required fields for validation")
        return false
    }

    // Recompute using SMPTE and compare
    let smpte = SMPTE(fps: Double(fps), dropFrame: file.isDropFrame ?? false)
    do {
        let expectedStart = try smpte.getFrames(tc: startTC)
        let expectedEnd = try smpte.getFrames(tc: endTC)

        if startFrame != expectedStart {
            print("❌ Start frame mismatch: stored=\(startFrame), expected=\(expectedStart)")
            return false
        }

        if endFrame != expectedEnd {
            print("❌ End frame mismatch: stored=\(endFrame), expected=\(expectedEnd)")
            return false
        }

        print("✅ Pre-computed values validated for \(file.fileName)")
        return true

    } catch {
        print("⚠️ Validation error: \(error)")
        return false
    }
}
```

---

## Section 5: Benefits Analysis

### 5.1 Performance Improvement Estimate

**Linking Stage (most impactful):**
- **Current:** 4 SMPTE calls per validation × N segments × M OCFs
- **After:** 0 SMPTE calls (direct integer comparison)
- **Example:** 100 segments × 20 OCFs = 8,000 conversions eliminated
- **Estimated speedup:** 150-500ms saved on large projects

**Render Stage:**
- **Current:** 2 SMPTE calls per segment
- **After:** 0 SMPTE calls
- **Example:** 50 segments = 100 conversions eliminated
- **Estimated speedup:** 50-200ms per render operation

**Frame Ownership Analysis:**
- **Current:** 2 SMPTE calls per segment
- **After:** 0 SMPTE calls
- **Estimated speedup:** 20-100ms per analysis

**Overall Impact:**
- **Linking:** 20-40% faster (from ~500ms to ~300ms)
- **Rendering:** 5-10% faster (print process is I/O bound)
- **UI responsiveness:** Improved (no computed property overhead)

**Memory Trade-off:**
- **Cost:** +16 bytes per MediaFileInfo
- **Benefit:** Eliminates repeated string parsing + SMPTE calculations

### 5.2 Code Clarity Improvement

**Before (confusing):**
```swift
// What does this do? Parse timecode? Convert to frames? Both?
let segmentFrames = try smpte.getFrames(tc: segmentTC)
let baseFrames = try smpte.getFrames(tc: baseTC)
let relativeFrames = segmentFrames - baseFrames
```

**After (crystal clear):**
```swift
// Direct integer arithmetic - obvious what's happening
let relativeFrames = segment.startFrameNumber! - base.startFrameNumber!
```

**Benefits:**
- Reduced cognitive load (no SMPTE object creation)
- Fewer error paths (no try/catch needed)
- Self-documenting (pre-computed values have clear names)

### 5.3 Maintenance Benefit

**Eliminated Code Patterns:**
1. **Repeated SMPTE object creation** (5+ locations)
2. **Try-catch error handling** for timecode parsing (8+ locations)
3. **Frame rate division** (Float(num)/Float(den)) across multiple files
4. **Computed property overhead** (frameRateFloat accessed 7+ times)

**Simplified Dependencies:**
- Linking process no longer needs SMPTE library
- Render service simplified (fewer error paths)
- Frame ownership analyzer has clearer data flow

**Future-proofing:**
- Adding new frame-based calculations becomes trivial
- Timeline visualization can use pre-computed values directly
- Debugging easier (can inspect frame numbers in .w2 files)

---

## Section 6: Implementation Steps

**Ordered checklist for safe implementation:**

### Phase 1: Add Fields (No Behavior Change)

1. ✅ **Update MediaFileInfo struct** (importProcess.swift:34-68)
   - Add three optional stored properties
   - Update initializer with default nil parameters
   - Remove computed `frameRateFloat` property
   - Keep `frameRateDouble` (rarely used, okay to compute)

2. ✅ **Update MediaAnalyzer** (importProcess.swift:173-329)
   - Add pre-computation logic after timecode extraction
   - Pass values to MediaFileInfo initializer
   - Add logging for debugging

3. ✅ **Update FFmpegGradedSegment** (printProcessFFmpeg.swift:41-75)
   - Add two optional stored properties (startFrameNumber, endFrameNumber)
   - Update initializer

4. ✅ **Update VideoStreamProperties** (printProcessFFmpeg.swift:18-39)
   - Add optional startFrameNumber property
   - Update analyzeVideoWithFFmpeg to compute it

5. ✅ **Test: Import New Media**
   - Verify pre-computed values populate correctly
   - Run on test files with various frame rates/timecodes

### Phase 2: Add Fallback Logic (Maintains Compatibility)

6. ✅ **Add legacy fallback helpers**
   - `isSegmentInOCFRangeLegacy()` in linkingProcess.swift
   - Document as temporary for migration period

7. ✅ **Update RenderService conversion** (RenderService.swift:228-293)
   - Use pre-computed values with nil checks
   - Keep fallback logic for legacy files
   - Pass through to FFmpegGradedSegment

8. ✅ **Test: Load Legacy Project**
   - Load .w2 file created before changes
   - Verify fallback logic activates
   - Verify no crashes/errors

### Phase 3: Optimize Hot Paths (Enable Performance Gains)

9. ✅ **Update isSegmentInOCFRange** (linkingProcess.swift:306-345)
   - Replace with direct integer comparison
   - Add legacy fallback
   - Update call site (line 243-257)

10. ✅ **Update convertToFFmpegSegments** (RenderService.swift:228-293)
    - Use pre-computed frame numbers
    - Eliminate SMPTE calls

11. ✅ **Update calculateSegmentFramePosition** (FrameOwnershipAnalyzer.swift:229-267)
    - Add fast path using pre-computed values
    - Keep time-based fallback

12. ✅ **Test: Performance Benchmark**
    - Measure linking time before/after
    - Measure render time before/after
    - Compare SMPTE call counts (should be 0)

### Phase 4: Migration & Cleanup

13. ✅ **Add automatic migration logic**
    - Detect missing pre-computed values on load
    - Trigger background re-computation
    - Save updated .w2 file

14. ✅ **Add validation script**
    - Verify pre-computed values match SMPTE calculations
    - Run on test suite

15. ✅ **Documentation updates**
    - Update CLAUDE.md with new architecture notes
    - Add comment about legacy fallback removal timeline

### Phase 5: Monitor & Remove Fallbacks (Future)

16. ⏳ **Monitor usage (1-2 releases)**
    - Log when fallback logic activates
    - Track migration adoption rate

17. ⏳ **Remove legacy fallback helpers (v0.2.x)**
    - After users have migrated projects
    - Remove `isSegmentInOCFRangeLegacy()`
    - Clean up nil-check branches

---

## Section 7: Risk Assessment

### Low Risk ✅
- **Adding optional fields:** Codable handles gracefully
- **Backward compatibility:** Nil fallbacks prevent crashes
- **Testing:** Easy to validate (compare with SMPTE calculations)

### Medium Risk ⚠️
- **Migration complexity:** Users might not re-import immediately
  - **Mitigation:** Automatic background migration on load
- **Edge cases:** Drop frame timecode edge cases
  - **Mitigation:** Comprehensive test suite with real-world files

### High Risk ❌
- **None identified** - Changes are additive and backward compatible

---

## Appendix: Performance Measurement

**Add to diagnostic tools:**

```swift
func benchmarkFrameCalculations(files: [MediaFileInfo]) {
    let startTime = CFAbsoluteTimeGetCurrent()
    var smpteCallCount = 0

    // Simulate linking stage
    for segment in files {
        for ocf in files {
            // Old method
            if let segmentTC = segment.sourceTimecode,
               let ocfTC = ocf.sourceTimecode,
               let fps = segment.frameRateFloat {
                let smpte = SMPTE(fps: Double(fps), dropFrame: false)
                do {
                    _ = try smpte.getFrames(tc: segmentTC)
                    _ = try smpte.getFrames(tc: ocfTC)
                    smpteCallCount += 2
                } catch {}
            }
        }
    }

    let oldTime = CFAbsoluteTimeGetCurrent() - startTime

    // New method
    let newStartTime = CFAbsoluteTimeGetCurrent()
    var precomputedLookups = 0

    for segment in files {
        for ocf in files {
            if let _ = segment.startFrameNumber,
               let _ = ocf.startFrameNumber {
                precomputedLookups += 2
            }
        }
    }

    let newTime = CFAbsoluteTimeGetCurrent() - newStartTime

    print("📊 Performance Comparison:")
    print("   Old method: \(String(format: "%.3f", oldTime))s (\(smpteCallCount) SMPTE calls)")
    print("   New method: \(String(format: "%.3f", newTime))s (\(precomputedLookups) pre-computed lookups)")
    print("   Speedup: \(String(format: "%.1f", oldTime / newTime))x faster")
}
```

---

**End of Optimization Plan**

This plan provides a complete roadmap for eliminating redundant calculations while maintaining backward compatibility and code safety. The phased implementation ensures each step is testable and reversible.
