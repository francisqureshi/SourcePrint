import SwiftUI
import SourcePrintCore

struct RenderHistoryDrawer: View {
    let records: [SourcePrintCore.PrintRecord]
    let sources: [MediaFileInfo]
    let onClose: () -> Void
    @State private var search = ""
    @State private var collapsedBatches: Set<String> = []
    @State private var job: String?
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
            (job == nil || identity($0) == job) &&
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
                Text("\(visible.count) attempts").foregroundStyle(.secondary)
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Close render log")
            }
            .padding()
            TextField("Search jobs, paths or results", text: $search)
            .padding(.horizontal)
            .padding(.bottom, 8)
            if job != nil {
                HStack {
                    Text("Job history").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All jobs") { job = nil; selection = nil }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
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
                                        Text(status(record))
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
                                    .contextMenu {
                                        Button("Show job history") { job = identity(record); selection = record.id }
                                    }
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
                Text("Select an attempt to inspect its output and job history.")
                    .font(.callout).foregroundStyle(.secondary).padding()
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .onChange(of: search) { _, _ in selection = nil }
        .task(id: selection) { await inspectOutput() }
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
                    Button("Job history") { job = identity(record) }
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
                Divider()
                Text(outputState).fontWeight(.medium)
                HStack {
                    Button("Open Output") { NSWorkspace.shared.open(record.outputURL) }
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.outputURL]) }
                }
                .disabled(!canOpenOutput)
                DisclosureGroup("File locations") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Source").fontWeight(.medium)
                        Text(record.ocfURL?.path ?? "Source path unavailable in older history")
                        Text("Output").fontWeight(.medium)
                        Text(record.outputURL.path)
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
        let newer = records.contains {
            $0.success && $0.date > record.date &&
            $0.outputURL.standardizedFileURL == record.outputURL.standardizedFileURL
        }
        if newer {
            outputState = "Replaced by a newer render at this path"
            return
        }
        let current = await Task.detached(priority: .utility) {
            RenderOutputFingerprint.capture(at: record.outputURL)
        }.value
        guard !Task.isCancelled, selection == record.id else { return }
        guard let current else {
            outputState = "Output missing or unavailable · it may have moved"
            return
        }
        guard let saved = record.outputFingerprint else {
            outputState = "File exists · historical version unverified"
            return
        }
        guard current == saved else {
            outputState = "Output changed or replaced since this render"
            return
        }
        outputState = "Rendered output available"
        canOpenOutput = true
    }
}
