import XCTest
@testable import SourcePrintCore

final class VideoFileDiscoveryTests: XCTestCase {

    // MARK: - Test Helpers

    /// Create a temporary directory with specified file structure
    private func createTestDirectory(with files: [String]) -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let testDir = tempDir.appendingPathComponent(UUID().uuidString)

        try! FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        for filePath in files {
            let fileURL = testDir.appendingPathComponent(filePath)

            // Create parent directories if needed
            let parentDir = fileURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try! FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }

            // Create file
            try! "test content".write(to: fileURL, atomically: true, encoding: .utf8)
        }

        return testDir
    }

    // MARK: - isVideoFile Tests

    func testIsVideoFile_MOV() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.mov")))
    }

    func testIsVideoFile_MP4() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.mp4")))
    }

    func testIsVideoFile_M4V() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.m4v")))
    }

    func testIsVideoFile_MXF() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.mxf")))
    }

    func testIsVideoFile_CaseInsensitive() {
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.MOV")))
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.MP4")))
        XCTAssertTrue(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.MxF")))
    }

    func testIsVideoFile_NonVideoExtension() {
        XCTAssertFalse(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.txt")))
        XCTAssertFalse(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.jpg")))
        XCTAssertFalse(VideoFileDiscovery.isVideoFile(URL(fileURLWithPath: "test.pdf")))
    }

    // MARK: - discoverVideoFiles Tests

    func testDiscoverVideoFiles_EmptyDirectory() async throws {
        let testDir = createTestDirectory(with: [])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 0, "Should find no video files in empty directory")
    }

    func testDiscoverVideoFiles_OnlyVideoFiles() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            "video2.mp4",
            "video3.m4v"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 3, "Should find 3 video files")
        XCTAssertTrue(videoFiles.allSatisfy { VideoFileDiscovery.isVideoFile($0) })
    }

    func testDiscoverVideoFiles_MixedFiles() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            "document.txt",
            "video2.mp4",
            "image.jpg",
            "data.json"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 2, "Should find only 2 video files")
        XCTAssertTrue(videoFiles.contains { $0.lastPathComponent == "video1.mov" })
        XCTAssertTrue(videoFiles.contains { $0.lastPathComponent == "video2.mp4" })
    }

    func testDiscoverVideoFiles_RecursiveSubdirectories() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            "subfolder1/video2.mp4",
            "subfolder1/document.txt",
            "subfolder2/video3.mxf",
            "subfolder2/nested/video4.m4v"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 4, "Should find 4 video files recursively")
        XCTAssertTrue(videoFiles.allSatisfy { VideoFileDiscovery.isVideoFile($0) })
    }

    func testDiscoverVideoFiles_SortedOutput() async throws {
        let testDir = createTestDirectory(with: [
            "zebra.mov",
            "apple.mp4",
            "banana.mxf"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir)

        XCTAssertEqual(videoFiles.count, 3)
        XCTAssertEqual(videoFiles[0].lastPathComponent, "apple.mp4")
        XCTAssertEqual(videoFiles[1].lastPathComponent, "banana.mxf")
        XCTAssertEqual(videoFiles[2].lastPathComponent, "zebra.mov")
    }

    func testDiscoverVideoFiles_HiddenFiles_Skipped() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            ".hidden_video.mp4",
            "video2.mxf"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir, skipHidden: true)

        XCTAssertEqual(videoFiles.count, 2, "Should skip hidden files")
        XCTAssertFalse(videoFiles.contains { $0.lastPathComponent == ".hidden_video.mp4" })
    }

    func testDiscoverVideoFiles_HiddenFiles_Included() async throws {
        let testDir = createTestDirectory(with: [
            "video1.mov",
            ".hidden_video.mp4",
            "video2.mxf"
        ])
        defer { try? FileManager.default.removeItem(at: testDir) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: testDir, skipHidden: false)

        XCTAssertEqual(videoFiles.count, 3, "Should include hidden files when skipHidden is false")
        XCTAssertTrue(videoFiles.contains { $0.lastPathComponent == ".hidden_video.mp4" })
    }

    func testDiscoverVideoFiles_NonExistentDirectory() async throws {
        let nonExistentDir = URL(fileURLWithPath: "/tmp/nonexistent_\(UUID().uuidString)")

        do {
            _ = try await VideoFileDiscovery.discoverVideoFiles(in: nonExistentDir)
            XCTFail("Should throw error for non-existent directory")
        } catch let error as VideoFileDiscoveryError {
            switch error {
            case .directoryNotAccessible(let url):
                XCTAssertEqual(url, nonExistentDir)
            default:
                XCTFail("Expected directoryNotAccessible error")
            }
        } catch {
            XCTFail("Expected VideoFileDiscoveryError, got \(error)")
        }
    }

    // MARK: - discoverVideoFiles (Multiple Directories) Tests

    func testDiscoverVideoFiles_MultipleDirectories() async throws {
        let testDir1 = createTestDirectory(with: [
            "video1.mov",
            "video2.mp4"
        ])
        defer { try? FileManager.default.removeItem(at: testDir1) }

        let testDir2 = createTestDirectory(with: [
            "video3.mxf",
            "video4.m4v"
        ])
        defer { try? FileManager.default.removeItem(at: testDir2) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(
            in: [testDir1, testDir2]
        )

        XCTAssertEqual(videoFiles.count, 4, "Should find video files from both directories")
        XCTAssertTrue(videoFiles.allSatisfy { VideoFileDiscovery.isVideoFile($0) })
    }

    func testDiscoverVideoFiles_MultipleDirectories_Sorted() async throws {
        let testDir1 = createTestDirectory(with: [
            "zebra.mov"
        ])
        defer { try? FileManager.default.removeItem(at: testDir1) }

        let testDir2 = createTestDirectory(with: [
            "apple.mp4"
        ])
        defer { try? FileManager.default.removeItem(at: testDir2) }

        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(
            in: [testDir1, testDir2]
        )

        XCTAssertEqual(videoFiles.count, 2)
        // Should be sorted across all directories
        XCTAssertEqual(videoFiles[0].lastPathComponent, "apple.mp4")
        XCTAssertEqual(videoFiles[1].lastPathComponent, "zebra.mov")
    }

    func testDiscoverVideoFiles_EmptyDirectoriesArray() async throws {
        let videoFiles = try await VideoFileDiscovery.discoverVideoFiles(in: [])

        XCTAssertEqual(videoFiles.count, 0, "Should return empty array for empty input")
    }

    // MARK: - Extension Support Tests

    func testVideoExtensions_Contains_StandardFormats() {
        XCTAssertTrue(VideoFileDiscovery.videoExtensions.contains("mov"))
        XCTAssertTrue(VideoFileDiscovery.videoExtensions.contains("mp4"))
        XCTAssertTrue(VideoFileDiscovery.videoExtensions.contains("m4v"))
        XCTAssertTrue(VideoFileDiscovery.videoExtensions.contains("mxf"))
        XCTAssertEqual(VideoFileDiscovery.videoExtensions, ["mov", "mp4", "m4v", "mxf", "avi", "mkv", "avp"])
    }
}
