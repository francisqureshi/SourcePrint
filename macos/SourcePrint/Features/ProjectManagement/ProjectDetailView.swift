//
//  ProjectDetailView.swift
//  SourcePrint
//
//  Created by Francis Qureshi on 31/08/2025.
//

import SwiftUI
import SourcePrintCore

enum ProjectTab {
    case overview
    case media
    case linking
}

struct ProjectDetailView: View {
    let project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    @State private var selectedTab: ProjectTab = .overview

    var body: some View {
        TabView(selection: $selectedTab) {
            ProjectOverviewTab(project: project)
                .tabItem {
                    Label("Overview", systemImage: "list.bullet")
                }
                .tag(ProjectTab.overview)

            MediaImportTab(project: project, selectedTab: $selectedTab)
                .environmentObject(projectManager)
                .tabItem {
                    Label("Media", systemImage: "folder")
                }
                .tag(ProjectTab.media)

            LinkingTab(project: project)
                .environmentObject(projectManager)
                .tabItem {
                    Label("Linking", systemImage: "link")
                }
                .tag(ProjectTab.linking)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarBackButtonHidden(true)
    }
}