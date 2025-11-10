import Foundation

/// Validation warnings and errors for project loading
public enum ProjectValidationIssue: Identifiable, Equatable {
    case missingOutputDirectory(URL)
    case missingBlankRushDirectory(URL)
    case missingOCFFile(String, URL)
    case missingSegmentFile(String, URL)
    case invalidLinkingResult(String)
    case corruptedBlankRushStatus
    case invalidTimecodeRange(String)

    public var id: String {
        switch self {
        case .missingOutputDirectory(let url):
            return "missing-output-\(url.path)"
        case .missingBlankRushDirectory(let url):
            return "missing-blank-rush-\(url.path)"
        case .missingOCFFile(let name, let url):
            return "missing-ocf-\(name)-\(url.path)"
        case .missingSegmentFile(let name, let url):
            return "missing-segment-\(name)-\(url.path)"
        case .invalidLinkingResult(let reason):
            return "invalid-linking-\(reason)"
        case .corruptedBlankRushStatus:
            return "corrupted-blank-rush"
        case .invalidTimecodeRange(let name):
            return "invalid-timecode-\(name)"
        }
    }

    public var severity: ValidationSeverity {
        switch self {
        case .missingOutputDirectory, .missingBlankRushDirectory:
            return .warning // Can be recreated
        case .missingOCFFile, .missingSegmentFile:
            return .error // Critical media files
        case .invalidLinkingResult, .corruptedBlankRushStatus, .invalidTimecodeRange:
            return .warning // Can be recalculated
        }
    }

    public var message: String {
        switch self {
        case .missingOutputDirectory(let url):
            return "Output directory not found: \(url.path)"
        case .missingBlankRushDirectory(let url):
            return "Blank rush directory not found: \(url.path)"
        case .missingOCFFile(let name, let url):
            return "OCF file '\(name)' not found at: \(url.path)"
        case .missingSegmentFile(let name, let url):
            return "Segment file '\(name)' not found at: \(url.path)"
        case .invalidLinkingResult(let reason):
            return "Linking result invalid: \(reason)"
        case .corruptedBlankRushStatus:
            return "Blank rush status data is corrupted"
        case .invalidTimecodeRange(let name):
            return "Invalid timecode range for: \(name)"
        }
    }

    public var recoveryAction: String {
        switch self {
        case .missingOutputDirectory:
            return "The output directory will be recreated on next print"
        case .missingBlankRushDirectory:
            return "The blank rush directory will be recreated when needed"
        case .missingOCFFile, .missingSegmentFile:
            return "Re-import the media file or remove it from the project"
        case .invalidLinkingResult:
            return "Re-run the linking process"
        case .corruptedBlankRushStatus:
            return "Blank rushes will need to be regenerated"
        case .invalidTimecodeRange:
            return "Check the media file properties"
        }
    }
}

public enum ValidationSeverity {
    case warning  // Project can function but with limitations
    case error    // Critical issue that prevents normal operation
}

/// Validation result containing all issues found
public struct ProjectValidationResult {
    public let issues: [ProjectValidationIssue]

    public init(issues: [ProjectValidationIssue]) {
        self.issues = issues
    }

    public var isValid: Bool {
        issues.isEmpty
    }

    public var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    public var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    public var errors: [ProjectValidationIssue] {
        issues.filter { $0.severity == .error }
    }

    public var warnings: [ProjectValidationIssue] {
        issues.filter { $0.severity == .warning }
    }
}

/// Service for validating project data integrity
public struct ProjectValidator {

    /// Validates a project model after loading from disk
    public static func validate(_ model: ProjectModel) -> ProjectValidationResult {
        var issues: [ProjectValidationIssue] = []

        // Validate directories
        issues.append(contentsOf: validateDirectories(model))

        // Validate media files
        issues.append(contentsOf: validateMediaFiles(model))

        // Validate linking result
        issues.append(contentsOf: validateLinkingResult(model))

        // Validate blank rush status
        issues.append(contentsOf: validateBlankRushStatus(model))

        return ProjectValidationResult(issues: issues)
    }

    // MARK: - Private Validation Methods

    private static func validateDirectories(_ model: ProjectModel) -> [ProjectValidationIssue] {
        var issues: [ProjectValidationIssue] = []

        // Check output directory
        if !FileManager.default.fileExists(atPath: model.outputDirectory.path) {
            issues.append(.missingOutputDirectory(model.outputDirectory))
        }

        // Check blank rush directory
        if !FileManager.default.fileExists(atPath: model.blankRushDirectory.path) {
            issues.append(.missingBlankRushDirectory(model.blankRushDirectory))
        }

        return issues
    }

    private static func validateMediaFiles(_ model: ProjectModel) -> [ProjectValidationIssue] {
        var issues: [ProjectValidationIssue] = []

        // Validate OCF files
        for ocfFile in model.ocfFiles {
            if !FileManager.default.fileExists(atPath: ocfFile.url.path) {
                issues.append(.missingOCFFile(ocfFile.fileName, ocfFile.url))
            }

            // Validate timecode range if present
            if let startTimecode = ocfFile.sourceTimecode,
               let endTimecode = ocfFile.endTimecode,
               startTimecode >= endTimecode {
                issues.append(.invalidTimecodeRange(ocfFile.fileName))
            }
        }

        // Validate segment files
        for segment in model.segments {
            if !FileManager.default.fileExists(atPath: segment.url.path) {
                issues.append(.missingSegmentFile(segment.fileName, segment.url))
            }

            // Validate timecode range if present
            if let startTimecode = segment.sourceTimecode,
               let endTimecode = segment.endTimecode,
               startTimecode >= endTimecode {
                issues.append(.invalidTimecodeRange(segment.fileName))
            }
        }

        return issues
    }

    private static func validateLinkingResult(_ model: ProjectModel) -> [ProjectValidationIssue] {
        var issues: [ProjectValidationIssue] = []

        guard let linkingResult = model.linkingResult else {
            return issues // No linking result yet is valid
        }

        // Validate that linked segments still exist in project
        for ocfParent in linkingResult.ocfParents {
            let ocfExists = model.ocfFiles.contains { $0.fileName == ocfParent.ocf.fileName }
            if !ocfExists {
                issues.append(.invalidLinkingResult("OCF '\(ocfParent.ocf.fileName)' no longer in project"))
            }

            for linkedSegment in ocfParent.children {
                let segmentExists = model.segments.contains { $0.fileName == linkedSegment.segment.fileName }
                if !segmentExists {
                    issues.append(.invalidLinkingResult("Segment '\(linkedSegment.segment.fileName)' no longer in project"))
                }
            }
        }

        return issues
    }

    private static func validateBlankRushStatus(_ model: ProjectModel) -> [ProjectValidationIssue] {
        var issues: [ProjectValidationIssue] = []

        // Validate blank rush status references valid OCF files
        for (ocfFileName, status) in model.blankRushStatus {
            let ocfExists = model.ocfFiles.contains { $0.fileName == ocfFileName }
            if !ocfExists {
                issues.append(.corruptedBlankRushStatus)
                break // Only report once
            }

            // Validate blank rush file exists if status is completed
            if case .completed(_, let url) = status {
                if !FileManager.default.fileExists(atPath: url.path) {
                    issues.append(.corruptedBlankRushStatus)
                    break // Only report once
                }
            }
        }

        return issues
    }
}
