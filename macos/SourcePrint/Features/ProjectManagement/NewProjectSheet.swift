//
//  NewProjectSheet.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import SwiftUI
import SourcePrintCore

struct NewProjectSheet: View {
    @EnvironmentObject var projectManager: ProjectManager
    @Environment(\.dismiss) private var dismiss

    @State private var projectName = ""
    @State private var outputDirectory: URL?
    @State private var blankRushDirectory: URL?
    @State private var projectSaveLocation: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("Project Information") {
                    TextField("Project Name", text: $projectName)
                        .textFieldStyle(.roundedBorder)

                    DirectoryPickerRow(
                        title: "Save Project To",
                        url: $projectSaveLocation,
                        placeholder: "Choose where to save project...",
                        isFilePicker: true,
                        projectName: projectName
                    )
                }

                Section("Directories") {
                    DirectoryPickerRow(
                        title: "Output Directory",
                        url: $outputDirectory,
                        placeholder: "Choose output directory..."
                    )

                    DirectoryPickerRow(
                        title: "Blank Rush Directory",
                        url: $blankRushDirectory,
                        placeholder: "Choose blank rush directory..."
                    )
                }
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createProject()
                    }
                    .disabled(!isValidProject)
                }
            }
        }
        .frame(width: 500, height: 350)
    }

    private var isValidProject: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        outputDirectory != nil &&
        blankRushDirectory != nil &&
        projectSaveLocation != nil
    }

    private func createProject() {
        guard let outputDir = outputDirectory,
              let blankRushDir = blankRushDirectory,
              let saveLocation = projectSaveLocation else { return }

        let trimmedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = projectManager.createNewProject(
            name: trimmedName,
            outputDirectory: outputDir,
            blankRushDirectory: blankRushDir,
            saveLocation: saveLocation
        )

        dismiss()
    }
}

struct DirectoryPickerRow: View {
    let title: String
    @Binding var url: URL?
    let placeholder: String
    var isFilePicker: Bool = false
    var projectName: String = ""

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 140, alignment: .leading)

            Button(displayText) {
                if isFilePicker {
                    selectFileSaveLocation()
                } else {
                    selectDirectory()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundColor(url == nil ? .secondary : .primary)
        }
    }

    private var displayText: String {
        if let url = url {
            if isFilePicker {
                // Show the full path for file save location
                return url.path
            } else {
                // Just show last path component for directories
                return url.lastPathComponent
            }
        }
        return placeholder
    }

    private func selectDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK {
            url = panel.url
        }
    }

    private func selectFileSaveLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = projectName.isEmpty ? "Untitled.w2" : "\(projectName).w2"
        panel.title = "Save Project"
        panel.message = "Choose where to save your project file"

        if panel.runModal() == .OK {
            url = panel.url
        }
    }
}