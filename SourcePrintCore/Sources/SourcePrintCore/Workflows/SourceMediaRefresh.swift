import Foundation

/// Refreshes saved metadata by full file URL, including legacy projects with no fingerprint.
public enum SourceMediaRefresh {
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
