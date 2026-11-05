import Foundation

/// Refreshes saved metadata by full file URL, including legacy projects with no fingerprint.
public enum SourceMediaRefresh {
    public struct Change: Identifiable {
        public var id: URL { original.url }
        public let original: MediaFileInfo
        public let refreshed: MediaFileInfo

        public struct Difference {
            public let field: String
            public let before: String
            public let after: String
        }

        public var differences: [Difference] {
            var rows: [Difference] = []
            if original.durationInFrames != refreshed.durationInFrames {
                rows.append(Difference(field: "Duration (frames)", before: original.durationInFrames.map(String.init) ?? "Unknown", after: refreshed.durationInFrames.map(String.init) ?? "Unknown"))
            }
            if original.sourceTimecode != refreshed.sourceTimecode {
                rows.append(Difference(field: "Start TC", before: original.sourceTimecode ?? "Unknown", after: refreshed.sourceTimecode ?? "Unknown"))
            }
            if original.endTimecode != refreshed.endTimecode {
                rows.append(Difference(field: "End TC", before: original.endTimecode ?? "Unknown", after: refreshed.endTimecode ?? "Unknown"))
            }
            if original.effectiveDisplayResolution != refreshed.effectiveDisplayResolution {
                func resolution(_ file: MediaFileInfo) -> String {
                    guard let r = file.effectiveDisplayResolution else { return "Unknown" }
                    return "\(Int(r.width)) × \(Int(r.height))"
                }
                rows.append(Difference(field: "Resolution", before: resolution(original), after: resolution(refreshed)))
            }
            if original.frameRateFloat != refreshed.frameRateFloat {
                rows.append(Difference(field: "FPS", before: original.frameRateFloat.map { String($0) } ?? "Unknown", after: refreshed.frameRateFloat.map { String($0) } ?? "Unknown"))
            }
            if rows.isEmpty {
                rows.append(Difference(field: "File", before: "Previous version", after: "Changed (\(refreshed.durationInFrames.map(String.init) ?? "Unknown") frames)"))
            }
            return rows
        }

        public var details: [String] {
            differences.map { difference in
                if difference.field == "Duration (frames)" {
                    return "Duration: \(difference.before) → \(difference.after) frames"
                }
                return "\(difference.field): \(difference.before) → \(difference.after)"
            }
        }

    }

    public struct Unavailable: Identifiable {
        public var id: URL { original.url }
        public let original: MediaFileInfo
        public let status: String
        public let message: String
    }

    public struct Inspection {
        public let changes: [Change]
        public let unavailable: [Unavailable]
        public var canRender: Bool { unavailable.isEmpty }
    }

    /// Collect every unavailable clip alongside valid metadata changes, without mutating the project.
    public static func inspect(_ files: [MediaFileInfo]) async throws -> Inspection {
        var changes: [Change] = []
        var unavailable: [Unavailable] = []
        for file in ProjectOperations.uniqueMediaFiles(files) {
            try Task.checkCancellation()
            do {
                let refreshed = try await refresh(file)
                if refreshed.analyzedFingerprint != file.analyzedFingerprint {
                    changes.append(Change(original: file, refreshed: refreshed))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                let missing = nsError.domain == NSCocoaErrorDomain &&
                    (nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError)
                unavailable.append(Unavailable(original: file,
                    status: missing ? "Missing / offline" : "Unreadable",
                    message: error.localizedDescription))
            }
        }
        return Inspection(changes: changes, unavailable: unavailable)
    }

    /// Read-only inspection: cancelling a render leaves the project's saved metadata intact.
    public static func changes(in files: [MediaFileInfo]) async throws -> [Change] {
        let inspection = try await inspect(files)
        if let issue = inspection.unavailable.first {
            throw CocoaError(.fileReadUnknown, userInfo: [NSLocalizedDescriptionKey: "\(issue.original.fileName): \(issue.message)"])
        }
        return inspection.changes
    }

    public static func refresh(_ file: MediaFileInfo) async throws -> MediaFileInfo {
        _ = try FileManager.default.attributesOfItem(atPath: file.url.path)
        guard FileManager.default.isReadableFile(atPath: file.url.path) else {
            throw CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: file.url.path])
        }
        guard let current = RenderOutputFingerprint.capture(at: file.url) else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: file.url.path])
        }
        if file.analyzedFingerprint == current,
           let resolution = file.resolution, resolution.width > 0, resolution.height > 0,
           let frames = file.durationInFrames, frames > 0,
           let rate = file.frameRate, rate.num > 0, rate.den > 0 { return file }
        var refreshed = try await MediaAnalyzer().analyzeMediaFile(at: file.url, type: file.mediaType)
        guard let resolution = refreshed.resolution, resolution.width > 0, resolution.height > 0,
              let frames = refreshed.durationInFrames, frames > 0,
              let rate = refreshed.frameRate, rate.num > 0, rate.den > 0 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                "Cannot read valid video metadata for \(file.fileName). The file may be incomplete or damaged."])
        }
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
