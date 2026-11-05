import Foundation

/// Refreshes saved metadata by full file URL, including legacy projects with no fingerprint.
public enum SourceMediaRefresh {
    public struct Change: Identifiable {
        public var id: URL { original.url }
        public let original: MediaFileInfo
        public let refreshed: MediaFileInfo

        public var details: [String] {
            var lines: [String] = []
            if original.durationInFrames != refreshed.durationInFrames {
                lines.append("Duration: \(original.durationInFrames.map(String.init) ?? "Unknown") → \(refreshed.durationInFrames.map(String.init) ?? "Unknown") frames")
            }
            if original.sourceTimecode != refreshed.sourceTimecode {
                lines.append("Start TC: \(original.sourceTimecode ?? "Unknown") → \(refreshed.sourceTimecode ?? "Unknown")")
            }
            if original.endTimecode != refreshed.endTimecode {
                lines.append("End TC: \(original.endTimecode ?? "Unknown") → \(refreshed.endTimecode ?? "Unknown")")
            }
            if original.effectiveDisplayResolution != refreshed.effectiveDisplayResolution {
                func resolution(_ file: MediaFileInfo) -> String {
                    guard let r = file.effectiveDisplayResolution else { return "Unknown" }
                    return "\(Int(r.width)) × \(Int(r.height))"
                }
                lines.append("Resolution: \(resolution(original)) → \(resolution(refreshed))")
            }
            if original.frameRateFloat != refreshed.frameRateFloat {
                lines.append("FPS: \(original.frameRateFloat.map { String($0) } ?? "Unknown") → \(refreshed.frameRateFloat.map { String($0) } ?? "Unknown")")
            }
            if lines.isEmpty { lines.append("File changed; duration remains \(refreshed.durationInFrames.map(String.init) ?? "Unknown") frames.") }
            return lines
        }
    }

    /// Read-only inspection: cancelling a render leaves the project's saved metadata intact.
    public static func changes(in files: [MediaFileInfo]) async throws -> [Change] {
        var changes: [Change] = []
        for file in ProjectOperations.uniqueMediaFiles(files) {
            try Task.checkCancellation()
            let refreshed = try await refresh(file)
            if refreshed.analyzedFingerprint != file.analyzedFingerprint {
                changes.append(Change(original: file, refreshed: refreshed))
            }
        }
        return changes
    }

    public static func refresh(_ file: MediaFileInfo) async throws -> MediaFileInfo {
        guard let current = RenderOutputFingerprint.capture(at: file.url) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: file.url.path])
        }
        if file.analyzedFingerprint == current { return file }
        var refreshed = try await MediaAnalyzer().analyzeMediaFile(at: file.url, type: file.mediaType)
        refreshed.isVFXShot = file.isVFXShot
        return refreshed
    }

    /// A queued job is a snapshot. Reject changed sources rather than silently render a
    /// different match or use outdated offsets; the project must refresh and link again.
    public static func validateQueuedParent(_ parent: OCFParent) async throws {
        for child in parent.children {
            let refreshed = try await refresh(child.segment)
            let old = child.segment
            guard refreshed.durationInFrames == old.durationInFrames,
                  refreshed.sourceTimecode == old.sourceTimecode,
                  refreshed.endTimecode == old.endTimecode,
                  refreshed.resolution == old.resolution,
                  refreshed.effectiveDisplayResolution == old.effectiveDisplayResolution,
                  refreshed.isDropFrame == old.isDropFrame,
                  refreshed.fieldOrder == old.fieldOrder,
                  refreshed.frameRate?.num == old.frameRate?.num,
                  refreshed.frameRate?.den == old.frameRate?.den else {
                throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey:
                    "\(old.fileName) changed since linking. Refresh and link the media again before rendering."])
            }
        }
    }
}
