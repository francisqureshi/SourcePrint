import Foundation
import CoreMedia
import SwiftFFmpeg

/// Exact, half-open frame ranges. OCF defines the timeline; grades supply the picture.
struct RenderPlan {
    let properties: VideoStreamProperties
    let totalFrames: Int
    let grades: [ProcessingRange]
    let gaps: [Range<Int>]
    let copySource: URL?

    init(parent: OCFParent) throws {
        let ocf = parent.ocf
        guard let count = ocf.durationInFrames, count > 0, count <= Int.max,
              let rate = ocf.frameRate, rate.num > 0, rate.den > 0,
              let resolution = ocf.effectiveDisplayResolution,
              let baseStart = ocf.effectiveStartFrame, let tc = ocf.sourceTimecode,
              !parent.children.isEmpty else { throw RenderPlanningError.invalidTimeline }
        totalFrames = Int(count)
        properties = VideoStreamProperties(width: Int(resolution.width), height: Int(resolution.height),
            frameRate: rate, frameRateFloat: Float(rate.num) / Float(rate.den),
            duration: Double(count) * Double(rate.den) / Double(rate.num),
            timebase: AVRational(num: rate.den, den: rate.num), timecode: tc)
        var segments: [FFmpegGradedSegment] = []
        for child in parent.children {
            let file = child.segment
            guard let start = file.effectiveStartFrame, let frames = file.durationInFrames,
                  frames > 0, start >= baseStart, Int64(start - baseStart) + frames <= count,
                  let fps = file.frameRate,
                  Int64(fps.num) * Int64(rate.den) == Int64(rate.num) * Int64(fps.den),
                  file.effectiveDisplayResolution == ocf.effectiveDisplayResolution,
                  file.isDropFrame == ocf.isDropFrame else {
                throw RenderPlanningError.invalidSegment(file.fileName)
            }
            segments.append(FFmpegGradedSegment(url: file.url,
                startTime: CMTime(value: Int64(start - baseStart) * Int64(rate.den), timescale: rate.num),
                duration: CMTime(value: frames * Int64(rate.den), timescale: rate.num),
                sourceStartTime: .zero, isVFXShot: file.isVFXShot ?? false,
                frameRate: Float(rate.num) / Float(rate.den), frameRateRational: rate,
                isDropFrame: file.isDropFrame, cachedStreamProperties: properties))
        }
        // Match existing compositor order: regular grades, then VFX, ordered by position.
        segments = (segments.filter { !$0.isVFXShot } + segments.filter { $0.isVFXShot })
            .sorted { $0.startTime < $1.startTime }
        grades = try FrameOwnershipAnalyzer(baseProperties: properties, segments: segments,
            totalFrames: totalFrames).analyze().consolidatedRanges
        var missing: [Range<Int>] = []
        var cursor = 0
        for range in grades {
            if cursor < range.startFrame { missing.append(cursor..<range.startFrame) }
            cursor = range.endFrame
        }
        if cursor < totalFrames { missing.append(cursor..<totalFrames) }
        gaps = missing
        copySource = parent.children.count == 1 && missing.isEmpty
            && parent.children[0].segment.durationInFrames == count
            && parent.children[0].segment.effectiveStartFrame == baseStart
            ? parent.children[0].segment.url : nil
    }
}

enum RenderPlanningError: LocalizedError {
    case invalidTimeline, invalidSegment(String), incompleteMedia, sourceChanged, outputIsSource
    var errorDescription: String? {
        switch self {
        case .invalidTimeline: return "Cannot plan a render without valid OCF metadata and graded segments."
        case .invalidSegment(let name): return "\(name) does not fit the OCF frame range or format. Refresh and link again."
        case .incompleteMedia: return "The rendered media does not contain the expected frames or format."
        case .sourceChanged: return "A source changed during rendering. Refresh and render again."
        case .outputIsSource: return "The output location would overwrite source media. Choose another output folder."
        }
    }
}
