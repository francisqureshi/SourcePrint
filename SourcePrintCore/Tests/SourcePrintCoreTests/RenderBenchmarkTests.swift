import XCTest
import Foundation
@testable import SourcePrintCore

/// Opt-in integration/benchmark harness: runs only against explicitly prepared local copies.
final class RenderBenchmarkTests: XCTestCase {
    struct Scenario: Codable { let name: String; let ocf: String; let grades: [String] }
    struct Fixtures: Codable { let cases: [Scenario]; let revisions: [Scenario] }
    struct Measurement: Codable {
        let scenario: String
        let iteration: Int
        let strategy: String
        let cacheState: String
        let seconds: Double
        let blankFramesAdded: Int
        let cacheBytes: Int64
        let cacheFiles: Int
        let outputBytes: Int64
        let frames: Int
        let pictureMatchesBaseline: Bool?
    }
    func testLocal4KBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Set SOURCEPRINT_BENCHMARK_ROOT to an isolated prepared benchmark directory")
        }
        let root = URL(fileURLWithPath: path)
        let fixture = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let work = root.appendingPathComponent("Runs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var measurements: [Measurement] = []
        let repetitions = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_REPEATS"] ?? "3") ?? 3
        let limit = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_LIMIT"] ?? "0") ?? 0
        let scenarios = limit > 0 ? Array(fixture.cases.prefix(limit)) : fixture.cases
        for iteration in 1...repetitions {
            for scenario in scenarios {
                let workspace = work.appendingPathComponent("\(iteration)-\(scenario.name)")
                try await run(scenario, iteration: iteration, state: "cold", workspace: workspace, measurements: &measurements, root: root)
                if ProcessInfo.processInfo.environment["SOURCEPRINT_STRESS_CLEANUP"] == "1" { try FileManager.default.removeItem(at: workspace) }
            }
            if limit == 0 {
                let revisionWork = work.appendingPathComponent("\(iteration)-revisions")
                for (index, scenario) in fixture.revisions.enumerated() {
                    try await run(scenario, iteration: iteration, state: index == 0 ? "revision-cold" : "revision-warm", workspace: revisionWork, measurements: &measurements, root: root)
                }
                if ProcessInfo.processInfo.environment["SOURCEPRINT_STRESS_CLEANUP"] == "1" { try FileManager.default.removeItem(at: revisionWork) }
            }
        }
        print("BENCHMARK_RESULTS \(root.appendingPathComponent("results.json").path)")
    }

    func testLocal4KWarmBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Set SOURCEPRINT_BENCHMARK_ROOT to isolated local fixtures")
        }
        let root = URL(fileURLWithPath: path)
        let fixture = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: root.appendingPathComponent("cases.json")))
        let work = root.appendingPathComponent("WarmRuns-\(UUID().uuidString)")
        var measurements: [Measurement] = []
        let repetitions = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_REPEATS"] ?? "5") ?? 5
        for scenario in fixture.cases {
            let workspace = work.appendingPathComponent(scenario.name)
            // Populate both caches once. Warm-up measurements are recorded separately.
            try await run(scenario, iteration: 1, state: "warmup", workspace: workspace,
                          measurements: &measurements, root: root, resultsName: "warm-results.json")
            for iteration in 1...repetitions {
                try await run(scenario, iteration: iteration, state: "unchanged-warm", workspace: workspace,
                              measurements: &measurements, root: root, resultsName: "warm-results.json",
                              reverseOrder: iteration % 2 == 1)
            }
            if ProcessInfo.processInfo.environment["SOURCEPRINT_STRESS_CLEANUP"] == "1" { try FileManager.default.removeItem(at: workspace) }
        }
        print("WARM_BENCHMARK_RESULTS \(root.appendingPathComponent("warm-results.json").path)")
    }

    private func run(_ scenario: Scenario, iteration: Int, state: String, workspace: URL,
                     measurements: inout [Measurement], root: URL, resultsName: String = "results.json",
                     reverseOrder: Bool = false) async throws {
        let analyzer = MediaAnalyzer()
        let ocf = try await analyzer.analyzeMediaFile(at: URL(fileURLWithPath: scenario.ocf), type: .originalCameraFile)
        var grades: [LinkedSegment] = []
        for path in scenario.grades {
            let grade = try await analyzer.analyzeMediaFile(at: URL(fileURLWithPath: path), type: .gradedSegment)
            grades.append(LinkedSegment(segment: grade, linkConfidence: .high, linkMethod: "benchmark"))
        }
        let parent = OCFParent(ocf: ocf, children: grades)
        var outputs: [String: (url: URL, hashes: [String])] = [:]
        for strategy in (reverseOrder ? ["hybrid", "legacy"] : ["legacy", "hybrid"]) {
            let directory = workspace.appendingPathComponent(strategy)
            let cache = directory.appendingPathComponent("BlankRushes")
            let output = directory.appendingPathComponent("Output")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let before = try cacheStats(cache)
            let service = RenderService(configuration: RenderConfiguration(blankRushDirectory: cache, outputDirectory: output))
            let start = Date()
            let result = strategy == "legacy" ? await service.renderLegacyOCF(parent: parent) : await service.renderOCF(parent: parent)
            let seconds = Date().timeIntervalSince(start)
            XCTAssertTrue(result.success, result.error ?? "Render failed")
            let rendered = try XCTUnwrap(result.outputURL, result.error ?? "No output")
            let info = try await analyzer.analyzeMediaFile(at: rendered, type: .originalCameraFile)
            XCTAssertEqual(info.durationInFrames, ocf.durationInFrames)
            XCTAssertEqual(info.sourceTimecode, ocf.sourceTimecode)
            XCTAssertEqual(info.resolution, ocf.effectiveDisplayResolution)
            XCTAssertEqual(info.frameRate?.num, ocf.frameRate?.num)
            XCTAssertEqual(info.frameRate?.den, ocf.frameRate?.den)
            // Compare compressed frame payloads; when encoder packet headers differ,
            // decode both outputs and compare every pixel via framemd5 instead.
            let hashes = try packetHashes(rendered)
            XCTAssertEqual(hashes.count, Int(ocf.durationInFrames!))
            outputs[strategy] = (rendered, hashes)
            let after = try cacheStats(cache)
            if state == "unchanged-warm" {
                XCTAssertEqual(after.frames, before.frames, "Unchanged rerender regenerated blanks")
                XCTAssertEqual(after.bytes, before.bytes)
                XCTAssertEqual(after.files, before.files)
            }
            if state.hasPrefix("revision") {
                let expected = strategy == "legacy" ? (scenario.name == "initial" ? 235 : 0)
                    : (scenario.name == "initial" ? 45 : scenario.name == "shorter" ? 40 : 0)
                XCTAssertEqual(after.frames - before.frames, expected, "Unexpected cache regeneration")
            }
            measurements.append(Measurement(scenario: scenario.name, iteration: iteration, strategy: strategy,
                cacheState: state, seconds: seconds, blankFramesAdded: after.frames - before.frames,
                cacheBytes: after.bytes, cacheFiles: after.files,
                outputBytes: RenderOutputFingerprint.capture(at: rendered)!.size,
                frames: Int(ocf.durationInFrames!), pictureMatchesBaseline: nil))
            try JSONEncoder().encode(measurements).write(to: root.appendingPathComponent(resultsName), options: .atomic)
            print("BENCH \(iteration) \(scenario.name) \(strategy): \(seconds) s, \(after.frames - before.frames) new blank frames")
        }
        let baseline = try XCTUnwrap(outputs["legacy"])
        let hybrid = try XCTUnwrap(outputs["hybrid"])
        let plan = try RenderPlan(parent: parent)
        var originalPackets: [URL: [String]] = [:]
        for range in plan.grades {
            if originalPackets[range.segment.url] == nil { originalPackets[range.segment.url] = try packetHashes(range.segment.url) }
            let original = try XCTUnwrap(originalPackets[range.segment.url])
            XCTAssertEqual(Array(hybrid.hashes[range.startFrame..<range.endFrame]),
                           Array(original[range.segmentStartOffset..<(range.segmentStartOffset + range.frameCount)]),
                           "Output picture differs from original grade for \(scenario.name)")
            XCTAssertEqual(Array(hybrid.hashes[range.startFrame..<range.endFrame]),
                           Array(baseline.hashes[range.startFrame..<range.endFrame]),
                           "Graded packets changed for \(scenario.name)")
        }
        if hybrid.hashes != baseline.hashes && iteration == 1 && state != "unchanged-warm" {
            XCTAssertEqual(try decodedHashes(hybrid.url, gaps: plan.gaps),
                           try decodedHashes(baseline.url, gaps: plan.gaps),
                           "Decoded blank frames differ for \(scenario.name)")
        }
        // Outputs are disposable; retain caches for the next revision, not large rendered movies.
        for strategy in ["legacy", "hybrid"] {
            try FileManager.default.removeItem(at: workspace.appendingPathComponent("\(strategy)/Output"))
        }
    }
    private func cacheStats(_ root: URL) throws -> (frames: Int, bytes: Int64, files: Int) {
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "mov" }
        var count = 0
        var bytes: Int64 = 0
        for file in files {
            let json = try JSONSerialization.jsonObject(with: command("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=nb_frames", "-of", "json", file.path])) as! [String: Any]
            let streams = json["streams"] as! [[String: Any]]
            count += Int(streams[0]["nb_frames"] as? String ?? "0") ?? 0
            bytes += RenderOutputFingerprint.capture(at: file)?.size ?? 0
        }
        return (count, bytes, files.count)
    }
    private func packetHashes(_ url: URL) throws -> [String] {
        let data = try command("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "json", url.path])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["packets"] as! [[String: Any]]).map { $0["data_hash"] as! String }
    }
    private func decodedHashes(_ url: URL, gaps: [Range<Int>]) throws -> [String] {
        let selection = gaps.map { "between(n,\($0.lowerBound),\($0.upperBound - 1))" }.joined(separator: "+")
        let data = try command("ffmpeg", ["-v", "error", "-i", url.path, "-map", "0:v:0", "-vf", "select='\(selection)'", "-fps_mode", "passthrough", "-f", "framemd5", "-"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }.map { String($0.split(separator: ",").last!).trimmingCharacters(in: .whitespaces) }
    }
    private func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }
}
