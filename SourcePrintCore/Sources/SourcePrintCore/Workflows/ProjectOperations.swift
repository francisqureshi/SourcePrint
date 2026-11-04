import Foundation

/// Result of project operations containing data changes
public struct ProjectOperationResult {
    /// Updated OCF files array
    public let ocfFiles: [MediaFileInfo]?

    /// Updated segments array
    public let segments: [MediaFileInfo]?

    /// Updated segment modification dates
    public let segmentModificationDates: [String: Date]?

    /// Updated segment file sizes
    public let segmentFileSizes: [String: Int64]?

    /// Updated offline files set
    public let offlineFiles: Set<String>?

    /// Updated offline metadata
    public let offlineMetadata: [String: OfflineFileMetadata]?

    /// Updated print status
    public let printStatus: [String: String]?  // ocfFileName -> status description

    /// Updated blank rush status
    public let blankRushStatus: [String: String]?  // ocfFileName -> status description

    /// Linking result should be invalidated
    public let shouldInvalidateLinking: Bool

    /// Should trigger modified update
    public let shouldUpdateModified: Bool

    public init(
        ocfFiles: [MediaFileInfo]? = nil,
        segments: [MediaFileInfo]? = nil,
        segmentModificationDates: [String: Date]? = nil,
        segmentFileSizes: [String: Int64]? = nil,
        offlineFiles: Set<String>? = nil,
        offlineMetadata: [String: OfflineFileMetadata]? = nil,
        printStatus: [String: String]? = nil,
        blankRushStatus: [String: String]? = nil,
        shouldInvalidateLinking: Bool = false,
        shouldUpdateModified: Bool = false
    ) {
        self.ocfFiles = ocfFiles
        self.segments = segments
        self.segmentModificationDates = segmentModificationDates
        self.segmentFileSizes = segmentFileSizes
        self.offlineFiles = offlineFiles
        self.offlineMetadata = offlineMetadata
        self.printStatus = printStatus
        self.blankRushStatus = blankRushStatus
        self.shouldInvalidateLinking = shouldInvalidateLinking
        self.shouldUpdateModified = shouldUpdateModified
    }
}

/// Service for project data management operations
public class ProjectOperations {

    // MARK: - Add Operations

    /// Keep the first reference to each file, preserving import order and its metadata.
    public static func uniqueMediaFiles(_ files: [MediaFileInfo], excluding existing: [MediaFileInfo] = []) -> [MediaFileInfo] {
        var paths = Set(existing.map { $0.url.standardizedFileURL.path })
        return files.filter { paths.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// Add OCF files to project
    public static func addOCFFiles(
        _ newFiles: [MediaFileInfo],
        existingOCFs: [MediaFileInfo]
    ) -> ProjectOperationResult {
        let additions = uniqueMediaFiles(newFiles, excluding: existingOCFs)

        return ProjectOperationResult(
            ocfFiles: existingOCFs + additions,
            shouldUpdateModified: !additions.isEmpty
        )
    }

    /// Add segments to project with file size tracking
    public static func addSegments(
        _ newSegments: [MediaFileInfo],
        existingSegments: [MediaFileInfo],
        existingFileSizes: [String: Int64]
    ) -> ProjectOperationResult {
        let additions = uniqueMediaFiles(newSegments, excluding: existingSegments)

        var updatedSizes = existingFileSizes

        // Track file sizes for new segments
        for segment in additions {
            if case .success(let fileSize) = FileSystemOperations.getFileSize(for: segment.url) {
                updatedSizes[segment.fileName] = fileSize
                NSLog("📊 Stored size for segment: %@ (size: %lld bytes)", segment.fileName, fileSize)
            }
        }

        return ProjectOperationResult(
            segments: existingSegments + additions,
            segmentFileSizes: updatedSizes,
            shouldUpdateModified: !additions.isEmpty
        )
    }

    // MARK: - Remove Operations

    /// Remove OCF files by filename
    public static func removeOCFFiles(
        _ fileNames: [String],
        existingOCFs: [MediaFileInfo],
        existingBlankRushStatus: [String: String]
    ) -> ProjectOperationResult {
        let updated = existingOCFs.filter { !fileNames.contains($0.fileName) }

        var updatedBlankRushStatus = existingBlankRushStatus
        for fileName in fileNames {
            updatedBlankRushStatus.removeValue(forKey: fileName)
        }

        return ProjectOperationResult(
            ocfFiles: updated,
            blankRushStatus: updatedBlankRushStatus,
            shouldInvalidateLinking: true,
            shouldUpdateModified: true
        )
    }

    /// Remove segments by filename
    public static func removeSegments(
        _ fileNames: [String],
        existingSegments: [MediaFileInfo],
        existingModDates: [String: Date],
        existingFileSizes: [String: Int64],
        existingOfflineFiles: Set<String>
    ) -> ProjectOperationResult {
        let updated = existingSegments.filter { !fileNames.contains($0.fileName) }

        var updatedModDates = existingModDates
        var updatedFileSizes = existingFileSizes
        var updatedOfflineFiles = existingOfflineFiles

        for fileName in fileNames {
            updatedModDates.removeValue(forKey: fileName)
            updatedFileSizes.removeValue(forKey: fileName)
            updatedOfflineFiles.remove(fileName)
        }

        return ProjectOperationResult(
            segments: updated,
            segmentModificationDates: updatedModDates,
            segmentFileSizes: updatedFileSizes,
            offlineFiles: updatedOfflineFiles,
            shouldInvalidateLinking: true,
            shouldUpdateModified: true
        )
    }

    /// Remove all offline media files
    public static func removeOfflineMedia(
        offlineFiles: Set<String>,
        existingOCFs: [MediaFileInfo],
        existingSegments: [MediaFileInfo],
        existingModDates: [String: Date],
        existingFileSizes: [String: Int64],
        existingPrintStatus: [String: String],
        existingBlankRushStatus: [String: String],
        existingOfflineMetadata: [String: OfflineFileMetadata]
    ) -> ProjectOperationResult {
        NSLog("🗑️ Removing %d offline media files from project", offlineFiles.count)

        let updatedSegments = existingSegments.filter { !offlineFiles.contains($0.fileName) }
        let updatedOCFs = existingOCFs.filter { !offlineFiles.contains($0.fileName) }

        var updatedModDates = existingModDates
        var updatedFileSizes = existingFileSizes
        var updatedPrintStatus = existingPrintStatus
        var updatedBlankRushStatus = existingBlankRushStatus
        var updatedOfflineMetadata = existingOfflineMetadata

        for fileName in offlineFiles {
            updatedModDates.removeValue(forKey: fileName)
            updatedFileSizes.removeValue(forKey: fileName)
            updatedPrintStatus.removeValue(forKey: fileName)
            updatedBlankRushStatus.removeValue(forKey: fileName)
            updatedOfflineMetadata.removeValue(forKey: fileName)
        }

        NSLog("✅ Removed all offline media files")

        return ProjectOperationResult(
            ocfFiles: updatedOCFs,
            segments: updatedSegments,
            segmentModificationDates: updatedModDates,
            segmentFileSizes: updatedFileSizes,
            offlineFiles: Set(),
            offlineMetadata: updatedOfflineMetadata,
            printStatus: updatedPrintStatus,
            blankRushStatus: updatedBlankRushStatus,
            shouldInvalidateLinking: !offlineFiles.isEmpty,
            shouldUpdateModified: true
        )
    }

    // MARK: - Update Operations

    /// Toggle VFX status for OCF file
    public static func toggleOCFVFXStatus(
        _ fileName: String,
        isVFX: Bool,
        existingOCFs: [MediaFileInfo]
    ) -> ProjectOperationResult {
        var updated = existingOCFs

        if let index = updated.firstIndex(where: { $0.fileName == fileName }) {
            updated[index].isVFXShot = isVFX

            return ProjectOperationResult(
                ocfFiles: updated,
                shouldUpdateModified: true
            )
        }

        return ProjectOperationResult()
    }

    /// Toggle VFX status for segment file
    public static func toggleSegmentVFXStatus(
        _ fileName: String,
        isVFX: Bool,
        existingSegments: [MediaFileInfo]
    ) -> ProjectOperationResult {
        var updated = existingSegments

        if let index = updated.firstIndex(where: { $0.fileName == fileName }) {
            updated[index].isVFXShot = isVFX

            return ProjectOperationResult(
                segments: updated,
                shouldUpdateModified: true
            )
        }

        return ProjectOperationResult()
    }

    /// Refresh segment modification dates from filesystem
    public static func refreshSegmentModificationDates(
        existingSegments: [MediaFileInfo],
        existingModDates: [String: Date]
    ) -> ProjectOperationResult {
        var updatedModDates = existingModDates

        for segment in existingSegments {
            if case .success(let modDate) = FileSystemOperations.getModificationDate(for: segment.url) {
                updatedModDates[segment.fileName] = modDate
            }
        }

        return ProjectOperationResult(
            segmentModificationDates: updatedModDates,
            shouldUpdateModified: true
        )
    }

    /// Check for modified segments and mark OCFs for reprint
    public static func checkForModifiedSegments(
        linkingResult: LinkingResult?,
        existingPrintStatus: [String: (isPrinted: Bool, lastPrintDate: Date?, outputURL: URL?)]
    ) -> (needsReprint: [String: Date], statusChanged: Bool) {
        guard let linkingResult = linkingResult else {
            return ([:], false)
        }

        var needsReprint: [String: Date] = [:]
        var statusChanged = false

        for parent in linkingResult.parentsWithChildren {
            let ocfFileName = parent.ocf.fileName

            // Only check OCFs that have been printed
            guard let currentStatus = existingPrintStatus[ocfFileName],
                  currentStatus.isPrinted,
                  let lastPrintDate = currentStatus.lastPrintDate
            else {
                continue
            }

            // Check if any segments for this OCF have been modified since last print
            var hasModifiedSegments = false
            for child in parent.children {
                if case .success(let fileModDate) = FileSystemOperations.getModificationDate(for: child.segment.url),
                    fileModDate > lastPrintDate
                {
                    hasModifiedSegments = true
                    break
                }
            }

            // If segments have been modified, mark for re-print
            if hasModifiedSegments {
                needsReprint[ocfFileName] = lastPrintDate
                statusChanged = true
                NSLog(
                    "🔄 Auto-flagged \(ocfFileName) for re-print: segments modified since last print"
                )
            }
        }

        return (needsReprint, statusChanged)
    }
}
