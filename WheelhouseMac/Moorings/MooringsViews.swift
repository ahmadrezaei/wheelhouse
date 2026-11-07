import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

private func statusText(_ state: ClusterCheckState) -> String {
    switch state {
    case .notChecked: "Not checked"
    case .checking: "Checking…"
    case .result(.reachable(let ms, let v)): "Reachable \(ms) ms" + (v.map { " · \($0)" } ?? "")
    case .result(.needsSignIn): "Needs sign-in"
    case .result(.unreachable): "Unreachable"
    case .result(.pluginMissing(let name)): "Plugin missing: \(name)"
    case .result(.blocked(let why)): why
    }
}

/// The first-run sheet (DESIGN-MAC §6.1): found contexts, environment suggestions, Allow changes (off) and Check.
struct FirstRunMooringsSheet: View {
    let controller: MooringsController
    @Environment(\.dismiss) private var dismiss

    struct Row { var selected: Bool; var environment: ClusterEnvironment?; var picked = false; var allow = false }
    @State private var rows: [ClusterID: Row] = [:]
    @State private var checks: [ClusterID: ClusterCheckState] = [:]

    private var fileCount: Int { Set(controller.firstRunRows.map(\.context.fileName)).count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Found \(controller.firstRunRows.count) contexts in \(fileCount) file\(fileCount == 1 ? "" : "s")").font(.headline)
            Table(controller.firstRunRows) {
                TableColumn("") { r in
                    Toggle("", isOn: binding(r.id, \.selected)).labelsHidden().disabled(!r.selectable)
                }.width(24)
                TableColumn("Context") { r in
                    VStack(alignment: .leading) {
                        Text(r.context.displayName).font(.system(.body, design: .monospaced))
                        if let why = r.unselectableReason { Text(why).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Server") { r in Text(r.context.server?.host() ?? "").foregroundStyle(.secondary) }
                TableColumn("Auth") { r in Text(r.context.authSummary.label) }
                TableColumn("Environment") { r in
                    HStack {
                        Picker("", selection: envBinding(r)) {
                            Text("Choose…").tag(ClusterEnvironment?.none)
                            ForEach(ClusterEnvironment.allCases, id: \.self) { e in Text(e.title).tag(ClusterEnvironment?.some(e)) }
                        }.labelsHidden().disabled(!r.selectable)
                        if r.context.suggestion != nil, rows[r.id]?.picked != true { Text("✦").help("Suggested: \(r.context.suggestion?.reasons.joined(separator: ", ") ?? "")") }
                    }
                }
                TableColumn("Allow changes") { r in
                    Toggle("", isOn: binding(r.id, \.allow)).labelsHidden().disabled(!r.selectable || rows[r.id]?.picked != true)
                        .help("Pick the environment first.")
                }
                TableColumn("Status") { r in
                    HStack {
                        Text(statusText(checks[r.id] ?? controller.state.checkState(for: r.id))).foregroundStyle(.secondary)
                        if r.selectable {
                            Button("Check") { Task { _ = await controller.service.check(r.id); sync() } }.buttonStyle(.link)
                        }
                    }
                }
            }
            .frame(minHeight: 220)
            Text("Wheelhouse reads these files where they are and never changes them. New contexts start read-only. You can change this per cluster at any time.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Choose Later") { dismiss() }
                Button("Add \(addCount) Clusters") { add() }.keyboardShortcut(.defaultAction).disabled(addCount == 0)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 420)
        .task { prepare() }
    }

    private var addCount: Int { rows.values.filter(\.selected).count }

    private func prepare() {
        for r in controller.firstRunRows where rows[r.id] == nil {
            rows[r.id] = Row(selected: r.defaultSelected, environment: r.context.suggestion?.environment)
        }
        // Production-suggested rows are never checked automatically.
        Task { await controller.service.startFirstRunChecks(ids: controller.firstRunRows.filter(\.selectable).map(\.id)); sync() }
    }

    private func sync() { for r in controller.firstRunRows { checks[r.id] = controller.state.checkState(for: r.id) } }

    private func binding(_ id: ClusterID, _ key: WritableKeyPath<Row, Bool>) -> Binding<Bool> {
        Binding(get: { rows[id]?[keyPath: key] ?? false }, set: { rows[id, default: Row(selected: false)][keyPath: key] = $0 })
    }

    private func envBinding(_ r: FirstRunRow) -> Binding<ClusterEnvironment?> {
        Binding(get: { rows[r.id]?.environment }, set: { rows[r.id, default: Row(selected: false)].environment = $0; rows[r.id]?.picked = true })
    }

    private func add() {
        let choices = rows.mapValues { FirstRunChoice(selected: $0.selected, environment: $0.environment, environmentPicked: $0.picked, allowChanges: $0.allow) }
        Task {
            try? await controller.service.completeFirstRun(choices: choices)
            await controller.refresh()
            dismiss()
        }
    }
}

extension ClusterEnvironment {
    var title: String { rawValue.capitalized }
}

/// The Moorings screen: sources, contexts and their state.
struct MooringsScreen: View {
    var body: some View {
        if let controller = MooringsController.shared { MooringsList(controller: controller) } else {
            ContentUnavailableView("Moorings isn’t running", systemImage: "externaldrive.badge.questionmark")
        }
    }
}

private struct MooringsList: View {
    let controller: MooringsController
    @State private var showFirstRun = false

    var body: some View {
        List {
            if controller.needsFirstRun {
                Button("Choose which contexts to add…") { showFirstRun = true }
            }
            ForEach(controller.contexts) { c in
                HStack {
                    VStack(alignment: .leading) {
                        Text(c.displayName).font(.system(.body, design: .monospaced))
                        Text(c.shadowedBy.map { "shadowed by \($0)" } ?? c.fileName).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if c.isCurrent { Text("current").font(.caption2).padding(2).background(.quaternary, in: Capsule()) }
                    Text(c.authSummary.label).foregroundStyle(.secondary)
                    Text(statusText(controller.state.checkState(for: c.id))).foregroundStyle(.secondary)
                }
            }
        }
        .sheet(isPresented: $showFirstRun) { FirstRunMooringsSheet(controller: controller) }
        .task { await controller.refresh(); if controller.needsFirstRun { showFirstRun = true } }
    }
}
