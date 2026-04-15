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

    @State private var outputDirectory: URL?
    @State private var blankRushDirectory: URL?
    @State private var projectSaveLocation: URL?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("New Project")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Fields
            VStack(spacing: 12) {
                projectRow(
                    label: "Save Project To",
                    url: $projectSaveLocation,
                    placeholder: "Choose location...",
                    isFilePicker: true
                )
                Divider()
                projectRow(
                    label: "Output Directory",
                    url: $outputDirectory,
                    placeholder: "Choose output directory..."
                )
                Divider()
                projectRow(
                    label: "Blank Rush Directory",
                    url: $blankRushDirectory,
                    placeholder: "Choose blank rush directory..."
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            // Footer buttons
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { createProject() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValidProject)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 460)
    }

    @ViewBuilder
    private func projectRow(label: String, url: Binding<URL?>, placeholder: String, isFilePicker: Bool = false) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 150, alignment: .leading)
                .foregroundColor(.secondary)
                .font(.system(size: 13))

            if let u = url.wrappedValue {
                Text(isFilePicker ? u.path : u.lastPathComponent)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button("Choose...") {
                if isFilePicker {
                    pickSaveLocation(binding: url)
                } else if label == "Output Directory" {
                    pickOutputDirectory()
                } else {
                    pickDirectory(binding: url)
                }
            }
            .controlSize(.small)
        }
    }

    private var isValidProject: Bool {
        outputDirectory != nil &&
        blankRushDirectory != nil &&
        projectSaveLocation != nil
    }

    private func createProject() {
        guard let outputDir = outputDirectory,
              let blankRushDir = blankRushDirectory,
              let saveLocation = projectSaveLocation else { return }

        let name = saveLocation.deletingPathExtension().lastPathComponent

        // Create blank rush directory if it doesn't already exist
        try? FileManager.default.createDirectory(at: blankRushDir, withIntermediateDirectories: true)

        _ = projectManager.createNewProject(
            name: name,
            outputDirectory: outputDir,
            blankRushDirectory: blankRushDir,
            saveLocation: saveLocation
        )

        dismiss()
    }

    private func pickSaveLocation(binding: Binding<URL?>) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.data]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Untitled"
        panel.title = "Save Project"
        panel.message = "Choose where to save your project file"

        if panel.runModal() == .OK, let panelURL = panel.url {
            var base = panelURL
            while base.pathExtension.lowercased() == "w2" {
                base = base.deletingPathExtension()
            }
            binding.wrappedValue = base.appendingPathExtension("w2")
        }
    }

    private func pickOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url

            // Suggest a sibling blank_rush folder — only create it when the project is confirmed
            blankRushDirectory = url.deletingLastPathComponent().appendingPathComponent("blank_rush")
        }
    }

    private func pickDirectory(binding: Binding<URL?>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true

        if panel.runModal() == .OK {
            binding.wrappedValue = panel.url
        }
    }
}
