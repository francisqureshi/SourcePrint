import Foundation

public enum MatchingOCFDiscovery {
    public struct Result {
        public let matches: [MediaFileInfo]
        public let notices: [String]
    }

    public static func search(folder: URL, segments: [MediaFileInfo], existingOCFs: [MediaFileInfo],
                              progress: @escaping (Int, Int, URL) async -> Void = { _, _, _ in }) async throws -> Result {
        let excluded = Set((segments + existingOCFs).map { $0.url.standardizedFileURL.resolvingSymlinksInPath() })
        let discovery = await MediaImportSelection.discover([folder])
        let files = discovery.files.filter { !excluded.contains($0.standardizedFileURL.resolvingSymlinksInPath()) }
        var matches: [MediaFileInfo] = []
        var notices = discovery.notices
        for (index, url) in files.enumerated() {
            try Task.checkCancellation()
            await progress(index + 1, files.count, url)
            do {
                let file = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .originalCameraFile)
                if segments.contains(where: { SegmentOCFLinker().matchesForDiscovery(segment: $0, ocf: file) }) {
                    matches.append(file)
                }
            } catch {
                notices.append("Could not read \(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return Result(matches: matches, notices: notices)
    }
}
