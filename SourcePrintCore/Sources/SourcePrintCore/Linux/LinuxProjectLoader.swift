import Foundation

/// Cross-platform project loader for Linux CLI/server applications
/// Provides functionality to load and work with .w2 project files without SwiftUI dependencies
///
/// Example usage:
/// ```swift
/// let loader = LinuxProjectLoader()
/// let project = try loader.loadProject(from: URL(fileURLWithPath: "/path/to/project.w2"))
/// print("Project: \(project.model.name)")
/// print("OCF files: \(project.model.ocfFiles.count)")
/// ```
public struct LinuxProjectLoader {

    public init() {}

    // MARK: - Project Loading

    /// Load a .w2 project file and return the cross-platform container
    public func loadProject(from url: URL) throws -> ProjectContainer {
        return try ProjectContainer.load(from: url)
    }

    /// Load a .w2 project file and return only the core model (without UI state)
    public func loadProjectModel(from url: URL) throws -> ProjectModel {
        let container = try ProjectContainer.load(from: url)
        return container.model
    }

    // MARK: - Project Saving

    /// Save a project container to a .w2 file
    public func saveProject(_ container: ProjectContainer, to url: URL) throws {
        try container.save(to: url)
    }

    /// Save a project model to a .w2 file (creates default container)
    public func saveProjectModel(_ model: ProjectModel, to url: URL) throws {
        let container = ProjectContainer(model: model)
        try container.save(to: url)
    }

    // MARK: - Project Inspection

    /// Get project info without fully loading (quick metadata check)
    public func getProjectInfo(from url: URL) throws -> ProjectInfo {
        let container = try ProjectContainer.load(from: url)

        return ProjectInfo(
            name: container.model.name,
            createdDate: container.model.createdDate,
            lastModified: container.model.lastModified,
            ocfCount: container.model.ocfFiles.count,
            segmentCount: container.model.segments.count,
            hasLinkingResult: container.model.linkingResult != nil,
            fileFormatVersion: container.fileFormatVersion
        )
    }

    /// List all .w2 project files in a directory
    public func listProjects(in directory: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )

        return contents.filter { $0.pathExtension == "w2" }
    }
}

// MARK: - Project Info

/// Lightweight project metadata for quick inspection
public struct ProjectInfo {
    public let name: String
    public let createdDate: Date
    public let lastModified: Date
    public let ocfCount: Int
    public let segmentCount: Int
    public let hasLinkingResult: Bool
    public let fileFormatVersion: Int

    public var summary: String {
        """
        Project: \(name)
        Created: \(createdDate)
        Modified: \(lastModified)
        OCF Files: \(ocfCount)
        Segments: \(segmentCount)
        Linked: \(hasLinkingResult ? "Yes" : "No")
        Format Version: \(fileFormatVersion)
        """
    }
}

// MARK: - Example Linux CLI Usage

#if os(Linux)
/// Example command-line tool for Linux
/// Build with: swift build -c release
/// Run with: .build/release/sourceprint-cli project.w2
@main
struct SourcePrintCLI {
    static func main() async throws {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            print("Usage: sourceprint-cli <project.w2>")
            print("       sourceprint-cli list <directory>")
            print("       sourceprint-cli info <project.w2>")
            return
        }

        let loader = LinuxProjectLoader()
        let command = args[1]

        switch command {
        case "list":
            // List all projects in directory
            let directory = args.count > 2 ? URL(fileURLWithPath: args[2]) : URL(fileURLWithPath: ".")
            let projects = try loader.listProjects(in: directory)
            print("Found \(projects.count) project(s):")
            for project in projects {
                print("  - \(project.lastPathComponent)")
            }

        case "info":
            // Show project info
            guard args.count > 2 else {
                print("Error: Please specify a project file")
                return
            }
            let url = URL(fileURLWithPath: args[2])
            let info = try loader.getProjectInfo(from: url)
            print(info.summary)

        default:
            // Load and display project
            let url = URL(fileURLWithPath: command)
            let project = try loader.loadProject(from: url)

            print("Loaded project: \(project.model.name)")
            print("OCF Files: \(project.model.ocfFiles.count)")
            print("Segments: \(project.model.segments.count)")

            if let linkingResult = project.model.linkingResult {
                print("Linking: \(linkingResult.ocfParents.count) OCF parents with children")
            }

            // Example: Process project data
            for ocfFile in project.model.ocfFiles {
                print("  - \(ocfFile.fileName): \(ocfFile.resolution?.description ?? "unknown resolution")")
            }
        }
    }
}
#endif
