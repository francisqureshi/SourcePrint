import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

// MARK: - Render Progress Delegate

/// Delegate protocol for render progress events
@MainActor
public protocol RenderProgressDelegate: AnyObject {
    /// Called when render progress updates occur
    func renderService(_ service: RenderService, didUpdateProgress progress: RenderProgress)
}

// MARK: - Render Service

/// Service for rendering OCF files with blank rush generation and composition
public class RenderService {

    // MARK: - Properties

    public weak var delegate: RenderProgressDelegate?

    /// Configuration for render operations
    private let configuration: RenderConfiguration

    // MARK: - Initialization

    public init(configuration: RenderConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Public API

    /// Render through a validated frame plan. A complete grade is copied unchanged;
    /// other jobs reuse full blanks or generate only uncached blank frames.
    public func renderOCF(parent: OCFParent) async -> RenderResult {
        let started = Date()
        var fullBlankURL: URL?
        do {
            try Task.checkCancellation()
            let sourceURLs = [parent.ocf.url] + parent.children.map { $0.segment.url }
            let versions = sourceURLs.map { RenderOutputFingerprint.capture(at: $0) }
            try await SourceMediaRefresh.validateQueuedParent(parent)
            let refreshedOCF = try await SourceMediaRefresh.refresh(parent.ocf)
            guard refreshedOCF.durationInFrames == parent.ocf.durationInFrames,
                  refreshedOCF.sourceTimecode == parent.ocf.sourceTimecode,
                  refreshedOCF.resolution == parent.ocf.resolution,
                  refreshedOCF.isDropFrame == parent.ocf.isDropFrame,
                  refreshedOCF.effectiveDisplayResolution == parent.ocf.effectiveDisplayResolution,
                  refreshedOCF.frameRate?.num == parent.ocf.frameRate?.num,
                  refreshedOCF.frameRate?.den == parent.ocf.frameRate?.den else {
                throw RenderPlanningError.sourceChanged
            }
            guard zip(sourceURLs, versions).allSatisfy({ $0.1 != nil && RenderOutputFingerprint.capture(at: $0.0) == $0.1 }) else {
                throw RenderPlanningError.sourceChanged
            }
            let plan = try RenderPlan(parent: parent)
            let baseName = (parent.ocf.fileName as NSString).deletingPathExtension
            let outputURL = configuration.outputDirectory.appendingPathComponent("\(baseName).mov")
            guard !sourceURLs.contains(where: { sameFile($0, outputURL) }) else {
                throw RenderPlanningError.outputIsSource
            }
            if configuration.proResProfile != "4" {
                return await renderLegacyOCF(parent: parent)
            }
            try FileManager.default.createDirectory(at: configuration.outputDirectory, withIntermediateDirectories: true)
            let temporary = configuration.outputDirectory.appendingPathComponent(".\(UUID().uuidString).mov")
            defer { try? FileManager.default.removeItem(at: temporary) }
            for child in parent.children {
                guard try SwiftFFmpegProResCompositor.isProRes4444(at: child.segment.url) else {
                    throw RenderPlanningError.invalidSegment(child.segment.fileName + " (expected ProRes 4444)")
                }
            }
            if let source = plan.copySource, source.pathExtension.lowercased() == "mov" {
                await notifyProgress(ocfFileName: parent.ocf.fileName, status: .compositing,
                    message: "Copying full-length grade unchanged…")
                try FileManager.default.copyItem(at: source, to: temporary)
                try Task.checkCancellation()
                guard try checksum(source) == checksum(temporary) else { throw RenderPlanningError.incompleteMedia }
            } else {
                let cache = try BlankRangeCache(root: configuration.blankRushDirectory, ocf: parent.ocf, plan: plan)
                var ranges = plan.grades
                if !plan.gaps.isEmpty {
                    let existing = configuration.blankRushDirectory.appendingPathComponent("\(baseName)_blankRush.mov")
                    if await cache.validFullBlank(at: existing) {
                        fullBlankURL = existing
                        ranges += plan.gaps.map { cache.range(url: existing, frames: $0, offset: $0.lowerBound) }
                    } else {
                        await notifyProgress(ocfFileName: parent.ocf.fileName, status: .generatingBlankRush,
                            message: "Preparing blank frames…")
                        ranges += try await cache.ranges(for: plan.gaps, progress: { [weak self] _, current, total, _ in
                            await self?.notifyProgress(ocfFileName: parent.ocf.fileName, status: .generatingBlankRush,
                                message: "Creating blank gaps…", currentItemFramesProcessed: Int64(current),
                                currentItemTotalFrames: Int64(total))
                        })
                    }
                }
                NSLog("Render plan: %d blank frames generated, %d cached frames reused", cache.generatedFrames, cache.reusedFrames)
                ranges.sort { $0.startFrame < $1.startFrame }
                await notifyProgress(ocfFileName: parent.ocf.fileName, status: .compositing,
                    message: "Assembling graded and blank frames…")
                let compositor = SwiftFFmpegProResCompositor()
                compositor.segmentProgressHandler = { [weak self] index, total, name, progress, frames, totalFrames in
                    Task { @MainActor in
                        await self?.notifySegmentProgress(ocfFileName: parent.ocf.fileName, currentSegment: index,
                            totalSegments: total, segmentName: name, progress: progress,
                            framesProcessed: frames, totalFrames: totalFrames)
                    }
                }
                let rangeVersions = ranges.map { RenderOutputFingerprint.capture(at: $0.segment.url) }
                try await compositor.composeRanges(ranges, properties: plan.properties,
                    totalFrames: plan.totalFrames, outputURL: temporary, headerSource: parent.children[0].segment.url)
                try await cache.validate(url: temporary, frames: 0..<plan.totalFrames)
                guard zip(ranges, rangeVersions).allSatisfy({ $0.1 != nil && RenderOutputFingerprint.capture(at: $0.0.segment.url) == $0.1 }) else {
                    throw RenderPlanningError.sourceChanged
                }
            }
            try Task.checkCancellation()
            guard zip(sourceURLs, versions).allSatisfy({ RenderOutputFingerprint.capture(at: $0.0) == $0.1 }) else {
                throw RenderPlanningError.sourceChanged
            }
            // Atomic replacement within the output directory preserves the previous output on failure.
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: outputURL)
            }
            return RenderResult(ocfFileName: parent.ocf.fileName, ocfURL: parent.ocf.url, success: true,
                outputURL: outputURL, duration: Date().timeIntervalSince(started), segmentCount: parent.children.count,
                blankRushURL: fullBlankURL, outputFingerprint: RenderOutputFingerprint.capture(at: outputURL))
        } catch {
            return RenderResult(ocfFileName: parent.ocf.fileName, ocfURL: parent.ocf.url, success: false,
                error: Task.isCancelled ? "Render cancelled" : error.localizedDescription,
                duration: Date().timeIntervalSince(started), segmentCount: parent.children.count,
                cancelled: Task.isCancelled || error is CancellationError)
        }
    }

    private func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath() == b.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let x = try? RenderOutputFingerprint.fileSnapshot(at: a),
              let y = try? RenderOutputFingerprint.fileSnapshot(at: b) else { return false }
        return x.device == y.device && x.fingerprint.fileNumber == y.fingerprint.fileNumber
    }

    private func checksum(_ url: URL) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize()
    }

    /// Render an OCF file (generates blank rush if needed, then composes video)
    func renderLegacyOCF(parent: OCFParent) async -> RenderResult {
        let startTime = Date()

        NSLog("🎬 Starting render for \(parent.ocf.fileName)")

        do {
            try await SourceMediaRefresh.validateQueuedParent(parent)
        } catch {
            return RenderResult(ocfFileName: parent.ocf.fileName, ocfURL: parent.ocf.url,
                                success: false, error: error.localizedDescription,
                                duration: Date().timeIntervalSince(startTime), segmentCount: parent.children.count)
        }

        // Step 1: Check/generate blank rush
        let blankRushResult = await ensureBlankRush(for: parent)

        guard !Task.isCancelled, blankRushResult.success, let blankRushURL = blankRushResult.url else {
            let duration = Date().timeIntervalSince(startTime)
            return RenderResult(
                ocfFileName: parent.ocf.fileName,
                ocfURL: parent.ocf.url,
                success: false,
                outputURL: nil,
                error: Task.isCancelled ? "Render cancelled" : blankRushResult.error ?? "Failed to create blank rush",
                duration: duration,
                segmentCount: parent.children.count,
                cancelled: Task.isCancelled
            )
        }

        // Blank-rush generation can take time; check queued sources again before composition.
        do {
            try await SourceMediaRefresh.validateQueuedParent(parent)
        } catch {
            return RenderResult(ocfFileName: parent.ocf.fileName, ocfURL: parent.ocf.url,
                                success: false, error: error.localizedDescription,
                                duration: Date().timeIntervalSince(startTime), segmentCount: parent.children.count)
        }
        let sourceVersions = parent.children.map { RenderOutputFingerprint.capture(at: $0.segment.url) }

        // Step 2: Compose video
        let compositionResult = await composeVideo(
            parent: parent,
            blankRushURL: blankRushURL
        )

        let sourcesChanged = zip(parent.children, sourceVersions).contains {
            RenderOutputFingerprint.capture(at: $0.0.segment.url) != $0.1
        }
        let totalDuration = Date().timeIntervalSince(startTime)

        return RenderResult(
            ocfFileName: parent.ocf.fileName,
            ocfURL: parent.ocf.url,
            success: compositionResult.success && !Task.isCancelled && !sourcesChanged,
            outputURL: compositionResult.url,
            error: Task.isCancelled ? "Render cancelled" : sourcesChanged ? "A graded source changed during rendering. Refresh and render again." : compositionResult.error,
            duration: totalDuration,
            segmentCount: parent.children.count,
            blankRushURL: blankRushURL,
            cancelled: Task.isCancelled,
            outputFingerprint: compositionResult.success && !Task.isCancelled && !sourcesChanged
                ? compositionResult.url.flatMap { RenderOutputFingerprint.capture(at: $0) } : nil
        )
    }

    // MARK: - Blank Rush Management

    /// Ensure blank rush exists (check or create)
    private func ensureBlankRush(for parent: OCFParent) async -> (
        success: Bool, url: URL?, error: String?
    ) {
        // Strip extension and add _blankRush.mov (matches BlankRushIntermediate naming)
        let baseName = (parent.ocf.fileName as NSString).deletingPathExtension
        let expectedURL = configuration.blankRushDirectory
            .appendingPathComponent("\(baseName)_blankRush.mov")

        // Check if blank rush already exists
        if FileManager.default.fileExists(atPath: expectedURL.path) {
            // Verify it's valid
            let isValid = await isValidBlankRush(at: expectedURL)
            if isValid {
                NSLog("✅ Using existing blank rush: \(expectedURL.lastPathComponent)")
                return (true, expectedURL, nil)
            } else {
                NSLog(
                    "⚠️ Existing blank rush invalid, regenerating: \(expectedURL.lastPathComponent)")
                try? FileManager.default.removeItem(at: expectedURL)
            }
        }

        // Generate new blank rush
        return await generateBlankRush(for: parent)
    }

    /// Validate blank rush file
    private func isValidBlankRush(at url: URL) async -> Bool {
        // Use MediaAnalyzer to check if file is valid
        let analyzer = MediaAnalyzer()
        do {
            _ = try await analyzer.analyzeMediaFile(at: url, type: .originalCameraFile)
            return true
        } catch {
            return false
        }
    }

    /// Generate blank rush for OCF
    private func generateBlankRush(for parent: OCFParent) async -> (
        success: Bool, url: URL?, error: String?
    ) {
        NSLog("📝 Generating blank rush for \(parent.ocf.fileName)")

        // Update progress
        await notifyProgress(
            ocfFileName: parent.ocf.fileName,
            status: .generatingBlankRush,
            message: "Creating blank rush..."
        )

        // Create single-file linking result
        let singleOCFResult = LinkingResult(
            ocfParents: [parent],
            unmatchedSegments: [],
            unmatchedOCFs: []
        )

        let blankRushCreator = BlankRushIntermediate(
            projectDirectory: configuration.blankRushDirectory.path
        )

        // Create blank rush with progress callback
        let results = await blankRushCreator.createBlankRushes(
            from: singleOCFResult
        ) { [weak self] clipName, current, total, fps in
            guard let self = self else { return }
            let percentage = (current / total) * 100
            await self.notifyProgress(
                ocfFileName: parent.ocf.fileName,
                status: .generatingBlankRush,
                message: "Creating blank rush... \(Int(percentage))% @ \(Int(fps)) fps",
                currentItemFramesProcessed: Int64(current),
                currentItemTotalFrames: Int64(total)
            )
        }

        // Process result
        guard let result = results.first else {
            return (false, nil, "No blank rush result returned")
        }

        if result.success {
            NSLog("✅ Created blank rush: \(result.blankRushURL.lastPathComponent)")
            return (true, result.blankRushURL, nil)
        } else {
            let errorMessage = result.error ?? "Unknown error"
            NSLog("❌ Failed to create blank rush: \(errorMessage)")
            return (false, nil, errorMessage)
        }
    }

    // MARK: - Video Composition

    /// Compose video using SwiftFFmpeg
    private func composeVideo(
        parent: OCFParent,
        blankRushURL: URL
    ) async -> (success: Bool, url: URL?, error: String?) {
        NSLog("🎨 Composing video for \(parent.ocf.fileName)")

        // Update progress
        await notifyProgress(
            ocfFileName: parent.ocf.fileName,
            status: .compositing,
            message: "Printing Segments on to Blank Rush..."
        )

        // Generate output filename
        let baseName = (parent.ocf.fileName as NSString).deletingPathExtension
        let outputFileName = "\(baseName).mov"
        let outputURL = configuration.outputDirectory.appendingPathComponent(outputFileName)

        // Convert linked children to FFmpegGradedSegments
        let ffmpegSegments = await convertToFFmpegSegments(parent: parent)

        guard !ffmpegSegments.isEmpty else {
            let error = "No valid segments for composition"
            NSLog("❌ \(error)")
            return (false, nil, error)
        }

        // Create compositor settings
        let settings = FFmpegCompositorSettings(
            outputURL: outputURL,
            baseVideoURL: blankRushURL,
            gradedSegments: ffmpegSegments,
            proResProfile: configuration.proResProfile
        )

        // Execute composition
        let compositor = SwiftFFmpegProResCompositor()

        // Wire up segment progress callback
        compositor.segmentProgressHandler = {
            [weak self]
            currentSegment, totalSegments, segmentName, progress, framesProcessed, totalFrames in
            guard let self = self else { return }
            Task { @MainActor in
                await self.notifySegmentProgress(
                    ocfFileName: parent.ocf.fileName,
                    currentSegment: currentSegment,
                    totalSegments: totalSegments,
                    segmentName: segmentName,
                    progress: progress,
                    framesProcessed: framesProcessed,
                    totalFrames: totalFrames
                )
            }
        }

        let result = await withCheckedContinuation { continuation in
            compositor.completionHandler = { result in
                continuation.resume(returning: result)
            }
            compositor.composeVideo(with: settings)
        }

        // Process result
        switch result {
        case .success(let finalOutputURL):
            NSLog("✅ Composition completed: \(finalOutputURL.lastPathComponent)")
            return (true, finalOutputURL, nil)

        case .failure(let error):
            NSLog("❌ Composition failed: \(error.localizedDescription)")
            return (false, nil, error.localizedDescription)
        }
    }

    /// Convert LinkedSegments to FFmpegGradedSegments
    private func convertToFFmpegSegments(parent: OCFParent) async -> [FFmpegGradedSegment] {
        var ffmpegGradedSegments: [FFmpegGradedSegment] = []

        guard let baseTC = parent.ocf.sourceTimecode else {
            NSLog("⚠️ OCF missing source timecode: \(parent.ocf.fileName)")
            return []
        }

        for child in parent.children {
            let segmentInfo = child.segment

            guard let segmentTC = segmentInfo.sourceTimecode,
                let segmentFrameRate = segmentInfo.frameRate,
                let segmentFrameRateFloat = segmentInfo.effectiveFrameRateFloat,
                let duration = segmentInfo.durationInFrames
            else {
                NSLog("⚠️ Segment missing required fields: \(segmentInfo.fileName)")
                continue
            }

            // 🚀 PERFORMANCE OPTIMIZATION: Use pre-computed frame numbers instead of SMPTE calls
            guard let segmentStartFrame = segmentInfo.effectiveStartFrame,
                let baseStartFrame = parent.ocf.effectiveStartFrame
            else {
                NSLog("⚠️ Missing pre-computed frame numbers for segment: \(segmentInfo.fileName)")
                continue
            }

            let relativeFrames = segmentStartFrame - baseStartFrame

            // Create CMTime values
            let startTime = CMTime(
                value: CMTimeValue(relativeFrames),
                timescale: CMTimeScale(segmentFrameRateFloat)
            )

            let segmentDuration = CMTime(
                seconds: Double(duration) / Double(segmentFrameRateFloat),
                preferredTimescale: CMTimeScale(segmentFrameRateFloat * 1000)
            )

            // Create FFmpeg segment
            let ffmpegSegment = FFmpegGradedSegment(
                url: segmentInfo.url,
                startTime: startTime,
                duration: segmentDuration,
                sourceStartTime: .zero,
                isVFXShot: segmentInfo.isVFXShot ?? false,
                sourceTimecode: segmentInfo.sourceTimecode,
                frameRate: segmentFrameRateFloat,
                frameRateRational: segmentFrameRate,
                isDropFrame: segmentInfo.isDropFrame
            )

            ffmpegGradedSegments.append(ffmpegSegment)
        }

        NSLog("📊 Converted \(ffmpegGradedSegments.count) segments for composition")
        return ffmpegGradedSegments
    }

    // MARK: - Progress Notifications

    /// Notify delegate of progress update
    @MainActor
    private func notifyProgress(
        ocfFileName: String,
        status: RenderStatus,
        message: String,
        currentItemFramesProcessed: Int64? = nil,
        currentItemTotalFrames: Int64? = nil
    ) async {
        let progress = RenderProgress(
            ocfFileName: ocfFileName,
            status: status,
            message: message,
            percentage: nil,
            elapsedTime: nil,
            currentItemFramesProcessed: currentItemFramesProcessed,
            currentItemTotalFrames: currentItemTotalFrames
        )

        delegate?.renderService(self, didUpdateProgress: progress)
    }

    /// Notify delegate of segment-level progress
    private func notifySegmentProgress(
        ocfFileName: String,
        currentSegment: Int,
        totalSegments: Int,
        segmentName: String,
        progress: String,
        framesProcessed: Int64? = nil,
        totalFrames: Int? = nil
    ) async {
        // Parse percentage and FPS from progress string (e.g., "45.2% @ 145 fps")
        let percentage: Double?
        var message = "Processing segment \(currentSegment) of \(totalSegments)"

        // Extract percentage (before "@" if present)
        if let separatorIndex = progress.range(of: " @ ")?.lowerBound {
            let percentPart = String(progress[..<separatorIndex])
            let fpsPart = String(progress[progress.index(after: separatorIndex)...])

            // Parse percentage
            if let percentValue = Double(
                percentPart.replacingOccurrences(of: "%", with: "").trimmingCharacters(
                    in: .whitespaces))
            {
                percentage = percentValue
            } else {
                percentage = nil
            }

            // Include FPS in message
            message = "Processing segment \(currentSegment) of \(totalSegments) \(fpsPart)"
        } else {
            // No FPS info, just parse percentage
            if let percentValue = Double(
                progress.replacingOccurrences(of: "%", with: "").trimmingCharacters(
                    in: .whitespaces))
            {
                percentage = percentValue
            } else {
                percentage = nil
            }
        }

        let renderProgress = RenderProgress(
            ocfFileName: ocfFileName,
            status: .compositing,
            message: message,
            percentage: percentage,
            elapsedTime: nil,
            currentSegment: currentSegment,
            totalSegments: totalSegments,
            segmentName: segmentName,
            currentItemFramesProcessed: framesProcessed,
            currentItemTotalFrames: totalFrames.map { Int64($0) }
        )

        await MainActor.run {
            delegate?.renderService(self, didUpdateProgress: renderProgress)
        }
    }
}
