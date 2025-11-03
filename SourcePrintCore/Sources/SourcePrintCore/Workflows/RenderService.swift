import AVFoundation
import CoreMedia
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

    /// Render an OCF file (generates blank rush if needed, then composes video)
    public func renderOCF(parent: OCFParent) async -> RenderResult {
        let startTime = Date()

        NSLog("🎬 Starting render for \(parent.ocf.fileName)")

        // Step 1: Check/generate blank rush
        let blankRushResult = await ensureBlankRush(for: parent)

        guard blankRushResult.success, let blankRushURL = blankRushResult.url else {
            let duration = Date().timeIntervalSince(startTime)
            return RenderResult(
                ocfFileName: parent.ocf.fileName,
                success: false,
                outputURL: nil,
                error: blankRushResult.error ?? "Failed to create blank rush",
                duration: duration,
                segmentCount: parent.children.count
            )
        }

        // Step 2: Compose video
        let compositionResult = await composeVideo(
            parent: parent,
            blankRushURL: blankRushURL
        )

        let totalDuration = Date().timeIntervalSince(startTime)

        return RenderResult(
            ocfFileName: parent.ocf.fileName,
            success: compositionResult.success,
            outputURL: compositionResult.url,
            error: compositionResult.error,
            duration: totalDuration,
            segmentCount: parent.children.count,
            blankRushURL: blankRushURL
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
                message: "Creating blank rush... \(Int(percentage))% @ \(Int(fps)) fps"
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
            message: "Creating composition..."
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
                let segmentFrameRateFloat = segmentInfo.frameRateFloat,
                let duration = segmentInfo.durationInFrames
            else {
                NSLog("⚠️ Segment missing required fields: \(segmentInfo.fileName)")
                continue
            }

            let smpte = SMPTE(
                fps: Double(segmentFrameRateFloat),
                dropFrame: segmentInfo.isDropFrame ?? false
            )

            do {
                // Calculate relative frames
                let segmentFrames = try smpte.getFrames(tc: segmentTC)
                let baseFrames = try smpte.getFrames(tc: baseTC)
                let relativeFrames = segmentFrames - baseFrames

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

            } catch {
                NSLog("⚠️ SMPTE calculation failed for \(segmentInfo.fileName): \(error)")
                continue
            }
        }

        NSLog("📊 Converted \(ffmpegGradedSegments.count) segments for composition")
        return ffmpegGradedSegments
    }

    // MARK: - Progress Notifications

    /// Notify delegate of progress update
    @MainActor
    private func notifyProgress(ocfFileName: String, status: RenderStatus, message: String) async {
        let progress = RenderProgress(
            ocfFileName: ocfFileName,
            status: status,
            message: message,
            percentage: nil,
            elapsedTime: nil
        )

        delegate?.renderService(self, didUpdateProgress: progress)
    }
}
