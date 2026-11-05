import Foundation

/// Shared discovery for picker and Finder imports. Call away from the main actor.
public enum MediaImportSelection {
    public struct Result {
        public let files: [URL]
        public let notices: [String]
    }

    public static func discover(_ locations: [URL]) async -> Result {
        var files: [URL] = []
        var notices: [String] = []
        var seen = Set<URL>()
        var unsupported = 0
        var repeated = 0
        let fm = FileManager.default

        for location in locations {
            do {
                guard location.isFileURL else { unsupported += 1; continue }
                let values = try location.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                let candidates: [URL]
                if values.isDirectory == true {
                    guard fm.isReadableFile(atPath: location.path) else {
                        throw VideoFileDiscoveryError.directoryNotAccessible(location)
                    }
                    candidates = try await VideoFileDiscovery.discoverVideoFiles(in: location)
                    if candidates.isEmpty { notices.append("No supported videos in \(location.lastPathComponent).") }
                } else if values.isRegularFile == true &&
                            VideoFileDiscovery.isVideoFile(location) {
                    candidates = [location]
                } else {
                    unsupported += 1
                    continue
                }
                for candidate in candidates {
                    guard seen.insert(candidate.standardizedFileURL).inserted else {
                        repeated += 1
                        continue
                    }
                    if fm.isReadableFile(atPath: candidate.path) {
                        files.append(candidate)
                    } else {
                        notices.append("Cannot read \(candidate.lastPathComponent).")
                    }
                }
            } catch {
                notices.append("Cannot read \(location.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if unsupported > 0 { notices.append("Skipped \(unsupported) unsupported item(s).") }
        if repeated > 0 { notices.append("Skipped \(repeated) repeated path(s) in this selection.") }
        return Result(files: files, notices: notices)
    }
}
