//
//  ProjectAlertHelper.swift
//  SourcePrint
//
//  Created by Claude on 10/11/2025.
//

import AppKit

/// Helper for showing project-related alerts
struct ProjectAlertHelper {

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
