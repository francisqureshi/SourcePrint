import SwiftUI
import SourcePrintCore

struct RenderHistoryDrawer: View {
    @ObservedObject var project: ProjectViewModel
    @EnvironmentObject var projectManager: ProjectManager
    let isRendering: Bool
    private var records: [SourcePrintCore.PrintRecord] { project.model.printHistory }
    private var sources: [MediaFileInfo] { project.model.ocfFiles }
    @State private var eligibleIDs: Set<UUID> = []
    @State private var publishPlan: [PublishItem] = []
    @State private var showPublishReview = false
    @State private var preparingPublish = false
    @State private var publishMessage: String?
    @State private var inspectedOutputURL: URL?

    let onClose: () -> Void
    @State private var search = ""
    @State private var collapsedBatches: Set<String> = []
    @State private var selection: UUID?
    @State private var outputState = "Checking output…"
    @State private var canOpenOutput = false

    private func identity(_ record: SourcePrintCore.PrintRecord) -> String {
        if let url = record.ocfURL { return url.standardizedFileURL.absoluteString }
        let matches = sources.filter { $0.fileName == record.ocfFileName }
        if matches.count == 1 { return matches[0].url.standardizedFileURL.absoluteString }
        return "legacy:" + record.ocfFileName
    }

    private func status(_ record: SourcePrintCore.PrintRecord) -> String {
        record.cancelled == true ? "Cancelled" : record.success ? "Completed" : "Failed"
    }

    private func color(_ record: SourcePrintCore.PrintRecord) -> Color {
        record.cancelled == true ? .orange : record.success ? .green : .red
    }

    private var visible: [SourcePrintCore.PrintRecord] {
        records.filter {
            (search.isEmpty || [$0.ocfFileName, $0.ocfURL?.path ?? "", $0.outputURL.path, status($0)]
                .contains { $0.localizedCaseInsensitiveContains(search) })
        }.sorted { $0.date < $1.date }
    }

    private struct BatchGroup: Identifiable {
        let id: String
        let batch: RenderBatch?
        let records: [SourcePrintCore.PrintRecord]
        var date: Date { batch?.date ?? records.first?.date ?? .distantPast }
    }

    private var batches: [BatchGroup] {
        Dictionary(grouping: visible) { $0.batch?.id.uuidString ?? "legacy" }
            .map { id, records in BatchGroup(id: id, batch: records.first?.batch, records: records) }
            .sorted { $0.date < $1.date }
    }

    private func batchHeader(_ group: BatchGroup) -> some View {
        Button {
            if !collapsedBatches.insert(group.id).inserted { collapsedBatches.remove(group.id) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: collapsedBatches.contains(group.id) ? "chevron.right" : "chevron.down")
                    Image(systemName: "square.stack.3d.up")
                    Text(group.batch?.name ?? "Earlier history · batch unknown").fontWeight(.semibold)
                    Spacer()
                    Text("\(group.records.count) \(group.records.count == 1 ? "job" : "jobs")")
                }
                let completed = group.records.filter(\.success).count
                let cancelled = group.records.filter { $0.cancelled == true }.count
                let failed = group.records.count - completed - cancelled
                HStack {
                    Text(group.date.formatted(date: .abbreviated, time: .standard))
                    Spacer()
                    Text([
                        completed > 0 ? "\(completed) completed" : nil,
                        failed > 0 ? "\(failed) failed" : nil,
                        cancelled > 0 ? "\(cancelled) cancelled" : nil
                    ].compactMap { $0 }.joined(separator: " · "))
                }
                .foregroundStyle(.secondary)
                if let batch = group.batch, group.records.count < batch.jobCount {
                    Text("\(batch.jobCount) jobs queued in this batch").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(.primary)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
    }

    private var selected: SourcePrintCore.PrintRecord? {
        records.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Render Log", systemImage: "clock.arrow.circlepath").font(.headline)
                Spacer()
                Button("Publish All (\(eligibleIDs.count))") {
                    preparePublish(records.filter { eligibleIDs.contains($0.id) })
                }
                .tint(.blue)
                .accentColor(.blue)
                .disabled(eligibleIDs.isEmpty || isRendering || project.isPublishing || preparingPublish)
                Text("\(visible.count) attempts").foregroundStyle(.secondary)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close render log")
            }
            .padding()
            if project.model.publishDirectory == nil {
                Text("Choose a Publish Folder in Overview to enable publishing.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
            }
            if project.isPublishing {
                ProgressView("Publishing…").padding(.horizontal)
            }
            if let publishMessage {
                Text(publishMessage).font(.caption).textSelection(.enabled).padding(.horizontal)
            }
            TextField("Search jobs, paths or results", text: $search)
            .padding(.horizontal)
            .padding(.bottom, 8)
            Divider()
            ScrollViewReader { scroll in
                List(selection: $selection) {
                    ForEach(batches) { group in
                        Section {
                            if !collapsedBatches.contains(group.id) {
                                ForEach(group.records) { record in
                                    HStack(spacing: 8) {
                                        Image(systemName: record.cancelled == true ? "stop.circle" : record.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                            .foregroundStyle(color(record))
                                            .help(status(record))
                                            .accessibilityLabel(status(record))
                                        Text(record.ocfFileName)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 8)
                                        Text(published(record) != nil ? "Published" : status(record))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        Text("\(record.duration, specifier: "%.1f")s")
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                            .help("Render duration")
                                    }
                                    .padding(.leading, 20)
                                    .padding(.vertical, 6)
                                    .tag(record.id)
                                }
                            }
                        } header: {
                            batchHeader(group)
                        }
                    }
                    Color.clear
                        .frame(height: 1)
                        .listRowSeparator(.hidden)
                        .id("latest-render")
                }
                .task(id: records.count) {
                    // Allow the native list to lay out inserted rows before scrolling.
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { return }
                    scroll.scrollTo("latest-render", anchor: .bottom)
                }
                .listStyle(.plain)
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView(
                            records.isEmpty ? "No renders yet" : "No matching attempts",
                            systemImage: "clock",
                            description: Text(records.isEmpty ? "Completed, failed and cancelled attempts appear here." : "Try another search or show all jobs.")
                        )
                    }
                }
            }
            Divider()
            if let record = selected {
                details(record)
            } else {
                Text("Select an attempt to inspect its output and render details.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: search) { _, _ in selection = nil }
        .task(id: selection) { await inspectOutput() }
        .task(id: project.model.lastModified) {
            while !Task.isCancelled {
                await refreshPublishCandidates()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .sheet(isPresented: $showPublishReview) { publishReview }

        .onChange(of: records.count) { _, _ in
            // Recheck an older selected attempt when a new render replaces its output.
            selection = nil
        }
    }

    private func details(_ record: SourcePrintCore.PrintRecord) -> some View {
        let history = records.filter { identity($0) == identity(record) }
        let latest = history.max { $0.date < $1.date }
        let success = history.filter(\.success).max { $0.date < $1.date }
        return ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(record.ocfFileName).font(.headline)
                    Spacer()
                    Button("Publish") { preparePublish([record]) }
                        .tint(.blue)
                        .accentColor(.blue)
                        .disabled(!eligibleIDs.contains(record.id) || isRendering || project.isPublishing || preparingPublish)
                }
                Text("\(status(record)) · \(record.date.formatted(date: .abbreviated, time: .standard))")
                Text("\(record.segmentCount) \(record.segmentCount == 1 ? "segment" : "segments") · Render time \(record.duration, specifier: "%.1f")s")
                    .foregroundStyle(.secondary)
                if let latest {
                    Text("Latest attempt · \(status(latest)) · \(latest.date.formatted(date: .abbreviated, time: .standard))")
                }
                Text(success.map { "Last success · " + $0.date.formatted(date: .abbreviated, time: .standard) }
                    ?? "No successful render recorded")
                if let error = record.errorMessage {
                    Text(error).foregroundStyle(record.cancelled == true ? Color.orange : Color.red)
                        .textSelection(.enabled)
                } else if !record.success {
                    Text(record.cancelled == true ? "Render cancelled" : "Failure details unavailable in older history")
                        .foregroundStyle(.secondary)
                }
                if let event = published(record) {
                    Text("Published · " + event.date.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(.green)
                    if let message = event.message {
                        Text(message).foregroundStyle(.secondary)
                    }
                }
                ForEach(project.model.publishHistory.filter { $0.renderID == record.id && $0.state != "published" }) { event in
                    Text("Publish \(event.state) · \(event.message ?? "Review and retry if delivery was interrupted.")")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text(outputState).fontWeight(.medium)
                HStack {
                    Button("Open Output") { if let url = inspectedOutputURL { NSWorkspace.shared.open(url) } }
                    Button("Reveal in Finder") { if let url = inspectedOutputURL { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
                .disabled(!canOpenOutput)
                DisclosureGroup("File locations") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source").fontWeight(.medium)
                        Text(record.ocfURL?.path ?? "Source path unavailable in older history")
                        Text("Output").fontWeight(.medium)
                        Text(record.outputURL.path)
                        if let event = published(record) {
                            Text("Published destination").fontWeight(.medium)
                            Text(event.destinationURL.path)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.vertical, 4)
                }
                .id(record.id)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .frame(maxHeight: 250)
    }

    private func inspectOutput() async {
        canOpenOutput = false
        outputState = "Checking output…"
        guard let record = selected else { return }
        guard record.success else {
            outputState = "This attempt produced no completed output"
            return
        }
        let event = published(record)
        let outputURL = event?.destinationURL ?? record.outputURL
        let expected = event?.outputFingerprint ?? record.outputFingerprint
        let newer = event == nil && records.contains {
            $0.success && $0.date > record.date &&
            $0.outputURL.standardizedFileURL == record.outputURL.standardizedFileURL
        }
        if newer {
            outputState = "Replaced by a newer render at this path"
            return
        }
        let current = await Task.detached(priority: .utility) {
            RenderOutputFingerprint.capture(at: outputURL)
        }.value
        guard !Task.isCancelled, selection == record.id else { return }
        guard let current else {
            outputState = "Output missing or unavailable · it may have moved"
            return
        }
        guard let saved = expected else {
            outputState = "File exists · historical version unverified"
            return
        }
        guard current == saved else {
            outputState = event == nil ? "Output changed or replaced since this render" : "Published output has since been replaced or changed"
            return
        }
        outputState = event == nil ? "Rendered output available" : "Published output available"
        inspectedOutputURL = outputURL
        canOpenOutput = true
    }
    private func published(_ record: SourcePrintCore.PrintRecord) -> PublishRecord? {
        project.model.publishHistory.last { $0.renderID == record.id && $0.state == "published" }
    }

    private func refreshPublishCandidates() async {
        guard project.model.publishDirectory != nil else { eligibleIDs = []; return }
        let completed = records.filter { $0.success }
        var seenJobs = Set<String>()
        var seenOutputs = Set<URL>()
        let candidates = completed.reversed().filter { record in
            let latestJob = seenJobs.insert(identity(record)).inserted
            let latestOutput = seenOutputs.insert(record.outputURL.standardizedFileURL).inserted
            return latestJob && latestOutput && published(record) == nil
        }
        let ids = await Task.detached(priority: .utility) {
            Set(candidates.filter {
                guard let saved = $0.outputFingerprint else { return false }
                return RenderOutputFingerprint.capture(at: $0.outputURL) == saved
            }.map(\.id))
        }.value
        guard !Task.isCancelled else { return }
        eligibleIDs = ids
    }

    private func preparePublish(_ renders: [SourcePrintCore.PrintRecord]) {
        guard let directory = project.model.publishDirectory, !renders.isEmpty else { return }
        preparingPublish = true
        publishMessage = nil
        let protected = (project.model.ocfFiles + project.model.segments).map(\.url)
            + [project.model.fileURL].compactMap { $0 }
        Task {
            do {
                let plan = try await Task.detached(priority: .utility) {
                    try PublishService.prepare(renders, directory: directory, protectedURLs: protected)
                }.value
                publishPlan = plan
                showPublishReview = true
            } catch {
                publishMessage = error.localizedDescription
            }
            preparingPublish = false
        }
    }

    private var publishReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Publish \(publishPlan.count) \(publishPlan.count == 1 ? "job" : "jobs")").font(.title2)
            Text("Move these rendered outputs to the Publish Folder. Existing files marked Replace will be overwritten.")
            Text(publishPlan.first?.destination.deletingLastPathComponent().path ?? "")
                .font(.caption).textSelection(.enabled)
            List(publishPlan) { item in
                HStack {
                    Text(item.render.ocfFileName)
                    Spacer()
                    Text(item.previousDestination == nil ? "Add" : "Replace")
                        .foregroundStyle(item.previousDestination == nil ? Color.secondary : Color.orange)
                }
            }
            .frame(height: min(280, CGFloat(publishPlan.count) * 32 + 16))
            HStack {
                Spacer()
                Button("Cancel") { showPublishReview = false }
                Button("Publish") { performPublish() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .accentColor(.blue)
                    .disabled(isRendering || project.isPublishing)
            }
        }
        .padding(24)
        .frame(width: 550)
    }

    private func savePublishingState() async throws {
        project.updateModified()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            projectManager.saveProject(project) { continuation.resume(with: $0) }
        }
    }

    private func performPublish() {
        guard !project.isPublishing, !isRendering else { return }
        let plan = publishPlan
        project.isPublishing = true
        showPublishReview = false
        Task {
            var completed = 0
            var messages: [String] = []
            for item in plan {
                let event = PublishRecord(render: item.render, destinationURL: item.destination)
                let index = project.model.publishHistory.count
                project.model.publishHistory.append(event)
                do {
                    try await savePublishingState()
                    let fingerprint = try await Task.detached(priority: .utility) {
                        try PublishService.install(item)
                    }.value
                    project.model.publishHistory[index].state = "published"
                    project.model.publishHistory[index].date = Date()
                    project.model.publishHistory[index].outputFingerprint = fingerprint
                    if case .printed(let date, let url) = project.model.printStatus[item.render.ocfFileName],
                       url == item.render.outputURL {
                        project.model.printStatus[item.render.ocfFileName] = .printed(date: date, outputURL: item.destination)
                    }
                    try await savePublishingState()
                    completed += 1
                    do {
                        try await Task.detached(priority: .utility) { try PublishService.removeOriginal(item) }.value
                    } catch {
                        let message = "Published; original retained in Output. " + error.localizedDescription
                        project.model.publishHistory[index].message = message
                        messages.append(message)
                        try? await savePublishingState()
                    }
                } catch {
                    project.model.publishHistory[index].state = "failed"
                    project.model.publishHistory[index].message = error.localizedDescription
                    messages.append(item.render.ocfFileName + " · " + error.localizedDescription)
                    try? await savePublishingState()
                }
            }
            project.isPublishing = false
            publishMessage = "Published \(completed) of \(plan.count) jobs." + (messages.isEmpty ? "" : " " + messages.joined(separator: "\n"))
            await refreshPublishCandidates()
            await inspectOutput()
        }
    }

}
