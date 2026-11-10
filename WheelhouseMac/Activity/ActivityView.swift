import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The local audit log (DESIGN-MAC section 10): time, cluster, origin, verb, object, result and (terminal origin) the command line as
/// reported by the user's shell. Shows the newest 200 matches (a bounded list); exports cover everything. Local only; never a
/// request body or a Secret value.
struct ActivityView: View {
    static let visibleRows = 200

    @Environment(MacAppEnvironment.self) private var env
    @State private var records: [ActivityRecord] = []
    @State private var text = ""
    @State private var clusterFilter: ClusterID?
    @State private var range: Range = .week
    @State private var total = 0
    @State private var loaded = false

    enum Range: String, CaseIterable, Identifiable {
        case day = "Last 24 hours", week = "Last 7 days", all = "All (90 days)"
        var id: String { rawValue }
        var since: Date? {
            switch self {
            case .day: Date().addingTimeInterval(-86_400)
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .all: nil
            }
        }
    }

    private var log: ActivityLog { env.activity }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter", text: $text).textFieldStyle(.roundedBorder).frame(maxWidth: 260).accessibilityIdentifier("activity.filter")
                Picker("Cluster", selection: $clusterFilter) {
                    Text("All clusters").tag(ClusterID?.none)
                    ForEach(env.registry.clusters, id: \.id) { Text($0.name).tag(ClusterID?.some($0.id)) }
                }
                .labelsHidden().frame(maxWidth: 180)
                Picker("Range", selection: $range) { ForEach(Range.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(maxWidth: 160)
                Spacer()
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh").accessibilityLabel("Refresh")
                Menu {
                    Button("Export CSV…") { export(csv: true) }
                    Button("Export JSON…") { export(csv: false) }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            .padding(10)
            Divider()
            if records.isEmpty {
                EmptyState(.empty(title: loaded ? "No activity" : "Loading…", systemImage: "list.bullet.rectangle",
                                  hint: "Changes you confirm, plugin runs and other audited events appear here. Nothing leaves this Mac."))
            } else {
                Table(records) {
                    TableColumn("Time") { Text($0.entry.time, format: .dateTime.month().day().hour().minute().second()).monospacedDigit() }.width(min: 110, ideal: 130)
                    TableColumn("Cluster") { Text(clusterName($0.entry.cluster)) }.width(min: 80, ideal: 110)
                    TableColumn("Origin") { Text(ActivityLog.label(for: $0.entry.origin)) }.width(min: 70, ideal: 100)
                    TableColumn("Verb") { Text($0.entry.verb) }.width(min: 60, ideal: 80)
                    TableColumn("Object") { Text($0.entry.object ?? "") }.width(min: 100, ideal: 180)
                    TableColumn("Result") { Text($0.entry.result).foregroundStyle($0.entry.result == "ok" ? Color.primary : Palette.warningText) }.width(min: 80, ideal: 160)
                    TableColumn("Command (reported by your shell)") { Text($0.entry.commandLine ?? "").font(.system(.body, design: .monospaced)) }
                }
                .accessibilityIdentifier("activity.table")
                if total > records.count {
                    Text("Showing the newest \(records.count) of \(total) matching entries. Export for everything.").font(.caption).foregroundStyle(.secondary).padding(6)
                }
            }
        }
        .frame(minWidth: 720, minHeight: 360)
        .task(id: "\(text)|\(clusterFilter ?? "")|\(range.rawValue)") {
            // Typing in the filter reloads after a short pause, not on every key.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await reload()
        }
        .accessibilityIdentifier("activity")
    }

    private func clusterName(_ id: ClusterID?) -> String { id.map { env.registry.config(for: $0)?.name ?? $0 } ?? "" }

    private func reload() async {
        let query = ActivityQuery(text: text, cluster: clusterFilter, since: range.since, limit: Self.visibleRows)
        records = await log.records(query)
        total = records.count < Self.visibleRows ? records.count : await log.count(matching: query)
        loaded = true
    }

    private func export(csv: Bool) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = csv ? "wheelhouse-activity.csv" : "wheelhouse-activity.json"
        panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let all = await log.records(ActivityQuery(text: text, cluster: clusterFilter, since: range.since, limit: Int(Int32.max))).reversed() as [ActivityRecord]
            let data = csv ? Data(ActivityLog.csv(all).utf8) : ((try? ActivityLog.json(all)) ?? Data())
            try? data.write(to: url, options: .atomic)
        }
    }
}
