//
//  OCFParentHeaderView.swift
//  SourcePrint
//
//  Header view for OCF parent cards
//

import SourcePrintCore
import SwiftUI

struct OCFParentHeaderView: View {
    let parent: OCFParent
    let project: ProjectViewModel
    let timelineVisualization: TimelineVisualization?
    let selectedSegmentFileName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(parent.ocf.fileName)
                    .font(.body)
                    .fontWeight(.medium)

                HStack {
                    Text("\(parent.childCount) linked segments")
                        .monospacedDigit()
                    Text("•")
                    if let fps = parent.ocf.frameRate {
                        Text("\(fps.floatValue, specifier: "%.3f") fps")
                            .monospacedDigit()
                    }
                    if let startTC = parent.ocf.sourceTimecode {
                        Text("•")
                        Text("TC: \(startTC)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            HStack(spacing: 8) {
                // Print Status Indicator
                if let printStatus = project.model.printStatus[parent.ocf.fileName] {
                    Label(printStatus.displayName, systemImage: printStatus.icon)
                        .font(.caption2)
                        .foregroundColor(printStatus.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appBackgroundBadge)
                        .cornerRadius(4)
                } else {
                    Label("Not Printed", systemImage: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appBackgroundBadge)
                        .cornerRadius(4)
                }

                // Blank Rush Status Indicator
                if project.blankRushFileExists(for: parent.ocf.fileName) {
                    Label("Blank Rush", systemImage: "film.fill")
                        .font(.caption2)
                        .foregroundColor(Color.appBlankRush)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appBackgroundBadge)
                        .cornerRadius(4)
                } else {
                    Label("No Blank Rush", systemImage: "film")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appBackgroundBadge)
                        .cornerRadius(4)
                }
            }
        }
        .padding(.vertical, 4)

        // Timeline visualization
        if let timelineData = timelineVisualization {
            TimelineChartView(
                visualizationData: timelineData,
                ocfFileName: parent.ocf.fileName,
                selectedSegmentFileName: selectedSegmentFileName
            )
        }
        }
    }
}

