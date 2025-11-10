#!/usr/bin/env swift

// Demo: Loading a .w2 project file using SourcePrintCore
// This works on macOS AND Linux (no SwiftUI required!)

import Foundation

// Add the Core module to your swift command:
// swift -I .build/debug -L .build/debug -lSourcePrintCore demo-load-project.swift

#if canImport(SourcePrintCore)
import SourcePrintCore

let projectPath = "/Users/mac10/Documents/ProResWriter Projects/watchFolderNew.w2"
let projectURL = URL(fileURLWithPath: projectPath)

print("📂 Loading project from Core...")
print("   Path: \(projectPath)")
print()

do {
    // Method 1: Direct ProjectContainer loading (cross-platform)
    let container = try ProjectContainer.load(from: projectURL)

    print("✅ Project loaded successfully!")
    print()
    print("📊 Project Info:")
    print("   File Format Version: \(container.fileFormatVersion)")
    print("   Last Modified: \(container.model.lastModified)")
    print("   OCF Directory: \(container.model.ocfDirectory?.path ?? "none")")
    print("   Segments Directory: \(container.model.segmentsDirectory?.path ?? "none")")
    print("   Blank Rush Directory: \(container.model.blankRushDirectory?.path ?? "none")")
    print()

    if let linkingResult = container.model.linkingResult {
        print("🔗 Linking Results:")
        print("   OCF Parents: \(linkingResult.ocfParents.count)")

        let totalLinkedSegments = linkingResult.ocfParents.reduce(0) { $0 + $1.children.count }
        print("   Total Linked Segments: \(totalLinkedSegments)")
        print("   Unmatched Segments: \(linkingResult.unmatchedSegments.count)")
        print()

        // Show OCF files
        if !linkingResult.ocfParents.isEmpty {
            print("📹 OCF Files:")
            for (index, parent) in linkingResult.ocfParents.prefix(5).enumerated() {
                let ocf = parent.ocf
                print("   \(index + 1). \(ocf.fileName)")
                if let tc = ocf.sourceTimecode {
                    print("      TC: \(tc)")
                }
                if let resolution = ocf.resolution {
                    print("      Resolution: \(Int(resolution.width))x\(Int(resolution.height))")
                }
                if let fps = ocf.frameRate {
                    print("      Frame Rate: \(fps.num)/\(fps.den) fps")
                }
                print("      Linked Segments: \(parent.children.count)")
            }

            if linkingResult.ocfParents.count > 5 {
                print("   ... and \(linkingResult.ocfParents.count - 5) more")
            }
        }
        print()
    }

    print("🎬 Render Queue:")
    if container.renderQueue.isEmpty {
        print("   (empty)")
    } else {
        for (index, item) in container.renderQueue.enumerated() {
            print("   \(index + 1). \(item.ocfFileName)")
            print("      Status: \(item.status)")
            print("      Added: \(item.addedDate)")
        }
    }
    print()

    print("👀 Watch Folder Settings:")
    print("   Monitoring: \(container.watchFolderSettings.isMonitoring ? "ON" : "OFF")")
    if let watchURL = container.watchFolderSettings.watchFolderURL {
        print("   Watch Path: \(watchURL.path)")
    }
    print("   Folder Type: \(container.watchFolderSettings.folderType)")
    print()

    // Method 2: Using LinuxProjectLoader (convenience wrapper)
    print("📦 Alternative: Using LinuxProjectLoader...")
    let loader = LinuxProjectLoader()
    let container2 = try loader.loadProject(from: projectURL)
    print("   ✅ Also loaded successfully!")
    print()

    // Demonstrate saving
    print("💾 Saving project back (round-trip test)...")
    let tempURL = URL(fileURLWithPath: "/tmp/test-project.w2")
    try container.save(to: tempURL)
    print("   ✅ Saved to: \(tempURL.path)")

    // Verify round-trip
    let reloaded = try ProjectContainer.load(from: tempURL)
    print("   ✅ Round-trip successful!")
    print("   OCF Parents match: \(reloaded.model.linkingResult?.ocfParents.count == container.model.linkingResult?.ocfParents.count)")

    // Clean up
    try? FileManager.default.removeItem(at: tempURL)

} catch {
    print("❌ Error loading project: \(error)")
    exit(1)
}

print()
print("🎉 Demo complete! This code works on Linux too!")

#else
print("❌ SourcePrintCore not found. Build the package first:")
print("   cd SourcePrintCore && swift build")
#endif
