import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

/// S16: paste, type or import one or more YAML documents; dry-run them all; create/apply each with per-document results.
struct CreateFromYAMLView: View {
    let clusterID: ClusterID
    var namespace: String?
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        if let cluster = registry.config(for: clusterID), let key = registry.screenKey(for: clusterID), let session = registry.session(for: clusterID) {
            CreateContent(model: CreateModel(cluster: cluster, session: session, namespace: namespace ?? cluster.defaultNamespace ?? "default"))
                .id(key)
        } else {
            EmptyState(.error(message: "This cluster is no longer available."))
        }
    }
}

// MARK: - Model

@MainActor @Observable
final class CreateModel {
    struct Row: Identifiable {
        var id: Int
        var title: String
        var line: Int
        var namespace: String?
        var namespaceDefaulted: Bool
        var result: DocumentResult
    }

    let cluster: ClusterConfig
    let session: ClusterSession
    var text = ""
    var namespace: String
    private(set) var namespaces: [String] = []
    private(set) var rows: [Row] = []
    private(set) var isWorking = false
    private(set) var diagnostics: [YAMLDiagnostic] = []
    private(set) var documentCount = 0
    @ObservationIgnored private var prepared: [PreparedManifest] = []
    @ObservationIgnored private var lintTask: Task<Void, Never>?

    init(cluster: ClusterConfig, session: ClusterSession, namespace: String) {
        self.cluster = cluster
        self.session = session
        self.namespace = namespace
    }

    var client: any KubeClientProtocol { session.client }
    var hasErrors: Bool { !diagnostics.isEmpty }
    var finished: Bool { !rows.isEmpty && rows.allSatisfy { $0.result.isDone } }
    var anyDone: Bool { rows.contains { $0.result.isDone } }

    func loadNamespaces() async {
        var names = ((try? await client.list(Namespace.self).items) ?? []).map(\.metadata.name)
        if !names.contains(namespace) { names.append(namespace) }
        namespaces = names.sorted()
    }

    func textChanged() {
        lintTask?.cancel()
        lintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let docs = YAMLCodec.parseDocuments(self.text)
            self.documentCount = docs.count
            self.diagnostics = docs.compactMap(\.diagnostic)
            if !self.rows.isEmpty, !self.isWorking, !self.anyDone { self.rows = [] }  // stale results
        }
    }

    func append(_ snippet: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { text = snippet } else { text = text.hasSuffix("\n") ? text + "---\n" + snippet : text + "\n---\n" + snippet }
        textChanged()
    }

    // MARK: Prepare & dry-run

    private func buildRows() async -> Bool {
        let docs = YAMLCodec.parseDocuments(text)
        documentCount = docs.count
        diagnostics = docs.compactMap(\.diagnostic)
        if session.discovery == nil, docs.contains(where: { $0.apiVersion?.contains("/") == true }) { await session.loadDiscovery() }
        let outcomes = ManifestPreparer.prepare(docs, defaultNamespace: namespace, discovery: session.discovery)
        prepared = []
        rows = outcomes.map { outcome in
            switch outcome {
            case .ready(let m):
                prepared.append(m)
                return Row(id: m.index, title: m.title, line: m.startLine, namespace: m.namespace, namespaceDefaulted: m.namespaceDefaulted, result: .pending)
            case .invalid(let doc, let issue):
                let title = [doc.kind, doc.name].compactMap { $0 }.joined(separator: "/")
                return Row(id: doc.index, title: title.isEmpty ? "Document \(doc.index + 1)" : title, line: issue.line ?? doc.startLine, namespace: nil, namespaceDefaulted: false, result: .invalid([issue]))
            }
        }
        return !rows.isEmpty && prepared.count == rows.count
    }

    private func setResult(_ index: Int, _ result: DocumentResult) {
        if let i = rows.firstIndex(where: { $0.id == index }) { rows[i].result = result }
    }

    /// Dry-runs every document. Returns true when all are acceptable.
    @discardableResult
    func validate() async -> Bool {
        isWorking = true
        defer { isWorking = false }
        guard await buildRows() || !prepared.isEmpty else { return false }
        let newNamespaces = Set(prepared.filter { $0.kind == .namespace }.map(\.name))
        for m in prepared { setResult(m.index, .working) }
        for m in prepared {
            var result = await ManifestApplier.dryRun(m, client: client)
            // A namespace created by this same batch doesn't exist yet during the dry-run.
            if case .invalid(let issues) = result, let ns = m.namespace, newNamespaces.contains(ns),
               issues.allSatisfy({ $0.message.contains("namespaces \"\(ns)\" not found") }) {
                result = .valid("Will create (after Namespace \(ns))")
            }
            setResult(m.index, result)
        }
        return rows.allSatisfy { $0.result.isOK }
    }

    var summaryForDryRun: DryRunOutcome {
        let bad = rows.filter { !$0.result.isOK }
        if bad.isEmpty { return .passed("All \(rows.count) document\(rows.count == 1 ? "" : "s") validated by the API server.") }
        let msg = bad.map { row -> String in
            switch row.result {
            case .invalid(let issues), .failed(let issues): "\(row.title): " + (issues.first?.message ?? "invalid")
            default: "\(row.title): not validated"
            }
        }.joined(separator: "\n")
        return .failed(msg)
    }

    // MARK: Commit

    func commit() async throws {
        isWorking = true
        defer { isWorking = false }
        // Namespaces first so later documents can land in them.
        let ordered = prepared.sorted { ($0.kind == .namespace ? 0 : 1, $0.index) < ($1.kind == .namespace ? 0 : 1, $1.index) }
        for m in ordered where !(rows.first { $0.id == m.index }?.result.isDone ?? false) {
            setResult(m.index, .working)
            setResult(m.index, await ManifestApplier.commit(m, client: client))
        }
        let failed = rows.filter { !$0.result.isDone }.count
        if failed > 0 { throw KubeError.unsupported("\(failed) of \(rows.count) documents failed. See the results list.") }
    }
}

// MARK: - View

private struct CreateContent: View {
    @State var model: CreateModel
    @State private var controller = CodeEditorController()
    @State private var importing = false
    @State private var importError: String?
    @State private var confirm: ConfirmRequest?
    @Environment(\.dismiss) private var dismiss

    init(model: CreateModel) { _model = State(initialValue: model) }

    private var cluster: ClusterConfig { model.cluster }

    var body: some View {
        VStack(spacing: Spacing.s) {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ContextLine(cluster: cluster, namespace: model.namespace, kind: nil)
                if cluster.readOnly { StateBanner(.readOnly) }
                controls
            }
            .padding(.horizontal, Spacing.l)

            YAMLCodeEditor(text: $model.text, isEditable: true, wraps: false, diagnostics: model.diagnostics, controller: controller)
                .overlay(alignment: .topLeading) {
                    if model.text.isEmpty {
                        Text("Paste or type YAML here.\nSeparate multiple objects with ---")
                            .font(.whCode).foregroundStyle(.tertiary).padding(.leading, 56).padding(.top, 10).allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, Spacing.l)
                .frame(minHeight: 180)

            if let message = model.diagnostics.first {
                Button { controller.jump(toLine: message.line) } label: {
                    Label("Line \(message.line): \(message.message)", systemImage: "xmark.octagon.fill")
                        .font(.footnote).foregroundStyle(Palette.criticalText).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain).padding(.horizontal, Spacing.l)
            }
            if let importError { Text(importError).font(.footnote).foregroundStyle(Palette.criticalText).padding(.horizontal, Spacing.l) }

            if !model.rows.isEmpty { results }
        }
        .padding(.bottom, Spacing.s)
        .background(Palette.groupedBackground)
        .navigationTitle("Create from YAML")
        .whInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(model.anyDone ? "Done" : "Cancel") { dismiss() } }
            if !cluster.readOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.anyDone && !model.finished ? "Retry" : "Create") { Task { await presentConfirm() } }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.hasErrors || model.isWorking || model.finished)
                        .accessibilityIdentifier("yaml.create")
                }
            }
        }
        .confirmSheet($confirm)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.yaml, .json, .plainText, .text, .data]) { result in
            handleImport(result)
        }
        .task { await model.loadNamespaces() }
        .onChange(of: model.text) { model.textChanged() }
    }

    // MARK: Pieces

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.s) {
                Menu {
                    ForEach(YAMLTemplate.all) { t in
                        Button(t.name, systemImage: t.symbol) { model.append(t.yaml) }
                    }
                } label: { Label("Template", systemImage: "doc.badge.plus") }
                    .accessibilityIdentifier("yaml.templates")
                Button("Import", systemImage: "square.and.arrow.down") { importing = true }
                PasteButton(payloadType: String.self) { strings in
                    if let s = strings.first { model.append(s) }
                }
                .labelStyle(.titleAndIcon)
                Menu {
                    Picker("Namespace", selection: $model.namespace) {
                        ForEach(model.namespaces.isEmpty ? [model.namespace] : model.namespaces, id: \.self) { Text($0).tag($0) }
                    }
                } label: { Label(model.namespace, systemImage: "folder") }
                    .accessibilityLabel("Default namespace \(model.namespace)")
                if !cluster.readOnly {
                    Button { Task { await model.validate() } } label: {
                        Label("Dry-run", systemImage: "checkmark.shield")
                    }
                    .disabled(model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.hasErrors || model.isWorking)
                }
                Spacer(minLength: 0)
                if model.documentCount > 0 {
                    Text("\(model.documentCount) document\(model.documentCount == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.small)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Results").padding(.horizontal, Spacing.l).padding(.bottom, 4)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        ResultRow(row: row) { line in controller.jump(toLine: line) }
                        Divider()
                    }
                }
                .padding(.horizontal, Spacing.m)
                .whCard()
                .padding(.horizontal, Spacing.l)
            }
            .frame(maxHeight: 240)
        }
    }

    // MARK: Actions

    private func presentConfirm() async {
        controller.dismissKeyboard()
        guard await model.validate() || model.rows.contains(where: { $0.result.isOK }) else { return }
        if model.rows.contains(where: { !$0.result.isOK && !$0.result.isDone }) { return }
        let rows = model.rows
        let pendingRows = rows.filter { !$0.result.isDone }
        guard !pendingRows.isEmpty else { return }
        let updates = pendingRows.filter { if case .willUpdate = $0.result { true } else { false } }.count
        let single = pendingRows.count == 1 ? pendingRows[0] : nil
        confirm = ConfirmRequest(
            title: single.map { "Create \($0.title)?" } ?? "Create \(pendingRows.count) objects?",
            message: updates > 0
                ? "Creates new objects and updates \(updates) that already exist (server-side apply, field manager “wheelhouse”)."
                : "Creates \(pendingRows.count == 1 ? "this object" : "these \(pendingRows.count) objects") on the cluster.",
            verb: updates > 0 ? "Create & Apply" : "Create",
            cluster: cluster,
            namespace: model.namespace,
            resource: single?.title ?? "\(pendingRows.count) objects",
            confirmationText: single.flatMap { $0.title.split(separator: "/").last.map(String.init) } ?? String(pendingRows.count),
            facts: pendingRows.prefix(8).map { .init($0.title, $0.namespace ?? "cluster-scoped") },
            isDisruptive: true,
            dryRun: { [model] in
                await model.validate()
                return model.summaryForDryRun
            },
            action: { [model] in try await model.commit() })
    }

    private func handleImport(_ result: Result<URL, Error>) {
        importError = nil
        switch result {
        case .failure(let e): importError = e.localizedDescription
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                guard data.count <= 2_000_000 else { importError = "That file is larger than 2 MB."; return }
                guard let s = String(data: data, encoding: .utf8) else { importError = "The file isn’t UTF-8 text."; return }
                model.append(s)
            } catch { importError = error.localizedDescription }
        }
    }
}

private struct ResultRow: View {
    let row: CreateModel.Row
    var jump: (Int) -> Void

    var body: some View {
        Button { jump(row.line) } label: {
            HStack(alignment: .top, spacing: Spacing.m) {
                pill.frame(minWidth: 92, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.whCode.weight(.semibold)).lineLimit(1)
                    if let detail { Text(detail).font(.footnote).foregroundStyle(detailTone).fixedSize(horizontal: false, vertical: true) }
                    if row.namespaceDefaulted, let ns = row.namespace { Text("namespace \(ns) (default)").font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Jumps to line \(row.line)")
    }

    @ViewBuilder private var pill: some View {
        switch row.result {
        case .pending: StatusPill(tone: .unknown, text: "Pending", symbol: "circle.dotted")
        case .working: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Working").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
        case .valid: StatusPill(tone: .healthy, text: "Valid", symbol: "checkmark.circle.fill")
        case .willUpdate: StatusPill(tone: .info, text: "Update", symbol: "arrow.triangle.2.circlepath")
        case .invalid: StatusPill(tone: .critical, text: "Invalid", symbol: "xmark.octagon.fill")
        case .created: StatusPill(tone: .healthy, text: "Created", symbol: "checkmark.circle.fill")
        case .updated: StatusPill(tone: .healthy, text: "Updated", symbol: "checkmark.circle.fill")
        case .failed: StatusPill(tone: .critical, text: "Failed", symbol: "xmark.octagon.fill")
        }
    }

    private var detail: String? {
        switch row.result {
        case .valid(let s), .willUpdate(let s): s
        case .invalid(let issues), .failed(let issues):
            issues.map { i in [i.field, i.message].compactMap { $0 }.joined(separator: ": ") + (i.line.map { " (line \($0))" } ?? "") }.joined(separator: "\n")
        case .created: "Created on the cluster"
        case .updated: "Existing object updated"
        default: nil
        }
    }
    private var detailTone: Color {
        switch row.result {
        case .invalid, .failed: Palette.criticalText
        default: .secondary
        }
    }
}
