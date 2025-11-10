//
//  TimelineChartView.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 19/09/2025.
//

import Charts
import SourcePrintCore
import SwiftUI

struct TimelineChartView: View {
    let visualizationData: TimelineVisualization
    let ocfFileName: String
    let selectedSegmentFileName: String?

    private let chartHeight: CGFloat = 30
    private let trackHeight: CGFloat = 4

    private var hasVFX: Bool {
        visualizationData.placements.contains(where: { $0.isVFX })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Chart {
                // Blank rush background (bottom track, y=0)
                RuleMark(
                    xStart: .value("Start", 0),
                    xEnd: .value("End", visualizationData.totalFrames),
                    y: .value("Track", 0)
                )
                .foregroundStyle(Color.appBackgroundDivider)
                .lineStyle(StrokeStyle(lineWidth: trackHeight, lineCap: .butt))

                // Regular segments (middle track, y=1)
                ForEach(visualizationData.placements.filter { !$0.isVFX }, id: \.segment.url) {
                    placement in
                    let isSelected =
                        selectedSegmentFileName == placement.segment.url.lastPathComponent
                    RuleMark(
                        xStart: .value("Start", placement.startFrame),
                        xEnd: .value("End", placement.endFrame),
                        y: .value("Track", 1)
                    )
                    .foregroundStyle(
                        isSelected ? Color.red : Color.appSegment
                    )
                    .lineStyle(StrokeStyle(lineWidth: trackHeight, lineCap: .butt))
                }

                // VFX segments (top track, y=2) - always show track space
                ForEach(visualizationData.placements.filter { $0.isVFX }, id: \.segment.url) {
                    placement in
                    let isSelected =
                        selectedSegmentFileName == placement.segment.url.lastPathComponent
                    RuleMark(
                        xStart: .value("Start", placement.startFrame),
                        xEnd: .value("End", placement.endFrame),
                        y: .value("Track", 2)
                    )
                    .foregroundStyle(isSelected ? Color.red : Color.appVfxShot)
                    .lineStyle(StrokeStyle(lineWidth: trackHeight, lineCap: .butt))
                }

                // Conflict zones as overlay indicators
                ForEach(Array(visualizationData.conflictZones.enumerated()), id: \.offset) {
                    index, conflict in
                    RuleMark(
                        xStart: .value("Start", conflict.start),
                        xEnd: .value("End", conflict.end),
                        y: .value("Track", 2.5)
                    )
                    .foregroundStyle(Color.orange.opacity(0.8))
                    .lineStyle(StrokeStyle(lineWidth: 8, lineCap: .butt))
                }
            }
            .frame(height: chartHeight)
            .chartYScale(domain: 0...2)
            .chartXScale(domain: 0...visualizationData.totalFrames)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(position: .bottom) { value in
                    if let intValue = value.as(Int.self) {
                        AxisGridLine()
                        AxisValueLabel {
                            Text("\(intValue)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

        }
        .background(Color.appBackgroundCard.opacity(0.95), in: RoundedRectangle(cornerRadius: 8))
        .allowsHitTesting(false)
    }

}

// MARK: - Color Helper Extension

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a: UInt64
        let r: UInt64
        let g: UInt64
        let b: UInt64
        switch hex.count {
        case 3:  // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            return nil
        }

        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

#Preview {
    // Create sample visualization data for preview
    let sampleSegment1 = FFmpegGradedSegment(
        url: URL(fileURLWithPath: "/path/segment1.mov"),
        startTime: CMTime.zero,
        duration: CMTime(seconds: 10, preferredTimescale: 600),
        sourceStartTime: CMTime.zero,
        isVFXShot: false,
        sourceTimecode: "01:00:10:00",
        frameRate: 25.0,
        frameRateRational: AVRational(num: 25, den: 1),
        isDropFrame: false
    )

    let sampleSegment2 = FFmpegGradedSegment(
        url: URL(fileURLWithPath: "/path/vfx_shot.mov"),
        startTime: CMTime(seconds: 5, preferredTimescale: 600),
        duration: CMTime(seconds: 8, preferredTimescale: 600),
        sourceStartTime: CMTime.zero,
        isVFXShot: true,
        sourceTimecode: "01:00:15:00",
        frameRate: 25.0,
        frameRateRational: AVRational(num: 25, den: 1),
        isDropFrame: false
    )

    let sampleVisualization = TimelineVisualization(
        totalFrames: 1000,
        placements: [
            TimelineVisualization.SegmentPlacement(
                segment: sampleSegment1,
                startFrame: 100,
                endFrame: 350,
                isVFX: false,
                overwrittenRanges: [],
                color: "#4DABF7"
            ),
            TimelineVisualization.SegmentPlacement(
                segment: sampleSegment2,
                startFrame: 200,
                endFrame: 400,
                isVFX: true,
                overwrittenRanges: [(220, 280)],
                color: "#FF6B6B"
            ),
        ],
        conflictZones: [
            (start: 200, end: 350, description: "segment1.mov vs vfx_shot.mov")
        ]
    )

    TimelineChartView(
        visualizationData: sampleVisualization,
        ocfFileName: "C001_0101.mov",
        selectedSegmentFileName: nil
    )
    .padding()
}
