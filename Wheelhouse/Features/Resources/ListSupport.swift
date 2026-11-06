import SwiftUI
import WheelhouseKit
import WheelhouseUI

enum ListSort: String, CaseIterable, Identifiable {
    case status = "Status", name = "Name", age = "Age", restarts = "Restarts", cpu = "CPU", memory = "Memory"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .status: "waveform.path.ecg"; case .name: "textformat"; case .age: "clock"; case .restarts: "arrow.counterclockwise"; case .cpu: "cpu"; case .memory: "memorychip" }
    }
    static func available(for kind: ResourceKind) -> [ListSort] {
        switch kind.kind {
        case "Pod" where kind.group.isEmpty: [.status, .name, .age, .restarts, .cpu, .memory]
        case "Node": [.status, .name, .age, .cpu, .memory]
        default: [.status, .name, .age]
        }
    }
}

struct ListRowModel: Identifiable, Hashable {
    let object: Unstructured
    let summary: ResourceSummary
    var extra: [String] = []
    var id: String { object.id }
}

/// Caches `ResourceSummary` per object version so watch updates only re-summarise changed objects.
@MainActor
final class SummaryCache {
    private var cache: [String: (rv: String?, summary: ResourceSummary)] = [:]
    func summary(kind: ResourceKind, object: Unstructured) -> ResourceSummary {
        let key = "\(kind.id)|\(object.id)"
        if let hit = cache[key], hit.rv == object.metadata.resourceVersion, object.metadata.resourceVersion != nil { return hit.summary }
        let s = ResourceSummarizer.summarize(kind: kind, object: object)
        cache[key] = (object.metadata.resourceVersion, s)
        return s
    }
}

/// Namespace picker used by the sections and list screens. `nil` = All namespaces.
struct NamespaceMenu: View {
    @Environment(ClusterRegistry.self) private var registry
    let session: ClusterSession
    @Binding var namespace: String?
    var onChange: ((String?) -> Void)?

    var body: some View {
        let store = session.store(for: Namespace.self)
        let names = store.items.map(\.metadata.name)
        let pinned = session.config.pinnedNamespaces.filter { names.contains($0) || names.isEmpty }
        Menu {
            Picker("Namespace", selection: Binding(get: { namespace ?? "" }, set: { set($0.isEmpty ? nil : $0) })) {
                Label("All namespaces", systemImage: "square.stack.3d.up").tag("")
                if !pinned.isEmpty {
                    Section("Pinned") { ForEach(pinned, id: \.self) { Label($0, systemImage: "pin").tag($0) } }
                }
                Section("Namespaces") { ForEach(names.filter { !pinned.contains($0) }, id: \.self) { Text($0).tag($0) } }
            }
        } label: {
            Label(namespace ?? "All namespaces", systemImage: "folder")
        }
        .accessibilityLabel("Namespace: \(namespace ?? "all")")
        .task { await store.run() }
    }

    private func set(_ ns: String?) {
        namespace = ns
        registry.setNamespace(ns, for: session.id)
        onChange?(ns)
    }
}

struct LabelFilterSheet: View {
    @Binding var applied: String
    let suggestions: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    private var problem: String? { LabelSelectorSyntax.validate(text) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("app=web,tier in (api,worker),!canary", text: $text)
                        .font(.whCode).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if let problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Palette.criticalText) }
                } header: { Text("Label selector") } footer: { Text("Equality (`=`, `!=`), set-based (`in`, `notin`) and existence (`key`, `!key`) requirements, comma separated.") }
                if !suggestions.isEmpty {
                    Section("Common labels") {
                        ForEach(suggestions, id: \.self) { s in
                            Button { append(s) } label: { Text(s).font(.whCode) }
                        }
                    }
                }
            }
            .navigationTitle("Filter by Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { applied = text.trimmingCharacters(in: .whitespaces); dismiss() }.disabled(problem != nil) }
            }
            .onAppear { text = applied }
        }
        .presentationDetents([.medium, .large])
    }

    private func append(_ s: String) {
        let t = text.trimmingCharacters(in: .whitespaces)
        text = t.isEmpty ? s : "\(t),\(s)"
    }
}
