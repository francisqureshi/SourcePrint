import XCTest
@testable import SourcePrintCore

final class MediaImportSelectionTests: XCTestCase {
    func testMixedSelectionsDeduplicatePathsButPreserveSameNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["one/clip.mov", "two/clip.mov", "two/grade.mov", "notes.txt", ".hidden.mov"] {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        let result = await MediaImportSelection.discover([
            root, root.appendingPathComponent("one/clip.mov"), root.appendingPathComponent("two"),
            root.appendingPathComponent("notes.txt"), root.appendingPathComponent("missing.mov")
        ])
        XCTAssertEqual(Set(result.files.map(\.standardizedFileURL)), Set([
            root.appendingPathComponent("one/clip.mov"), root.appendingPathComponent("two/clip.mov"),
            root.appendingPathComponent("two/grade.mov")
        ].map(\.standardizedFileURL)))
        XCTAssertTrue(result.notices.contains { $0.contains("unsupported") })
        XCTAssertTrue(result.notices.contains { $0.contains("missing.mov") })
        XCTAssertTrue(result.notices.contains { $0.contains("repeated") })
    }

    func testEmptyFolderAndNonFileURLHaveUsefulFeedback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await MediaImportSelection.discover([root, URL(string: "https://example.com/clip.mov")!])
        XCTAssertTrue(result.files.isEmpty)
        XCTAssertEqual(result.notices.count, 2)
    }
}
