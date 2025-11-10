//
//  MediaFileRowView.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import SourcePrintCore
import SwiftUI

struct MediaFileRowView: View {
    let file: DisplayMediaInfo
    let type: MediaType
    let onVFXToggle: ((String, Bool) -> Void)?  // Callback to toggle VFX status (fileName, newValue)

    enum MediaType {
        case ocf, segment
    }

    // Check if this is a VFX shot
    private var isVFXShot: Bool {
        file.isVFX
    }

    var body: some View {
        HStack {
            // Main type icon
            Image(systemName: type == .ocf ? "film.fill" : "film")
                .foregroundColor(type == .ocf ? AppTheme.ocfColor : AppTheme.segmentColor)
                .frame(width: 16)

            // VFX indicator for segments
            if isVFXShot && type == .segment {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.purple)
                    .frame(width: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.fileName)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Text(file.durationDisplay)
                    Text("•")
                    Text(file.frameCountDisplay + " frames")
                    Text("•")
                    Text(file.frameRateDisplay)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let startTC = file.sourceTimecode {
                    Text("TC: \(startTC)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                // VFX badge for segments
                if isVFXShot && type == .segment {
                    Text("VFX")
                        .font(.caption)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.appBackgroundBadge)
                        .foregroundColor(Color.appVfxShot)
                        .cornerRadius(4)
                }

                Text(file.mediaTypeDisplay)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.appBackgroundBadge)
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if type == .segment {
                Button {
                    onVFXToggle?(file.fileName, !isVFXShot)
                } label: {
                    Label(
                        isVFXShot ? "Unmark as VFX Shot" : "Mark as VFX Shot",
                        systemImage: isVFXShot ? "wand.and.stars.slash" : "wand.and.stars")
                }
            }
        }
    }
}

#Preview {
    // Create a sample DisplayMediaInfo for preview
    let sampleFile = DisplayMediaInfo(
        fileName: "C20250825_0303.mov",
        url: URL(fileURLWithPath: "/path/to/file.mov"),
        resolution: Resolution(width: 3840, height: 2160),
        displayResolution: Resolution(width: 3840, height: 2160),
        sampleAspectRatio: "1:1",
        frameRateDisplay: "25.000fps (25/1)",
        frameRateValue: 25.0,
        isDropFrame: false,
        sourceTimecode: "20:16:31:13",
        endTimecode: "20:17:16:01",
        durationInFrames: 1320,
        durationSeconds: 52.8,
        reelName: nil,
        isInterlaced: false,
        fieldOrder: "progressive",
        mediaType: .originalCameraFile,
        isVFXShot: false
    )

    VStack {
        MediaFileRowView(file: sampleFile, type: .ocf, onVFXToggle: nil)
        MediaFileRowView(
            file: sampleFile, type: .segment,
            onVFXToggle: { fileName, isVFX in
                print("Toggle VFX for \(fileName): \(isVFX)")
            })
    }
    .padding()
}

