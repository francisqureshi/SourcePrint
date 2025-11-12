//
//  ProjectAlertHelper.swift
//  SourcePrint
//
//  Created by Claude on 10/11/2025.
//

import SwiftUI
import AppKit
import SourcePrintCore

/// Helper for showing project-related alerts
struct ProjectAlertHelper {

    /// Show validation warnings/errors in a custom window with fixed height
    static func showValidationAlert(for result: ProjectValidationResult, projectName: String) {
        guard !result.isValid else { return }

        // Get screen height and calculate 40%
        guard let screenHeight = NSScreen.main?.frame.height else { return }
        let windowHeight = screenHeight * 0.4
        let windowWidth: CGFloat = 600

        // Create the content view
        let contentView = ValidationAlertView(
            result: result,
            projectName: projectName,
            onClose: {
                // Window will be closed by the hosting window controller
            }
        )

        // Create a hosting controller
        let hostingController = NSHostingController(rootView: contentView)

        // Create window
        let window = NSWindow(contentViewController: hostingController)
        window.title = result.hasErrors ? "Project Loading Issues" : "Project Validation Warnings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: windowWidth, height: windowHeight))
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        // Show the window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func showDetailedValidationIssues(_ result: ProjectValidationResult, projectName: String) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Validation Issues for '\(projectName)'"

        var message = ""
        for (index, issue) in result.issues.enumerated() {
            message += "\(index + 1). [\(issue.severity == .error ? "ERROR" : "WARNING")] \(issue.message)\n"
            message += "   Recovery: \(issue.recoveryAction)\n\n"
        }

        alert.informativeText = message
        alert.addButton(withTitle: "Close")
        alert.runModal()
    }

    /// Show save error with retry option
    static func showSaveError(_ error: Error, projectName: String, retryHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Failed to Save Project"
        alert.informativeText = "Could not save project '\(projectName)'.\n\nError: \(error.localizedDescription)\n\nWould you like to try again?"
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            retryHandler()
        }
    }

    /// Show generic save success notification (optional, can be subtle)
    static func showSaveSuccess(projectName: String) {
        // Could use UserNotifications or a subtle toast
        // For now, just log - we don't want to be too noisy
        NSLog("✅ Successfully saved project: \(projectName)")
    }
}

// MARK: - Custom Validation Alert View

struct ValidationAlertView: View {
    let result: ProjectValidationResult
    let projectName: String
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: result.hasErrors ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill")
                    .font(.title)
                    .foregroundColor(result.hasErrors ? .red : .orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(result.hasErrors ? "Project Loading Issues" : "Project Validation Warnings")
                        .font(.headline)
                    Text("The project '\(projectName)' was loaded but has the following issues:")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(Color.appBackgroundSecondary)

            Divider()

            // Scrollable content
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Show errors first
                    if result.hasErrors {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("ERRORS")
                                .font(.headline)
                                .foregroundColor(.red)

                            ForEach(Array(result.errors.enumerated()), id: \.offset) { index, error in
                                ValidationIssueRow(
                                    icon: "xmark.circle.fill",
                                    iconColor: .red,
                                    message: error.message,
                                    recoveryAction: error.recoveryAction
                                )
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    // Then warnings
                    if result.hasWarnings {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(result.hasErrors ? "WARNINGS" : "")
                                .font(.headline)
                                .foregroundColor(.orange)
                                .opacity(result.hasErrors ? 1.0 : 0.0)

                            ForEach(Array(result.warnings.enumerated()), id: \.offset) { index, warning in
                                ValidationIssueRow(
                                    icon: "exclamationmark.triangle.fill",
                                    iconColor: .orange,
                                    message: warning.message,
                                    recoveryAction: warning.recoveryAction
                                )
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color.appBackground)

            Divider()

            // Footer with close button
            HStack {
                Spacer()
                Button("Close") {
                    NSApp.keyWindow?.close()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            }
            .padding()
            .background(Color.appBackgroundSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Validation Issue Row

struct ValidationIssueRow: View {
    let icon: String
    let iconColor: Color
    let message: String
    let recoveryAction: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(iconColor)
                .font(.title3)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.body)
                    .foregroundColor(.primary)

                Text(recoveryAction)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
            }

            Spacer()
        }
        .padding(12)
        .background(Color.appBackgroundTertiary.opacity(0.5))
        .cornerRadius(6)
    }
}
