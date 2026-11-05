#if canImport(Darwin)
import XCTest
import Foundation
import Darwin
@testable import SourcePrintCore

/// Isolated generation/concurrency benchmark; worker sweeps are independent of the app scheduler.
final class LongRenderBenchmarkTests: XCTestCase {
    struct Measurement: Codable {
        let secondsOfTimeline: Int
        let coveragePercent: Int
        let gapCount: Int
        let workers: Int
        let iteration: Int
        let strategy: String
        let phase: String
        let seconds: Double
        let framesGenerated: Int
        let bytes: Int64
        let peakResidentMB: Double
        let mainActorMaxDelayMS: Double
    }
    actor Meter {
        var peak: UInt64 = 0
        var maxDelay = 0.0
        func sample(_ rss: UInt64, _ delay: Double) { peak = max(peak, rss); maxDelay = max(maxDelay, delay) }
        func values() -> (Double, Double) { (Double(peak) / 1_048_576, maxDelay * 1000) }
    }
    func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let code = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return code == KERN_SUCCESS ? info.resident_size : 0
    }
    func measured(_ operation: () async throws -> Void) async throws -> (Double, Double, Double) {
        let meter = Meter()
        await meter.sample(residentBytes(), 0)
        let monitor = Task.detached { [self] in
            while !Task.isCancelled {
                let sent = ContinuousClock.now
                await MainActor.run {}
                let elapsed = sent.duration(to: .now)
                let delay = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                await meter.sample(residentBytes(), delay)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer { monitor.cancel() }
        let start = ContinuousClock.now
        try await operation()
        let duration = start.duration(to: .now)
        await meter.sample(residentBytes(), 0)
        let (memory, delay) = await meter.values()
        return (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18, memory, delay)
    }
    func generate(_ jobs: [(Range<Int>, URL)], ocf: MediaFileInfo, workers: Int) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func submit(_ index: Int) {
                let job = jobs[index]
                group.addTask {
                    try Task.checkCancellation()
                    try BlankRushIntermediate(projectDirectory: job.1.deletingLastPathComponent().path)
                        .generateGap(ocf: ocf, frames: job.0, outputURL: job.1, progress: nil)
                }
            }
            while next < min(workers, jobs.count) { submit(next); next += 1 }
            while try await group.next() != nil {
                if next < jobs.count { submit(next); next += 1 }
            }
        }
    }
    func complement(_ gaps: [Range<Int>], total: Int) -> [Range<Int>] {
        var cursor = 0
        var grades: [Range<Int>] = []
        for gap in gaps {
            if cursor < gap.lowerBound { grades.append(cursor..<gap.lowerBound) }
            cursor = gap.upperBound
        }
        if cursor < total { grades.append(cursor..<total) }
        return grades
    }
    func gaps(total: Int, coverage: Int, count: Int) -> [Range<Int>] {
        let blankFrames = total * (100 - coverage) / 100
        return (0..<count).map { index in
            let start = total * index / count
            let length = blankFrames / count + (index < blankFrames % count ? 1 : 0)
            return start..<(start + length)
        }
    }
    func command(_ name: String, _ args: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [name] + args
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return data
    }
    func packetHashes(_ url: URL) throws -> [String] {
        let data = try command("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_packets", "-show_data_hash", "sha256", "-show_entries", "packet=data_hash", "-of", "json", url.path])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["packets"] as! [[String: Any]]).map { $0["data_hash"] as! String }
    }
    func frameHash(_ url: URL, frame: Int) throws -> String {
        let data = try command("ffmpeg", ["-v", "error", "-ss", String(Double(frame) / 25), "-i", url.path,
            "-map", "0:v:0", "-frames:v", "1", "-f", "framemd5", "-"])
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
        return try XCTUnwrap(lines.last?.split(separator: ",").last).trimmingCharacters(in: .whitespaces)
    }

    func testFourJobGenerationBatch() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Requires isolated benchmark root")
        }
        let root = URL(fileURLWithPath: path).appendingPathComponent("BatchRuns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let total = 1500
        let helper = RenderPlanTests()
        let ocf = helper.file("Synthetic4K.mov", start: 90000, frames: total)
        let parent = OCFParent(ocf: ocf, children: [LinkedSegment(segment: ocf, linkConfidence: .high, linkMethod: "benchmark")])
        let factory = try BlankRangeCache(root: root, ocf: ocf, plan: RenderPlan(parent: parent))
        var results: [Measurement] = []
        let repetitions = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_REPEATS"] ?? "3") ?? 3
        for iteration in 1...repetitions {
            for workers in (iteration % 2 == 1 ? [1, 2, 4] : [4, 2, 1]) {
                for strategy in (iteration % 2 == 1 ? ["full", "gaps"] : ["gaps", "full"]) {
                    let intervals = strategy == "full" ? [0..<total] : gaps(total: total, coverage: 50, count: 30)
                    let jobs = (0..<4).flatMap { job in intervals.enumerated().map { interval in
                        (interval.element, root.appendingPathComponent("job-\(job)-gap-\(interval.offset).mov"))
                    } }
                    let timing = try await measured { try await self.generate(jobs, ocf: ocf, workers: workers) }
                    for job in jobs { try await factory.validate(url: job.1, frames: job.0) }
                    let bytes = jobs.reduce(Int64(0)) { $0 + RenderOutputFingerprint.capture(at: $1.1)!.size }
                    results.append(Measurement(secondsOfTimeline: 60, coveragePercent: 50, gapCount: intervals.count,
                        workers: workers, iteration: iteration, strategy: strategy, phase: "four-job-generation",
                        seconds: timing.0, framesGenerated: jobs.reduce(0) { $0 + $1.0.count }, bytes: bytes,
                        peakResidentMB: timing.1, mainActorMaxDelayMS: timing.2))
                    try JSONEncoder().encode(results).write(to: URL(fileURLWithPath: path).appendingPathComponent("batch-results.json"), options: .atomic)
                    print("BATCH_BENCH \(strategy) workers=\(workers): \(timing.0)s")
                    for job in jobs { try FileManager.default.removeItem(at: job.1) }
                }
            }
        }
    }

    func testLong4KGenerationAndAssembly() async throws {
        guard let path = ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] else {
            throw XCTSkip("Requires isolated benchmark root")
        }
        let root = URL(fileURLWithPath: path).appendingPathComponent("LongRuns-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputJSON = URL(fileURLWithPath: path).appendingPathComponent("long-results.json")
        var results: [Measurement] = []
        let repetitions = Int(ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_REPEATS"] ?? "3") ?? 3
        let durations = ProcessInfo.processInfo.environment["SOURCEPRINT_LONG_SECONDS"].map { $0.split(separator: ",").compactMap { Int($0) } } ?? [60, 300]
        func record(_ duration: Int, _ coverage: Int, _ gaps: Int, _ workers: Int, _ iteration: Int,
                    _ strategy: String, _ phase: String, _ timing: (Double, Double, Double), _ frames: Int, _ bytes: Int64) throws {
            results.append(Measurement(secondsOfTimeline: duration, coveragePercent: coverage, gapCount: gaps,
                workers: workers, iteration: iteration, strategy: strategy, phase: phase, seconds: timing.0,
                framesGenerated: frames, bytes: bytes, peakResidentMB: timing.1, mainActorMaxDelayMS: timing.2))
            try JSONEncoder().encode(results).write(to: outputJSON, options: .atomic)
            print("LONG_BENCH \(duration)s \(coverage)% gaps=\(gaps) workers=\(workers) \(strategy) \(phase): \(timing.0)s")
        }
        let helper = RenderPlanTests()
        for duration in durations {
            let total = duration * 25
            let ocf = helper.file("Synthetic4K.mov", start: 90000, frames: total)
            let parent = OCFParent(ocf: ocf, children: [LinkedSegment(segment: helper.file("grade.mov", start: 90000, frames: total), linkConfidence: .high, linkMethod: "benchmark")])
            let plan = try RenderPlan(parent: parent)
            let factory = try BlankRangeCache(root: root, ocf: ocf, plan: plan)
            for iteration in 1...repetitions {
                let workspace = root.appendingPathComponent("\(duration)-\(iteration)")
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
                let full = workspace.appendingPathComponent("Full.mov")
                let timing = try await measured { try await self.generate([(0..<total, full)], ocf: ocf, workers: 1) }
                try await factory.validate(url: full, frames: 0..<total)
                try record(duration, 0, 1, 1, iteration, "full", "generation", timing, total, RenderOutputFingerprint.capture(at: full)!.size)
                let masterHashes = try packetHashes(full)
                XCTAssertEqual(masterHashes.count, total)
                for coverage in [50, 90] {
                    for gapCount in [2, 30] {
                        let gaps = gaps(total: total, coverage: coverage, count: gapCount)
                        let grades = complement(gaps, total: total)
                        // Same range boundaries and compositor for both strategies. The master
                        // supplies synthetic grade packets, isolating gap generation/assembly.
                        let gradeRanges = grades.map { factory.range(url: full, frames: $0, offset: $0.lowerBound) }
                        let oldRanges = (gradeRanges + gaps.map { factory.range(url: full, frames: $0, offset: $0.lowerBound) }).sorted { $0.startFrame < $1.startFrame }
                        let assembled = workspace.appendingPathComponent("assembled.mov")
                        let oldTiming = try await measured {
                            try await SwiftFFmpegProResCompositor().composeRanges(oldRanges, properties: plan.properties,
                                totalFrames: total, outputURL: assembled, headerSource: full)
                        }
                        try await factory.validate(url: assembled, frames: 0..<total)
                        XCTAssertEqual(try packetHashes(assembled), masterHashes)
                        try record(duration, coverage, gapCount, 1, iteration, "full", "assembly", oldTiming, 0, RenderOutputFingerprint.capture(at: assembled)!.size)
                        try FileManager.default.removeItem(at: assembled)
                        let workerOrder = iteration % 2 == 1 ? [1, 2, 4] : [4, 2, 1]
                        for workers in workerOrder {
                            let jobs = gaps.enumerated().map { ($0.element, workspace.appendingPathComponent("gap-\($0.offset).mov")) }
                            let generated = try await measured { try await self.generate(jobs, ocf: ocf, workers: workers) }
                            let validateTiming = try await measured {
                                for job in jobs { try await factory.validate(url: job.1, frames: job.0) }
                            }
                            let bytes = jobs.reduce(Int64(0)) { $0 + RenderOutputFingerprint.capture(at: $1.1)!.size }
                            try record(duration, coverage, gapCount, workers, iteration, "gaps", "generation", generated, gaps.reduce(0) { $0 + $1.count }, bytes)
                            try record(duration, coverage, gapCount, workers, iteration, "gaps", "validation", validateTiming, 0, bytes)
                            let ranges = (gradeRanges + jobs.map { factory.range(url: $0.1, frames: $0.0, offset: 0) }).sorted { $0.startFrame < $1.startFrame }
                            let composeTiming = try await measured {
                                try await SwiftFFmpegProResCompositor().composeRanges(ranges, properties: plan.properties,
                                    totalFrames: total, outputURL: assembled, headerSource: full)
                            }
                            try await factory.validate(url: assembled, frames: 0..<total)
                            let hashes = try packetHashes(assembled)
                            XCTAssertEqual(hashes.count, total)
                            for grade in grades { XCTAssertEqual(Array(hashes[grade]), Array(masterHashes[grade])) }
                            if iteration == 1 && workers == 4 {
                                for frame in [gaps.first!.lowerBound, gaps.first!.upperBound - 1,
                                              gaps.last!.lowerBound, gaps.last!.upperBound - 1] {
                                    XCTAssertEqual(try frameHash(assembled, frame: frame), try frameHash(full, frame: frame),
                                                   "Blank pixels/timecode differ at frame \(frame)")
                                }
                            }
                            try record(duration, coverage, gapCount, workers, iteration, "gaps", "assembly", composeTiming, 0, RenderOutputFingerprint.capture(at: assembled)!.size)
                            try FileManager.default.removeItem(at: assembled)
                            for job in jobs { try FileManager.default.removeItem(at: job.1) }
                        }
                    }
                }
                try FileManager.default.removeItem(at: workspace)
            }
        }
        print("LONG_RESULTS \(outputJSON.path)")
    }
}

#endif
