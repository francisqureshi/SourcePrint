import XCTest
import Foundation
import SwiftFFmpeg
@testable import SourcePrintCore

/// Opt-in, retained 4K fixture for inspecting a heavily edited timeline in the app.
final class HeavyGapDemoTests: XCTestCase {
    func testTwentyThousandFramesFiftyGradesAndEdits() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_HEAVY_DEMO"] else {
            throw XCTSkip("Requires an explicitly prepared disposable demo directory")
        }
        let root = URL(fileURLWithPath: path)
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("Cache").path),
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("Grades").path) else {
            throw XCTSkip("Use a fresh disposable fixture directory for the cold-cache assertions")
        }
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: root.appendingPathComponent("Stress20K.mov"), type: .originalCameraFile)
        XCTAssertEqual(ocf.durationInFrames, 20000)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var baseline: [LinkedSegment] = []
        var revised: [LinkedSegment] = []
        func grade(_ name: String, _ range: Range<Int>) async throws -> LinkedSegment {
            let url = root.appendingPathComponent("Grades/\(name).mov")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let tc = try SMPTE(fps: 25, dropFrame: false).addFrames(to: "01:00:00:00", frames: range.lowerBound)
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["ffmpeg", "-v", "error", "-y", "-stream_loop", "-1", "-i", root.appendingPathComponent("Fixtures/grade-seed.mov").path,
                "-map", "0:v:0", "-c", "copy", "-frames:v", String(range.count), "-an", "-timecode", tc, url.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
            let media = try await analyzer.analyzeMediaFile(at: url, type: .gradedSegment)
            XCTAssertEqual(media.durationInFrames, Int64(range.count))
            return LinkedSegment(segment: media, linkConfidence: .high, linkMethod: "manual")
        }
        for index in 0..<50 {
            let start = index * 400 + 100
            let original = try await grade(String(format: "Grade_%02d", index + 1), start..<(start + 200))
            baseline.append(original)
            if index < 10 {
                revised.append(try await grade(String(format: "Shortened_%02d", index + 1), start..<(start + 150)))
            } else if index < 20 {
                revised.append(try await grade(String(format: "Split_%02d_A", index + 1), start..<(start + 90)))
                revised.append(try await grade(String(format: "Split_%02d_B", index + 1), (start + 110)..<(start + 200)))
            } else if index < 30 {
                if index % 2 == 0 {
                    revised.append(try await grade(String(format: "Merged_%02d_%02d", index + 1, index + 2), start..<(start + 600)))
                }
            } else { revised.append(original) }
        }
        XCTAssertEqual(baseline.count, 50); XCTAssertEqual(revised.count, 55)
        let cacheRoot = root.appendingPathComponent("Cache")
        let service = RenderService(configuration: .init(blankRushDirectory: cacheRoot, outputDirectory: root.appendingPathComponent("Output")))
        var previousEntries: [BlankRangeCache.Entry] = []
        var reports: [[String: Any]] = []
        for pass in 0..<4 {
            let parent = OCFParent(ocf: ocf, children: pass < 2 ? baseline : revised)
            let plan = try RenderPlan(parent: parent)
            XCTAssertEqual(plan.gaps.reduce(0) { $0 + $1.count }, pass < 2 ? 10000 : 9700)
            let start = Date()
            let result = await service.renderOCF(parent: parent)
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertTrue(result.success, result.error ?? "")
            let output = try XCTUnwrap(result.outputURL)
            let info = try await analyzer.analyzeMediaFile(at: output, type: .originalCameraFile)
            XCTAssertEqual(info.durationInFrames, 20000)
            XCTAssertEqual(info.sourceTimecode, ocf.sourceTimecode)
            XCTAssertEqual(info.endTimecode, ocf.endTimecode)
            XCTAssertEqual(info.resolution, ocf.resolution)
            XCTAssertEqual(info.frameRate?.num, 25); XCTAssertEqual(info.frameRate?.den, 1)
            let cache = try BlankRangeCache(root: cacheRoot, ocf: ocf, plan: plan)
            let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self, from: Data(contentsOf: cache.directory.appendingPathComponent("ranges.json")))
            let oldNames = Set(previousEntries.map(\.file))
            let newEntries = entries.filter { !oldNames.contains($0.file) }
            let newFrames = newEntries.reduce(0) { $0 + $1.frames.count }
            XCTAssertEqual(newFrames, [10000, 0, 700, 0][pass])
            XCTAssertEqual(entries.count, pass < 2 ? 51 : 71)
            for old in previousEntries {
                XCTAssertEqual(RenderOutputFingerprint.capture(at: cache.directory.appendingPathComponent(old.file)), old.fingerprint)
            }
            for entry in newEntries { try await cache.validate(url: cache.directory.appendingPathComponent(entry.file), frames: entry.frames) }
            // Compare every output packet with the intended grade/cache source packet.
            let outputHashes = try packetHashes(output)
            XCTAssertEqual(outputHashes.count, 20000)
            var verified = 0
            for range in plan.grades {
                let source = try packetHashes(range.segment.url)
                XCTAssertEqual(Array(outputHashes[range.startFrame..<range.endFrame]), Array(source[range.segmentStartOffset..<(range.segmentStartOffset + range.frameCount)]))
                verified += range.frameCount
            }
            for gap in plan.gaps {
                var cursor = gap.lowerBound
                for entry in entries.sorted(by: { $0.start < $1.start }) where cursor < gap.upperBound && entry.end > cursor && entry.start <= cursor {
                    let end = min(entry.end, gap.upperBound)
                    let source = try packetHashes(cache.directory.appendingPathComponent(entry.file))
                    XCTAssertEqual(Array(outputHashes[cursor..<end]), Array(source[(cursor-entry.start)..<(end-entry.start)]))
                    verified += end - cursor; cursor = end
                }
                XCTAssertEqual(cursor, gap.upperBound)
            }
            XCTAssertEqual(verified, 20000)
            let report: [String: Any] = ["pass": pass, "seconds": elapsed, "grades": parent.children.count,
                "requiredBlankFrames": plan.gaps.reduce(0) { $0 + $1.count }, "newBlankFrames": newFrames,
                "cachedFiles": entries.count, "verifiedOutputFrames": verified]
            reports.append(report)
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
            try encoder.encode(parent).write(to: root.appendingPathComponent(pass < 2 ? "baseline-parent.json" : "revised-parent.json"))
            previousEntries = entries
            print("HEAVY_DEMO \(report)")
        }
    }
    private func packetHashes(_ url: URL) throws -> [String] {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "json", url.path]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (object["packets"] as! [[String: Any]]).map { $0["data_hash"] as! String }
    }
}
