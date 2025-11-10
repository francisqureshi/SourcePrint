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

    /// Show validation warnings/errors in an alert
    static func showValidationAlert(for result: ProjectValidationResult, projectName: String) {
        guard !result.isValid else { return }

        let alert = NSAlert()
        alert.alertStyle = result.hasErrors ? .critical : .warning
        alert.messageText = result.hasErrors ? "Project Loading Issues" : "Project Validation Warnings"

        var message = "The project '\(projectName)' was loaded but has the following issues:\n\n"

        // Show errors first
        if result.hasErrors {
            message += "ERRORS:\n"
            for error in result.errors {
                message += "• \(error.message)\n"
                message += "  → \(error.recoveryAction)\n\n"
            }
        }

        // Then warnings
        if result.hasWarnings {
            message += result.hasErrors ? "\nWARNINGS:\n" : ""
            for warning in result.warnings {
                message += "• \(warning.message)\n"
                message += "  → \(warning.recoveryAction)\n\n"
            }
        }

        alert.informativeText = message
        alert.addButton(withTitle: "OK")

        if result.hasErrors {
            alert.addButton(withTitle: "View Details")
        }

        let response = alert.runModal()

        if response == .alertSecondButtonReturn {
            // Show detailed issue list
            showDetailedValidationIssues(result, projectName: projectName)
        }
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
