import XCTest
import Foundation
import SwiftFFmpeg
@testable import SourcePrintCore

/// Opt-in synthetic 4K edge cases alongside the real-media benchmark matrix.
final class RenderStressTests: XCTestCase {
    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Requires explicit hardware stress-test opt-in")
        }
    }
    private func hashes(_ url: URL) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "json", url.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let value = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (value["packets"] as! [[String: Any]]).map { $0["data_hash"] as! String }
    }
    func test4KFractionalRatesDropFrameOneFrameGapsAndVFX() async throws {
        try requireOptIn()
        let formats: [(Int32, Int32, Bool)] = [(24,1,false), (25,1,false), (50,1,false),
            (24000,1001,false), (30000,1001,true), (60000,1001,true)]
        for (num, den, drop) in formats {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("RateStress-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let rate = AVRational(num: num, den: den)
            let seed = RenderPlanTests().file("camera.mov", start: 0, frames: 120, fps: rate)
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(seed)) as! [String: Any]
            let start = drop ? (num == 30000 ? "00:00:59;28" : "00:00:59;58") : "01:00:00:00"
            object["sourceTimecode"] = start; object["isDropFrame"] = drop
            let template = try JSONDecoder().decode(MediaFileInfo.self, from: JSONSerialization.data(withJSONObject: object))
            let generator = BlankRushIntermediate(projectDirectory: root.path)
            let cameraURL = root.appendingPathComponent("camera.mov")
            try generator.generateGap(ocf: template, frames: 0..<120, outputURL: cameraURL, progress: nil)
            let analyzer = MediaAnalyzer()
            let ocf = try await analyzer.analyzeMediaFile(at: cameraURL, type: .originalCameraFile)
            var children: [LinkedSegment] = []
            var sources: [URL: [String]] = [:]
            // One-frame holes at start, middle and end, plus a VFX overlap.
            for (index, frames) in [1..<45, 46..<119, 20..<30].enumerated() {
                let url = root.appendingPathComponent("grade-\(index).mov")
                try generator.generateGap(ocf: ocf, frames: frames, outputURL: url, progress: nil)
                var grade = try await analyzer.analyzeMediaFile(at: url, type: .gradedSegment)
                grade.isVFXShot = index == 2
                children.append(.init(segment: grade, linkConfidence: .high, linkMethod: "manual"))
                sources[url] = try hashes(url)
            }
            let parent = OCFParent(ocf: ocf, children: children)
            let plan = try RenderPlan(parent: parent)
            XCTAssertEqual(plan.gaps, [0..<1,45..<46,119..<120])
            let cacheRoot = root.appendingPathComponent("Cache")
            let service = RenderService(configuration: .init(blankRushDirectory: cacheRoot, outputDirectory: root.appendingPathComponent("Output")))
            var previousPackets: [String]?
            var previousManifest: Data?
            for pass in 0..<2 {
                let result = await service.renderOCF(parent: parent)
                XCTAssertTrue(result.success, "\(num)/\(den) pass \(pass): \(result.error ?? "")")
                let output = try XCTUnwrap(result.outputURL)
                let metadata = try await analyzer.analyzeMediaFile(at: output, type: .originalCameraFile)
                XCTAssertEqual(metadata.durationInFrames, 120)
                XCTAssertEqual(metadata.sourceTimecode, start)
                XCTAssertEqual(metadata.endTimecode, ocf.endTimecode)
                XCTAssertEqual(metadata.isDropFrame, drop)
                XCTAssertEqual(metadata.frameRate?.num, num); XCTAssertEqual(metadata.frameRate?.den, den)
                XCTAssertEqual(metadata.resolution, ocf.resolution)
                let packets = try hashes(output); XCTAssertEqual(packets.count, 120)
                for range in plan.grades {
                    let original = try XCTUnwrap(sources[range.segment.url])
                    XCTAssertEqual(Array(packets[range.startFrame..<range.endFrame]),
                        Array(original[range.segmentStartOffset..<(range.segmentStartOffset + range.frameCount)]))
                }
                let cache = try BlankRangeCache(root: cacheRoot, ocf: ocf, plan: plan)
                let data = try Data(contentsOf: cache.directory.appendingPathComponent("ranges.json"))
                if let previousPackets { XCTAssertEqual(packets, previousPackets) }
                if let previousManifest { XCTAssertEqual(data, previousManifest) }
                previousPackets = packets; previousManifest = data
                let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: data)
                XCTAssertEqual(entries.reduce(0) { $0 + $1.frames.count }, 3)
                for entry in entries { try await cache.validate(url: cache.directory.appendingPathComponent(entry.file), frames: entry.frames) }
            }
            let output = root.appendingPathComponent("Output/camera.mov")
            let fingerprint = RenderOutputFingerprint.capture(at: output)
            // Change a disposable source after preflight, while preparing the render.
            let mutator = await SourceMutator(url: children[0].segment.url)
            service.delegate = mutator
            let changed = await service.renderOCF(parent: parent)
            XCTAssertFalse(changed.success)
            XCTAssertTrue(changed.error?.contains("changed") == true)
            let didChange = await mutator.changed
            XCTAssertTrue(didChange)
            XCTAssertEqual(RenderOutputFingerprint.capture(at: output), fingerprint)
            service.delegate = nil
            // A removed grade must fail without replacing the previous successful output.
            try FileManager.default.removeItem(at: children[0].segment.url)
            let offline = await service.renderOCF(parent: parent)
            XCTAssertFalse(offline.success)
            XCTAssertEqual(RenderOutputFingerprint.capture(at: output), fingerprint)
            print("RATE_STRESS passed \(num)/\(den), drop=\(drop), cold/warm/VFX/one-frame-gaps/offline")
        }
    }

    func testFiveMinuteFragmentedColdWarmAndRevision() async throws {
        try requireOptIn()
        let fixture = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"]!).appendingPathComponent("long-ocf.mov")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw XCTSkip("Requires prepared five-minute synthetic fixture") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongServiceStress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: fixture, type: .originalCameraFile)
        XCTAssertEqual(ocf.durationInFrames, 7500)
        var children: [LinkedSegment] = []
        var originals: [URL: [String]] = [:]
        for index in 0..<30 {
            let first = index * 250 + 125
            let url = root.appendingPathComponent("grade-\(index).mov")
            let tc = try SMPTE(fps: 25, dropFrame: false).addFrames(to: ocf.sourceTimecode!, frames: first)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-v", "error", "-ss", String(Double(first) / 25), "-i", fixture.path,
                "-map", "0:v:0", "-c", "copy", "-frames:v", "125", "-an", "-timecode", tc, url.path]
            try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
            let grade = try await analyzer.analyzeMediaFile(at: url, type: .gradedSegment)
            children.append(.init(segment: grade, linkConfidence: .high, linkMethod: "manual"))
            originals[url] = try hashes(url)
        }
        let cacheRoot = root.appendingPathComponent("Cache")
        let service = RenderService(configuration: .init(blankRushDirectory: cacheRoot, outputDirectory: root.appendingPathComponent("Output")))
        var priorManifest: Data?
        for pass in 0..<3 {
            // Remove one grade on pass three: only its 125 newly exposed frames need blanks.
            let parent = OCFParent(ocf: ocf, children: pass == 2 ? Array(children.dropFirst()) : children)
            let plan = try RenderPlan(parent: parent)
            let result = await service.renderOCF(parent: parent)
            XCTAssertTrue(result.success, result.error ?? "")
            let output = try XCTUnwrap(result.outputURL)
            let info = try await analyzer.analyzeMediaFile(at: output, type: .originalCameraFile)
            XCTAssertEqual(info.durationInFrames, ocf.durationInFrames)
            XCTAssertEqual(info.sourceTimecode, ocf.sourceTimecode)
            XCTAssertEqual(info.endTimecode, ocf.endTimecode)
            XCTAssertEqual(info.resolution, ocf.resolution)
            XCTAssertEqual(info.frameRate?.num, 25); XCTAssertEqual(info.frameRate?.den, 1)
            let packets = try hashes(output); XCTAssertEqual(packets.count, 7500)
            for range in plan.grades {
                let source = try XCTUnwrap(originals[range.segment.url])
                XCTAssertEqual(Array(packets[range.startFrame..<range.endFrame]),
                    Array(source[range.segmentStartOffset..<(range.segmentStartOffset + range.frameCount)]))
            }
            let cache = try BlankRangeCache(root: cacheRoot, ocf: ocf, plan: plan)
            let manifest = try Data(contentsOf: cache.directory.appendingPathComponent("ranges.json"))
            if pass == 1 { XCTAssertEqual(manifest, priorManifest) }
            priorManifest = manifest
            let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: manifest)
            XCTAssertEqual(entries.reduce(0) { $0 + $1.frames.count }, pass == 2 ? 3875 : 3750)
            XCTAssertEqual(entries.count, pass == 2 ? 31 : 30)
            print("LONG_SERVICE_STRESS pass \(pass) complete; \(entries.count) cached ranges")
        }
    }

    func testTwentyFourConcurrentRequestsShareThreeCaches() async throws {
        try requireOptIn()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ContentionStress-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let plan = try RenderPlan(parent: parent)
        let gaps = [0..<1,10..<11,20..<21,30..<31,40..<41,50..<51]
        var generated = 0
        var reused = 0
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for index in 0..<24 {
                let cache = try BlankRangeCache(root: root.appendingPathComponent("cache-\(index % 3)"), ocf: parent.ocf, plan: plan)
                group.addTask {
                    let ranges = try await cache.ranges(for: gaps, progress: nil)
                    XCTAssertEqual(ranges.map(\.frameCount), [1,1,1,1,1,1])
                    return (cache.generatedFrames, cache.reusedFrames)
                }
            }
            for try await counts in group { generated += counts.0; reused += counts.1 }
        }
        XCTAssertEqual(generated, 18)
        XCTAssertEqual(reused, 126)
        for index in 0..<3 {
            let cache = try BlankRangeCache(root: root.appendingPathComponent("cache-\(index)"), ocf: parent.ocf, plan: plan)
            let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: cache.directory.appendingPathComponent("ranges.json")))
            XCTAssertEqual(entries.count, 6)
            XCTAssertEqual(Set(entries.map(\.file)).count, 6)
            for entry in entries { try await cache.validate(url: cache.directory.appendingPathComponent(entry.file), frames: entry.frames) }
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).contains { $0.hasPrefix(".pending-") })
        }
    }

    func testRepeatedParallelCancellationAndRetry() async throws {
        try requireOptIn()
        for _ in 0..<12 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CancelStress-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let helper = RenderPlanTests()
            let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
            let cache = try BlankRangeCache(root: root, ocf: parent.ocf, plan: RenderPlan(parent: parent))
            let started = expectation(description: "Generation active")
            started.assertForOverFulfill = false
            let work = Task { try await cache.ranges(for: [0..<400,600..<1000], progress: { _, _, _, _ in started.fulfill() }) }
            await fulfillment(of: [started], timeout: 10)
            work.cancel()
            do { _ = try await work.value; XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: cache.directory.path).isEmpty)
            let result = try await cache.ranges(for: [0..<2,600..<602], progress: nil)
            XCTAssertEqual(result.map(\.frameCount), [2,2])
        }
    }
}

@MainActor
private final class SourceMutator: RenderProgressDelegate {
    let url: URL
    var changed = false
    init(url: URL) { self.url = url }
    func renderService(_ service: RenderService, didUpdateProgress progress: RenderProgress) {
        guard !changed, progress.status == .generatingBlankRush else { return }
        do {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: url.path)
            changed = true
        } catch { XCTFail("Could not inject source change: \(error)") }
    }
}
