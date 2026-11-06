import Foundation
import CryptoKit
import CoreMedia

/// Persistent range cache, scoped by source identity, timeline and burn-in version.
/// Manifests are published only after generation and validation succeed.
final class BlankRangeCache {
    struct Entry: Codable {
        let start: Int
        let end: Int
        let file: String
        let fingerprint: RenderOutputFingerprint
        var frames: Range<Int> { start..<end }
    }
    struct Identity: Codable {
        let version: Int
        let source: String
        let fingerprint: RenderOutputFingerprint?
        let width: Int
        let height: Int
        let frames: Int
        let fpsNum: Int32
        let fpsDen: Int32
        let timecode: String?
        let dropFrame: Bool
        let clipName: String
    }
    let directory: URL
    private let ocf: MediaFileInfo
    private let plan: RenderPlan
    private var entries: [Entry] = []
    private(set) var generatedFrames = 0
    private(set) var reusedFrames = 0

    init(root: URL, ocf: MediaFileInfo, plan: RenderPlan) throws {
        self.ocf = ocf
        self.plan = plan
        let identity = Identity(version: 1, source: ocf.url.standardizedFileURL.resolvingSymlinksInPath().path,
            fingerprint: RenderOutputFingerprint.capture(at: ocf.url), width: plan.properties.width,
            height: plan.properties.height, frames: plan.totalFrames,
            fpsNum: plan.properties.frameRate.num, fpsDen: plan.properties.frameRate.den,
            timecode: plan.properties.timecode, dropFrame: ocf.isDropFrame ?? false, clipName: ocf.fileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let key = SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
        directory = root.appendingPathComponent("GapCache-v1", isDirectory: true).appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reloadEntries()
    }

    private func reloadEntries() {
        entries = []
        if let data = try? Data(contentsOf: directory.appendingPathComponent("ranges.json")),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved.filter {
                $0.start >= 0 && $0.end > $0.start && $0.end <= plan.totalFrames &&
                URL(fileURLWithPath: $0.file).lastPathComponent == $0.file &&
                RenderOutputFingerprint.capture(at: directory.appendingPathComponent($0.file)) == $0.fingerprint
            }
        }
    }

    /// One transaction per cache identity; independent ranges share a global two-worker limit.
    func ranges(for requested: Range<Int>, progress: BlankRushIntermediate.ProgressCallback?) async throws -> [ProcessingRange] {
        try await ranges(for: [requested], progress: progress)
    }

    func ranges(for requested: [Range<Int>], progress: BlankRushIntermediate.ProgressCallback?) async throws -> [ProcessingRange] {
        let permit = try await RenderWorkGate.caches.acquire(key: directory.standardizedFileURL.resolvingSymlinksInPath().path)
        do {
            let result = try await prepare(requested, progress: progress)
            await RenderWorkGate.caches.release(permit)
            return result
        } catch {
            await RenderWorkGate.caches.release(permit)
            throw error
        }
    }

    private func prepare(_ requested: [Range<Int>], progress: BlankRushIntermediate.ProgressCallback?) async throws -> [ProcessingRange] {
        // Another cache instance may have published while this transaction waited.
        reloadEntries()
        var result: [ProcessingRange] = []
        var missing: [Range<Int>] = []
        var reused = 0
        for request in requested {
            var cursor = request.lowerBound
            while cursor < request.upperBound {
                try Task.checkCancellation()
                if let entry = entries.filter({ $0.start <= cursor && $0.end > cursor }).max(by: { $0.end < $1.end }) {
                    let end = min(entry.end, request.upperBound)
                    result.append(range(url: directory.appendingPathComponent(entry.file), frames: cursor..<end, offset: cursor - entry.start))
                    reused += end - cursor
                    cursor = end
                } else {
                    let end = min(request.upperBound, entries.filter { $0.start > cursor }.map(\.start).min() ?? request.upperBound)
                    missing.append(cursor..<end)
                    cursor = end
                }
            }
        }
        // A warm cache is read-only: do not create staging directories or rewrite metadata.
        if missing.isEmpty {
            reusedFrames += reused
            return result.sorted { $0.startFrame < $1.startFrame }
        }
        let staging = directory.appendingPathComponent(".pending-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let meter = BlankGenerationProgress(total: missing.reduce(0) { $0 + $1.count }, name: ocf.fileName, callback: progress)
        var generated: [(Range<Int>, URL)] = []
        do {
            try await withThrowingTaskGroup(of: (Range<Int>, URL).self) { group in
                var next = 0
                func submit(_ index: Int) {
                    let frames = missing[index]
                    let url = staging.appendingPathComponent("\(index).mov")
                    group.addTask {
                        let slot = try await RenderWorkGate.workers.acquire()
                        do {
                            try Task.checkCancellation()
                            try BlankRushIntermediate(projectDirectory: staging.path).generateGap(
                                ocf: self.ocf, frames: frames, outputURL: url, progress: { _, current, _, _ in
                                    await meter.update(index, frames: min(frames.count, Int(current)))
                                })
                            try Task.checkCancellation()
                            try await self.validate(url: url, frames: frames)
                            try Task.checkCancellation()
                            await meter.update(index, frames: frames.count)
                            await RenderWorkGate.workers.release(slot)
                            return (frames, url)
                        } catch {
                            await RenderWorkGate.workers.release(slot)
                            throw error
                        }
                    }
                }
                while next < min(2, missing.count) { submit(next); next += 1 }
                while let item = try await group.next() {
                    generated.append(item)
                    if next < missing.count { submit(next); next += 1 }
                }
            }
            await meter.close()
        } catch {
            await meter.close()
            throw error
        }
        try Task.checkCancellation()
        // Publication is serial and atomic. On failure the previous manifest remains usable.
        var published: [URL] = []
        do {
            var updated = entries
            for (frames, temporary) in generated.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
                try Task.checkCancellation()
                let url = directory.appendingPathComponent("\(frames.lowerBound)-\(frames.upperBound)-\(UUID().uuidString).mov")
                try FileManager.default.moveItem(at: temporary, to: url)
                published.append(url)
                guard let fingerprint = RenderOutputFingerprint.capture(at: url) else { throw RenderPlanningError.incompleteMedia }
                updated.append(Entry(start: frames.lowerBound, end: frames.upperBound, file: url.lastPathComponent, fingerprint: fingerprint))
                result.append(range(url: url, frames: frames, offset: 0))
            }
            try Task.checkCancellation()
            if !generated.isEmpty {
                try JSONEncoder().encode(updated).write(to: directory.appendingPathComponent("ranges.json"), options: .atomic)
            }
            entries = updated
        } catch {
            for url in published { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        generatedFrames += missing.reduce(0) { $0 + $1.count }
        reusedFrames += reused
        return result.sorted { $0.startFrame < $1.startFrame }
    }

    func validate(url: URL, frames: Range<Int>) async throws {
        let file = try await MediaAnalyzer().analyzeMediaFile(at: url, type: .originalCameraFile)
        let rate = plan.properties.frameRate
        let tc = try SMPTE(fps: Double(rate.num) / Double(rate.den), dropFrame: ocf.isDropFrame ?? false)
            .addFrames(to: ocf.sourceTimecode!, frames: frames.lowerBound)
        guard file.durationInFrames == Int64(frames.count),
              file.resolution?.width == Double(plan.properties.width),
              file.resolution?.height == Double(plan.properties.height),
              file.sourceTimecode == tc,
              let fps = file.frameRate,
              Int64(fps.num) * Int64(rate.den) == Int64(rate.num) * Int64(fps.den) else {
            throw RenderPlanningError.incompleteMedia
        }
    }

    /// Legacy full blanks use the same burn-in layout. Validate their complete timeline
    /// before reuse; unlike a grade, they contain no source picture to confuse by path.
    func validFullBlank(at url: URL) async -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            try await validate(url: url, frames: 0..<plan.totalFrames)
            return try SwiftFFmpegProResCompositor.isProRes4444(at: url)
        } catch { return false }
    }

    func range(url: URL, frames: Range<Int>, offset: Int) -> ProcessingRange {
        let rate = plan.properties.frameRate
        return ProcessingRange(startFrame: frames.lowerBound, endFrame: frames.upperBound,
            segment: FFmpegGradedSegment(url: url, startTime: .zero,
                duration: CMTime(value: Int64(frames.count) * Int64(rate.den), timescale: rate.num),
                sourceStartTime: .zero, frameRateRational: rate, cachedStreamProperties: plan.properties), segmentStartOffset: offset)
    }
}

/// Cancellation-aware permits. Cache keys serialize writers; worker permits cap
/// expensive generation across all render services in this process.
actor RenderWorkGate {
    static let workers = RenderWorkGate(limit: 2)
    static let caches = RenderWorkGate(limit: Int.max)
    private let limit: Int
    private var active: [UUID: String] = [:]
    private var waiting: [(UUID, String, CheckedContinuation<UUID, Error>)] = []
    init(limit: Int) { precondition(limit > 0); self.limit = limit }

    func acquire(key: String = UUID().uuidString) async throws -> UUID {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                waiting.append((id, key, continuation))
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func release(_ id: UUID) { active.removeValue(forKey: id); drain() }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.0 == id }) {
            waiting.remove(at: index).2.resume(throwing: CancellationError())
        }
        // If already granted, the cancelled owner releases after checking cancellation.
    }
    private func drain() {
        var index = 0
        while active.count < limit && index < waiting.count {
            let item = waiting[index]
            if active.values.contains(item.1) { index += 1; continue }
            waiting.remove(at: index)
            active[item.0] = item.1
            item.2.resume(returning: item.0)
        }
    }
}

private actor BlankGenerationProgress {
    let total: Int
    let name: String
    let callback: BlankRushIntermediate.ProgressCallback?
    var counts: [Int: Int] = [:]
    var closed = false
    init(total: Int, name: String, callback: BlankRushIntermediate.ProgressCallback?) {
        self.total = total; self.name = name; self.callback = callback
    }
    func update(_ index: Int, frames: Int) async {
        guard !closed else { return }
        counts[index] = max(counts[index] ?? 0, frames)
        await callback?(name, Double(counts.values.reduce(0, +)), Double(total), 0)
    }
    func close() { closed = true }
}
