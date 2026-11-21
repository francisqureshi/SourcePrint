import XCTest
@testable import SourcePrintCore

final class ParallelGapTests: XCTestCase {
    func testWorkerLimitAndCancelledWaiterReleaseCapacity() async throws {
        let gate = RenderWorkGate(limit: 2)
        let first = try await gate.acquire()
        let second = try await gate.acquire()
        let blocked = expectation(description: "Third worker stays blocked")
        blocked.isInverted = true
        let third = Task {
            let token = try await gate.acquire()
            blocked.fulfill()
            await gate.release(token)
        }
        await fulfillment(of: [blocked], timeout: 0.1)
        third.cancel()
        do { try await third.value; XCTFail("Cancelled waiter acquired a permit") }
        catch { XCTAssertTrue(error is CancellationError) }
        await gate.release(first)
        await gate.release(second)
        let next = try await gate.acquire()
        await gate.release(next)
    }

    func testSameCacheKeyWaitsWhileOtherKeysProceed() async throws {
        let gate = RenderWorkGate(limit: 3)
        let first = try await gate.acquire(key: "same-cache")
        let blocked = expectation(description: "Same cache cannot publish concurrently")
        blocked.isInverted = true
        let other = try await gate.acquire(key: "other-cache")
        let waiter = Task {
            let token = try await gate.acquire(key: "same-cache")
            blocked.fulfill()
            await gate.release(token)
        }
        await fulfillment(of: [blocked], timeout: 0.1)
        waiter.cancel()
        _ = try? await waiter.value
        await gate.release(first)
        await gate.release(other)
        let next = try await gate.acquire(key: "same-cache")
        await gate.release(next)
    }

    func testConcurrentCacheRequestsReuseOnePublication() async throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Opt-in hardware generation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let plan = try RenderPlan(parent: parent)
        let first = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        let second = try BlankRangeCache(root: root, ocf: parent.ocf, plan: plan)
        let gaps = [0..<12, 24..<36, 48..<60, 72..<84]
        async let a = first.ranges(for: gaps, progress: nil)
        async let b = second.ranges(for: gaps, progress: nil)
        let (left, right) = try await (a, b)
        XCTAssertEqual(left.map(\.segment.url), right.map(\.segment.url))
        XCTAssertEqual(first.generatedFrames + second.generatedFrames, 48)
        XCTAssertEqual(first.reusedFrames + second.reusedFrames, 48)
        let entries = try JSONDecoder().decode([BlankRangeCache.Entry].self,
            from: Data(contentsOf: first.directory.appendingPathComponent("ranges.json")))
        XCTAssertEqual(entries.count, 4)
        for entry in entries { try await first.validate(url: first.directory.appendingPathComponent(entry.file), frames: entry.frames) }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: first.directory.path).contains { $0.hasPrefix(".pending-") })
    }

    func testCancellationPreservesManifestAndCleansParallelWork() async throws {
        guard ProcessInfo.processInfo.environment["SOURCEPRINT_BENCHMARK_ROOT"] != nil else {
            throw XCTSkip("Opt-in hardware generation")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = RenderPlanTests()
        let parent = helper.parent([helper.file("grade.mov", start: 90400, frames: 200)])
        let cache = try BlankRangeCache(root: root, ocf: parent.ocf, plan: RenderPlan(parent: parent))
        _ = try await cache.ranges(for: 0..<2, progress: nil)
        let manifest = cache.directory.appendingPathComponent("ranges.json")
        let before = try Data(contentsOf: manifest)
        let started = expectation(description: "Workers started encoding")
        started.assertForOverFulfill = false
        let work = Task {
            try await cache.ranges(for: [2..<400, 600..<1000], progress: { _, _, _, _ in started.fulfill() })
        }
        await fulfillment(of: [started], timeout: 10)
        work.cancel()
        do { _ = try await work.value; XCTFail("Cancelled generation succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try Data(contentsOf: manifest), before)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".mov") }.count, 1)
        XCTAssertFalse(files.contains { $0.hasPrefix(".pending-") })
        // A cancelled transaction must not retain either its cache or worker permits.
        let retry = try await cache.ranges(for: [2..<4, 600..<602], progress: nil)
        XCTAssertEqual(retry.map(\.frameCount), [2, 2])
    }
}
