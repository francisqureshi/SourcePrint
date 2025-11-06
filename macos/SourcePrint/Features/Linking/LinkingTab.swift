//
//  LinkingTab.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import SwiftUI
import SourcePrintCore

struct LinkingTab: View {
    let project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    @EnvironmentObject var statusBarVM: StatusBarViewModel
    @State private var isLinking = false
    @State private var timelineVisualizationData: [String: TimelineVisualization] = [:]
    
    var body: some View {
        VStack(spacing: 20) {
            // Linking Results Display
            LinkingResultsView(
                project: project,
                timelineVisualizationData: timelineVisualizationData,
                onPerformLinking: performLinking,
                onGenerateBlankRushes: generateBlankRushes
            )
            .environmentObject(projectManager)
        }
        .onAppear {
            generateTimelineVisualizationFromExistingData()
        }
    }

    private func generateTimelineVisualizationFromExistingData() {
        guard let linkingResult = project.model.linkingResult else { return }

        Task {
            var visualizationResults: [String: TimelineVisualization] = [:]

            for parent in linkingResult.parentsWithChildren {
                do {
                    let processingPlan = try await generateProcessingPlan(for: parent)

                    if let visualizationData = processingPlan.visualizationData {
                        visualizationResults[parent.ocf.fileName] = visualizationData
                    }
                } catch {
                    NSLog("⚠️ Failed to generate timeline visualization for \(parent.ocf.fileName): \(error)")
                }
            }

            await MainActor.run {
                timelineVisualizationData = visualizationResults
            }
        }
    }

    private func performLinking() {
        guard !project.model.ocfFiles.isEmpty && !project.model.segments.isEmpty else {
            NSLog("⚠️ Cannot link: need both OCF files and segments")
            return
        }

        isLinking = true
        statusBarVM.updateLinkingProgress(
            currentFile: 0,
            totalFiles: project.model.ocfFiles.count,
            fileName: "Starting...",
            fps: nil,
            percentage: 0.0
        )

        Task {
            await MainActor.run {
                statusBarVM.updateLinkingProgress(
                    currentFile: 0,
                    totalFiles: project.model.ocfFiles.count,
                    fileName: "Analyzing segments...",
                    fps: nil,
                    percentage: 0.1
                )
            }

            let linker = SegmentOCFLinker()
            let result = linker.linkSegments(project.model.segments, withOCFParents: project.model.ocfFiles)

            await MainActor.run {
                statusBarVM.updateLinkingProgress(
                    currentFile: result.parentsWithChildren.count,
                    totalFiles: project.model.ocfFiles.count,
                    fileName: "Processing analysis...",
                    fps: nil,
                    percentage: 0.5
                )
            }

            // Preview processing analysis for each OCF parent
            var analysisResults: [(String, AnalysisStatistics)] = []
            var visualizationResults: [String: TimelineVisualization] = [:]

            for parent in result.parentsWithChildren {
                do {
                    let processingPlan = try await generateProcessingPlan(for: parent)
                    analysisResults.append((parent.ocf.fileName, processingPlan.statistics))

                    // Store visualization data if available
                    if let visualizationData = processingPlan.visualizationData {
                        visualizationResults[parent.ocf.fileName] = visualizationData
                    }

                    await MainActor.run {
                        let currentIndex = analysisResults.count
                        let progress = 0.5 + (Double(currentIndex) / Double(result.parentsWithChildren.count) * 0.5)
                        statusBarVM.updateLinkingProgress(
                            currentFile: currentIndex,
                            totalFiles: result.parentsWithChildren.count,
                            fileName: parent.ocf.fileName,
                            fps: nil,
                            percentage: progress
                        )

                        let stats = processingPlan.statistics
                        NSLog("📊 Frame analysis for \(parent.ocf.fileName): \(stats.segmentCount) segments (\(stats.vfxSegmentCount) VFX), \(stats.overlapCount) overlaps")
                    }
                } catch {
                    await MainActor.run {
                        NSLog("⚠️ Failed to analyze \(parent.ocf.fileName): \(error)")
                    }
                }
            }

            await MainActor.run {
                project.updateLinkingResult(result)
                projectManager.saveProject(project)

                // Store visualization data for timeline display
                timelineVisualizationData = visualizationResults

                isLinking = false

                // Update status bar with completion
                statusBarVM.completeOperation(summary: "Linked \(result.ocfParents.count) OCF file\(result.ocfParents.count == 1 ? "" : "s")")

                NSLog("✅ Linking completed: \(result.summary)")
                NSLog("📊 Analyzed \(analysisResults.count) OCF files for overlaps and VFX priority")
            }
        }
    }

    private func generateProcessingPlan(for parent: OCFParent) async throws -> ProcessingPlan {
        // Convert MediaFileInfo segments to FFmpegGradedSegments
        var ffmpegSegments: [FFmpegGradedSegment] = []

        for child in parent.children {
            let segment = child.segment

            // Create FFmpegGradedSegment from MediaFileInfo
            let ffmpegSegment = FFmpegGradedSegment(
                url: segment.url,
                startTime: CMTime.zero, // Will be calculated by analyzer
                duration: CMTime(seconds: Double(segment.durationInFrames!) / Double(segment.frameRate!.floatValue), preferredTimescale: 600),
                sourceStartTime: CMTime.zero,
                isVFXShot: segment.isVFXShot ?? false,
                sourceTimecode: segment.sourceTimecode,
                frameRate: segment.frameRate!.floatValue,
                frameRateRational: segment.frameRate,
                isDropFrame: segment.isDropFrame
            )

            ffmpegSegments.append(ffmpegSegment)
        }

        // Create base properties from OCF parent
        let ocf = parent.ocf
        let baseProperties = VideoStreamProperties(
            width: Int(ocf.resolution!.width),
            height: Int(ocf.resolution!.height),
            frameRate: ocf.frameRate!,
            frameRateFloat: ocf.frameRate!.floatValue,
            duration: Double(ocf.durationInFrames!) / Double(ocf.frameRate!.floatValue),
            timebase: AVRational(num: 1, den: Int32(ocf.frameRate!.floatValue)),
            timecode: ocf.sourceTimecode
        )

        let totalFrames = Int(ocf.durationInFrames!)

        // Run the FrameOwnershipAnalyzer
        let analyzer = FrameOwnershipAnalyzer(
            baseProperties: baseProperties,
            segments: ffmpegSegments,
            totalFrames: totalFrames,
            verbose: true
        )

        return try analyzer.analyze()
    }

    private func generateBlankRushes() {
        guard let linkingResult = project.model.linkingResult else {
            NSLog("⚠️ Cannot generate blank rushes: no linking result")
            return
        }
        
        let allOcfsWithChildren = linkingResult.parentsWithChildren
        guard !allOcfsWithChildren.isEmpty else {
            NSLog("⚠️ No OCF files with children to process")
            return
        }
        
        // Filter out OCF files that already have blank rushes generated
        let ocfsToProcess = allOcfsWithChildren.filter { parent in
            !project.blankRushFileExists(for: parent.ocf.fileName)
        }
        
        let skippedCount = allOcfsWithChildren.count - ocfsToProcess.count
        if skippedCount > 0 {
            NSLog("📋 Skipping \(skippedCount) OCF file(s) with existing blank rushes")
        }
        
        guard !ocfsToProcess.isEmpty else {
            NSLog("✅ All OCF files already have blank rushes - nothing to generate")
            return
        }
        
        isLinking = true

        Task {
            let blankRushCreator = BlankRushIntermediate(projectDirectory: project.model.blankRushDirectory.path)
            var allResults: [BlankRushResult] = []

            for (index, parent) in ocfsToProcess.enumerated() {
                await MainActor.run {
                    statusBarVM.updateBlankRushProgress(
                        currentFile: index + 1,
                        totalFiles: ocfsToProcess.count,
                        fileName: parent.ocf.fileName,
                        fps: nil
                    )
                }

                // Create single file's linking result for this OCF
                let singleOCFResult = LinkingResult(
                    ocfParents: [parent],
                    unmatchedSegments: [],
                    unmatchedOCFs: []
                )

                // Process this single OCF with real progress callback
                let results = await blankRushCreator.createBlankRushes(from: singleOCFResult) { clipName, current, total, fps in
                    await MainActor.run {
                        statusBarVM.updateBlankRushProgress(
                            currentFile: index + 1,
                            totalFiles: ocfsToProcess.count,
                            fileName: clipName,
                            fps: fps
                        )
                    }
                }
                
                await MainActor.run {
                    // Update project status for this file
                    if let result = results.first {
                        if result.success {
                            project.model.blankRushStatus[result.originalOCF.fileName] = .completed(date: Date(), url: result.blankRushURL)
                        } else {
                            project.model.blankRushStatus[result.originalOCF.fileName] = .failed(error: result.error ?? "Unknown error")
                        }
                        allResults.append(result)
                    }
                }

                // Brief pause between files
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            }

            await MainActor.run {
                projectManager.saveProject(project)
                isLinking = false

                let successCount = allResults.filter { $0.success }.count

                // Update status bar with completion
                statusBarVM.completeOperation(summary: "Generated \(successCount) blank rush\(successCount == 1 ? "" : "es")")

                NSLog("✅ Blank Rush generation completed: \(successCount)/\(allResults.count) successful")
            }
        }
    }
}