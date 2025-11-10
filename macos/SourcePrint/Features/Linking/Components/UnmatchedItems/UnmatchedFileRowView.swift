//
//  UnmatchedFileRowView.swift
//  SourcePrint
//
//  Row view for unmatched files in linking view
//

import SourcePrintCore
import SwiftUI

struct UnmatchedFileRowView: View {
    let file: MediaFileInfo
    let type: MediaType

    enum MediaType {
        case ocf, segment
    }

    var body: some View {
        HStack {
            Image(systemName: type == .ocf ? "film.fill" : "film")
                .foregroundColor(type == .ocf ? AppTheme.ocfColor : AppTheme.segmentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.body)

                HStack {
                    if let fps = file.frameRate {
                        Text("\(fps.floatValue, specifier: "%.3f") fps")
                            .monospacedDigit()
                    }
                    if let startTC = file.sourceTimecode {
                        Text("•")
                        Text("TC: \(startTC)")
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer()

            Text("Unmatched")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.appBackgroundBadge)
                .cornerRadius(4)
        }
    }
}
