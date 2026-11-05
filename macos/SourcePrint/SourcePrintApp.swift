//
//  SourcePrintApp.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 28/08/2025.
//

import SwiftUI
import SourcePrintCore
import Sparkle

extension Notification.Name {
    static let showNewProject = Notification.Name("showNewProject")
    static let toggleSidebar = Notification.Name("toggleSidebar")
}

@main
struct SourcePrintApp: App {
    @StateObject private var projectManager = ProjectManager()
    private let updaterController: SPUStandardUpdaterController

    init() {
        // Initialize Sparkle updater
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(projectManager)
                .preferredColorScheme(.dark)
                .background(Color.appBackground)
                .tint(Color.appAccent)
                .accentColor(Color.appAccent)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project...") {
                    // This will trigger the new project sheet in ContentView
                    NotificationCenter.default.post(name: .showNewProject, object: nil)
                }
                .keyboardShortcut("n")
            }
            
            CommandGroup(after: .newItem) {
                Button("Open Project...") {
                    projectManager.openProjectFile()
                }
                .keyboardShortcut("o")
                
                Menu("Open Recent") {
                    if projectManager.recentProjects.isEmpty {
                        Text("No Recent Projects")
                            .disabled(true)
                    } else {
                        ForEach(projectManager.recentProjects.indices, id: \.self) { index in
                            let viewModel = projectManager.recentProjects[index]
                            Button(viewModel.model.name) {
                                projectManager.openRecentProject(viewModel)
                            }
                        }
                        
                        Divider()
                        
                        Button("Clear Menu") {
                            projectManager.clearRecentProjects()
                        }
                    }
                }
                .disabled(projectManager.recentProjects.isEmpty)
                
                Divider()
                
                Button("Save Project") {
                    if let currentViewModel = projectManager.currentProject {
                        projectManager.saveProject(currentViewModel)
                    }
                }
                .keyboardShortcut("s")
                .disabled(projectManager.currentProject == nil)

                Button("Save Project As...") {
                    if let currentViewModel = projectManager.currentProject {
                        projectManager.saveProjectAs(currentViewModel)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(projectManager.currentProject == nil)
            }
            
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
            }

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updaterController.updater.checkForUpdates()
                }
            }
        }
    }
}
