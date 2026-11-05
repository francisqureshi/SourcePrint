//
//  AppTheme.swift
//  SourcePrint
//
//  Created by Claude on 09/09/2025.
//

import SwiftUI

// MARK: - App Theme (Apple Compressor Inspired)

struct AppTheme {

    // MARK: - Primary Colors
    static let accent = Color.blue  // Native macOS action colour
    static let accentSecondary = accent

    // MARK: - Background Colors (Pure grayscale - no tinting)
    static let backgroundPrimary = Color(white: 0.12)  // Dark grey like Compressor
    static let backgroundSecondary = Color(white: 0.09)  // Darker panel
    static let backgroundTertiary = Color(white: 0.15)  // Lighter panel

    // MARK: - UI Element Backgrounds (Pure grayscale - no tinting)
    static let backgroundCard = Color(white: 0.13)  // Card/panel background
    static let backgroundBadge = Color(white: 0.20)  // Badge/pill backgrounds
    static let backgroundDivider = Color(white: 0.25)  // Dividers and borders

    // MARK: - Text Colors
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.7)
    static let textTertiary = Color(white: 0.5)

    // MARK: - Status Colors
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let info = accent  // Blue for information

    // MARK: - Media Type Colors
    static let ocfColor = Color(red: 0.00, green: 0.48, blue: 0.80)  // Blue for OCF files
    static let segmentColor = Color(red: 0.73, green: 0.69, blue: 0.59)  // Resolve tan for segments (186, 176, 151)
    static let blankRushColor = Color.secondary  // Neutral media type; green is reserved for success
    static let vfxShotColor = Color(red: 0.749, green: 0.352, blue: 0.94)

    // MARK: - Render Queue Colors
    static let queued = textSecondary
    static let rendering = accent
    static let completed = success
    static let failed = error

    // MARK: - Print Status Colors
    static let notPrinted = textTertiary
    static let printed = Color.white.opacity(0.5)
    static let needsReprint = warning
}

// MARK: - Color Extensions

extension Color {

    // Theme shortcuts
    static let appAccent = AppTheme.accent
    static let appBackground = AppTheme.backgroundPrimary
    static let appBackgroundSecondary = AppTheme.backgroundSecondary
    static let appBackgroundTertiary = AppTheme.backgroundTertiary
    static let appBackgroundCard = AppTheme.backgroundCard
    static let appBackgroundBadge = AppTheme.backgroundBadge
    static let appBackgroundDivider = AppTheme.backgroundDivider

    static let appTextPrimary = AppTheme.textPrimary
    static let appTextSecondary = AppTheme.textSecondary
    static let appTextTertiary = AppTheme.textTertiary

    static let appSuccess = AppTheme.success
    static let appWarning = AppTheme.warning
    static let appError = AppTheme.error
    static let appInfo = AppTheme.info

    static let appOCF = AppTheme.ocfColor
    static let appSegment = AppTheme.segmentColor
    static let appBlankRush = AppTheme.blankRushColor
    static let appVfxShot = AppTheme.vfxShotColor
}

// MARK: - Button Styles

struct CompressorButtonStyle: ButtonStyle {
    let isProminent: Bool

    init(prominent: Bool = false) {
        self.isProminent = prominent
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isProminent ? AppTheme.accent : AppTheme.backgroundTertiary)
                    .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .foregroundColor(isProminent ? .white : AppTheme.textPrimary)
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Label Styles

struct StatusLabel: View {
    let text: String
    let color: Color
    let icon: String?

    init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.caption2)
            }
            Text(text)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(color.opacity(0.8))
        )
    }
}

// MARK: - Progress Bar Style

struct CompressorProgressViewStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.backgroundSecondary)
                .frame(height: 6)

            RoundedRectangle(cornerRadius: 4)
                .fill(AppTheme.accent)
                .frame(
                    width: (configuration.fractionCompleted ?? 0) * 200,
                    height: 6
                )
                .animation(.easeInOut(duration: 0.2), value: configuration.fractionCompleted)
        }
        .frame(width: 200)
    }
}


/// Keeps availability notices compact; only unusual read failures need per-file details.
struct MediaRefreshNoticeView: View {
    let notice: String
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(notice, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            if !details.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(details.joined(separator: "\n"))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}
