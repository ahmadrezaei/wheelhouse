import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Detail of one Flux object or Argo CD Application (DESIGN-MAC §6.10). Reads the live object from the shared store on every
/// render, so a reconcile or sync shows up as it happens. Every action goes through ConfirmSheet.
struct TidesDetailView: View {
    let model: TidesClusterModel
    let appID: String

    enum Tab: String, CaseIterable, Identifiable {
        case resources = "Resources", diff = "Diff", history = "History", conditions = "Conditions & Events", manifest = "Manifest"
        case status = "Status", inventory = "Inventory", dependencies = "Dependencies"
        var id: String { rawValue }
    }

    /// nil until the person picks one: the default depends on the tool, which is known only once the object has loaded.
    @State private var picked: Tab?
    private func tab(for app: GitOpsApp) -> Tab { picked ?? (app.tool == .argoCD ? .resources : .status) }
    @State private var request: ConfirmRequest?
    @State private var syncSheet = false
    @State private var connectSheet = false
    @State private var failure: String?
    @State private var undo: UndoOffer?
    @State private var connection = ArgoConnection.live

    struct UndoOffer: Equatable { var message: String; var inverse: GitOpsActionPlan.Kind }

    private var app: GitOpsApp? { model.app(id: appID) }

    var body: some View {
        Group {
            if let app {
                content(app)
            } else {
                ContentUnavailableView("Not found", systemImage: "questionmark.folder", description: Text("This object no longer exists, or has not loaded yet."))
            }
        }
        .confirmSheet($request)
        .alert("Can't do that", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
        .sheet(isPresented: $syncSheet) {
            if let app { ArgoSyncOptionsSheet(app: app) { options in syncSheet = false; present(.argoSync, sync: options) } }
        }
        .sheet(isPresented: $connectSheet) { ArgoConnectSheet(session: model.session, connection: connection) { connectSheet = false } }
        .whileVisible(id: appID) { await model.run(includeSources: true) }
    }

    // MARK: Content

    @ViewBuilder private func content(_ app: GitOpsApp) -> some View {
        VStack(spacing: 0) {
            header(app)
            Divider()
            Picker("Section", selection: Binding(get: { tab(for: app) }, set: { picked = $0 })) {
                ForEach(tabs(for: app)) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(Spacing.m)
            Group {
                switch tab(for: app) {
                case .resources: ArgoResourcesTab(app: app)
                case .diff: app.tool == .argoCD ? AnyView(ArgoDiffTab(app: app, session: model.session, connection: connection, connect: { connectSheet = true })) : AnyView(FluxDiffTab())
                case .history: app.tool == .argoCD ? AnyView(ArgoHistoryTab(app: app) { id in present(.argoRollback, historyID: id) }) : AnyView(FluxHistoryTab(app: app))
                case .conditions: ConditionsTab(app: app, model: model)
                case .manifest: ManifestTab(app: app)
                case .status: FluxStatusTab(app: app, model: model)
                case .inventory: FluxInventoryTab(app: app)
                case .dependencies: FluxDependenciesTab(app: app, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(app.name)
        .toolbar { ToolbarItemGroup { actions(app) } }
        .overlay(alignment: .bottom) { undoBanner }
    }

    private func tabs(for app: GitOpsApp) -> [Tab] {
        if app.tool == .argoCD { return [.resources, .diff, .history, .conditions, .manifest] }
        if app.flavor == .fluxKustomization { return [.status, .inventory, .dependencies, .diff, .conditions, .manifest] }
        if app.flavor == .fluxHelmRelease { return [.status, .dependencies, .history, .conditions, .manifest] }
        return [.status, .conditions, .manifest]
    }

    private func header(_ app: GitOpsApp) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                ToolGlyph(tool: app.tool)
                Text(app.name).font(.title2.weight(.semibold))
                Text(app.flavor.title).foregroundStyle(.secondary)
                SyncPill(app: app)
                HealthPill(app: app)
                Spacer()
                HStack(spacing: 6) { Text(model.name).font(.callout); EnvBadge(model.config.environment) }
            }
            OwnershipLine(app: app)
            Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: 2) {
                if !app.source.isEmpty { GridRow { label("Source"); Text(app.source).textSelection(.enabled) } }
                GridRow { label("Revision"); RevisionText(app: app) }
                if app.tool == .argoCD {
                    let a = ArgoView(raw: app.raw)
                    GridRow { label("Destination"); Text([a.destinationServer, a.destinationNamespace].compactMap { $0 }.joined(separator: " · ")) }
                    GridRow {
                        label("Sync policy")
                        Text(a.autoSyncEnabled ? "Auto-sync on" + (a.selfHeal ? ", self-heal" : "") + (a.autoPrune ? ", prune" : "") : "Manual")
                    }
                } else if let i = FluxView(raw: app.raw, flavor: app.flavor).interval {
                    GridRow { label("Interval"); Text(i) }
                }
                if let m = app.message, !m.isEmpty { GridRow { label("Message"); Text(m).textSelection(.enabled).foregroundStyle(.secondary) } }
            }
            .font(.callout)
        }
        .padding(Spacing.m)
    }

    private func label(_ s: String) -> some View { Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing) }

    // MARK: Actions

    @ViewBuilder private func actions(_ app: GitOpsApp) -> some View {
        if app.tool == .flux {
            Button { present(optionKey ? .fluxReconcileWithSource : .fluxReconcile) } label: { Label("Reconcile", systemImage: "arrow.clockwise") }
                .help("Reconcile now. Hold Option to fetch the source first.")
            Menu {
                Button("Reconcile") { present(.fluxReconcile) }
                if !app.flavor.isSource, app.flavor == .fluxKustomization || app.flavor == .fluxHelmRelease {
                    Button("Reconcile with Source") { present(.fluxReconcileWithSource) }
                }
                if app.flavor == .fluxHelmRelease {
                    Divider()
                    Button("Force…") { present(.fluxForce) }
                    Button("Reset (retries exhausted)…") { present(.fluxReset) }
                }
                Divider()
                if app.suspended { Button("Resume") { present(.fluxResume) } } else { Button("Suspend") { present(.fluxSuspend) } }
            } label: { Label("More", systemImage: "ellipsis.circle") }
        } else {
            let a = ArgoView(raw: app.raw)
            Button { present(optionKey ? .argoHardRefresh : .argoRefresh) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Refresh from Git. Hold Option for a hard refresh.")
            Button { syncSheet = true } label: { Label("Sync…", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(a.isSyncRunning)
            Menu {
                Button("Refresh") { present(.argoRefresh) }
                Button("Hard Refresh") { present(.argoHardRefresh) }
                Divider()
                Button("Sync…") { syncSheet = true }.disabled(a.isSyncRunning)
                Button("Terminate Sync…") { present(.argoTerminate) }.disabled(!a.isSyncRunning)
                Divider()
                if a.autoSyncEnabled { Button("Disable Auto-Sync…") { present(.argoDisableAutoSync) } }
                else { Button("Enable Auto-Sync…") { present(.argoEnableAutoSync, sync: ArgoSyncRequest(prune: false)) } }
                Button("Roll Back…") { picked = .history }
                Divider()
                Button("Connect to Argo CD…") { connectSheet = true }
            } label: { Label("More", systemImage: "ellipsis.circle") }
        }
    }

    private var optionKey: Bool { NSEvent.modifierFlags.contains(.option) }

    private func present(_ kind: GitOpsActionPlan.Kind, sync: ArgoSyncRequest = ArgoSyncRequest(), historyID: Int? = nil) {
        guard let app else { return }
        do {
            let plan = try GitOpsPlanner.plan(kind, app: app, detection: model.detection, sync: sync, historyID: historyID)
            request = TidesConfirmations.request(plan: plan, cluster: model.config, client: model.session.client, detection: model.detection) { applied in
                if let inverse = applied.inverse { undo = UndoOffer(message: "\(applied.title): done", inverse: inverse) }
            }
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// The Undo toast: opens the inverse confirmation (never applies anything by itself).
    @ViewBuilder private var undoBanner: some View {
        if let undo {
            HStack {
                Text(undo.message)
                Button("Undo…") { let inverse = undo.inverse; self.undo = nil; present(inverse) }
                Button("Dismiss") { self.undo = nil }
            }
            .padding(Spacing.m)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding()
            .task(id: undo) { try? await Task.sleep(for: .seconds(10)); self.undo = nil }
            .transition(.opacity)
        }
    }
}

// MARK: - Ownership line (also what the editor and Chart Room show through the badge slot)

private struct OwnershipLine: View {
    let app: GitOpsApp
    var body: some View {
        if app.tool == .flux, !app.flavor.isSource, let owner = GitOpsOwnershipDetector.detect(app.raw) {
            Label("Itself managed by \(owner.tool == .flux ? "Flux" : "Argo CD"): \(owner.name)", systemImage: "arrow.triangle.branch")
                .font(.footnote).foregroundStyle(Palette.infoText)
        }
    }
}

// MARK: - Argo tabs

private struct ArgoResourcesTab: View {
    let app: GitOpsApp
    @State private var onlyOutOfSync = false

    var body: some View {
        let all = ArgoView(raw: app.raw).resources
        let rows = onlyOutOfSync ? all.filter { $0.sync == .outOfSync } : all
        VStack(alignment: .leading, spacing: 0) {
            Toggle("Only out of sync (\(all.filter { $0.sync == .outOfSync }.count) of \(all.count))", isOn: $onlyOutOfSync).padding(.horizontal, Spacing.m)
            if rows.isEmpty {
                ContentUnavailableView(all.isEmpty ? "No managed resources" : "Everything is in sync", systemImage: "checkmark.circle")
            } else {
                Table(rows) {
                    TableColumn("Kind") { r in Text(r.kind) }.width(min: 90, ideal: 120)
                    TableColumn("Name") { r in
                        HStack { Text(r.name); if r.requiresPruning { StatusPill(tone: .critical, text: "Prune", symbol: "trash") } }
                    }
                    TableColumn("Namespace") { r in Text(r.namespace ?? "-") }
                    TableColumn("Sync") { r in StatusPill(tone: r.sync.tone, text: r.sync == .outOfSync ? "Out of Sync" : r.sync.rawValue) }.width(min: 90, ideal: 110)
                    TableColumn("Health") { r in
                        if let h = r.health { StatusPill(tone: h.tone, text: h.rawValue) } else { Text("-").foregroundStyle(.secondary) }
                    }.width(min: 90, ideal: 110)
                    TableColumn("Message") { r in Text(r.healthMessage ?? "").foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }
}

private struct ArgoDiffTab: View {
    let app: GitOpsApp
    let session: ClusterSession
    let connection: ArgoConnection
    let connect: () -> Void
    @State private var phase: Phase = .idle
    enum Phase { case idle, loading, loaded([ArgoManagedResource]), failed(String) }

    var body: some View {
        let api = connection.api(for: session)
        let outOfSync = ArgoView(raw: app.raw).outOfSyncResources
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if api == nil {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        Text("Out-of-sync resources").font(.headline)
                        Text("Full desired-versus-live diffs come from the Argo CD API. Connect once per cluster with an Argo CD token (kept on this Mac only, never synced) to see them here.")
                            .foregroundStyle(.secondary)
                        Button("Connect to Argo CD…", action: connect)
                    }
                    ForEach(outOfSync) { r in Label(r.display, systemImage: "doc.badge.ellipsis").font(.callout) }
                    if outOfSync.isEmpty { Text("Nothing is out of sync.").foregroundStyle(.secondary) }
                } else {
                    switch phase {
                    case .idle, .loading: ProgressView("Asking Argo CD")
                    case .failed(let message):
                        Text(message).foregroundStyle(Palette.criticalText)
                        Button("Connect to Argo CD…", action: connect)
                    case .loaded(let items):
                        let changed = items.filter(\.modified)
                        if changed.isEmpty { Text("Live state matches Git for all \(items.count) managed resources.").foregroundStyle(.secondary) }
                        ForEach(changed) { r in
                            DisclosureGroup(r.display) { DiffText(lines: r.diff()) }
                        }
                    }
                }
            }
            .padding(Spacing.m)
        }
        .task(id: app.id + "\(app.raw.value(at: "status.sync.revision")?.stringValue ?? "")") { await load(api) }
    }

    private func load(_ api: ArgoAPI?) async {
        guard let api else { return }
        phase = .loading
        do { phase = .loaded(try await api.managedResources(application: app.name, appNamespace: app.namespace)) }
        catch { phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
    }
}

private struct DiffText: View {
    let lines: [DiffLine]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.filter { $0.kind != .context }) { l in
                Text((l.kind == .added ? "+ " : "- ") + l.text)
                    .font(.whCode)
                    .foregroundStyle(l.kind == .added ? Palette.healthyText : Palette.criticalText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct ArgoHistoryTab: View {
    let app: GitOpsApp
    let rollback: (Int) -> Void
    var body: some View {
        let entries = ArgoView(raw: app.raw).history.sorted { $0.id > $1.id }
        if entries.isEmpty {
            ContentUnavailableView("No history", systemImage: "clock")
        } else {
            Table(entries) {
                TableColumn("#") { e in Text("\(e.id)").monospacedDigit() }.width(40)
                TableColumn("Revision") { e in Text(GitOpsRevision.short(e.revision ?? e.revisions.first) ?? "-").font(.whCode) }.width(min: 90, ideal: 120)
                TableColumn("Deployed") { e in if let d = e.deployedAt { Text(d, style: .date) + Text(" ") + Text(d, style: .time) } else { Text("-") } }
                TableColumn("By") { e in Text(e.initiatedBy ?? "-") }
                TableColumn("") { e in Button("Roll Back…") { rollback(e.id) } }.width(100)
            }
        }
    }
}

// MARK: - Flux tabs

private struct FluxStatusTab: View {
    let app: GitOpsApp
    let model: TidesClusterModel
    var body: some View {
        let f = FluxView(raw: app.raw, flavor: app.flavor)
        Form {
            Section("Ready") {
                if let r = f.readyCondition {
                    LabeledContent("Status", value: r.status)
                    if let reason = r.reason { LabeledContent("Reason", value: reason) }
                    if let m = r.message { LabeledContent("Message") { Text(m).textSelection(.enabled) } }
                } else { Text("No Ready condition yet.").foregroundStyle(.secondary) }
                if f.reconciling { Label("Reconciling", systemImage: "arrow.clockwise") }
                if f.stalled { Label("Stalled", systemImage: "exclamationmark.octagon").foregroundStyle(Palette.criticalText) }
                if f.suspended { Label("Suspended: Flux is not reconciling this object", systemImage: "pause.circle") }
            }
            Section("Source and revision") {
                if let s = f.sourceRef { LabeledContent("Source", value: "\(s.kind ?? "")/\(s.name)" + (s.namespace.map { " (\($0))" } ?? "")) }
                if let u = f.url { LabeledContent("URL") { Text(u).textSelection(.enabled) } }
                if let p = f.path { LabeledContent("Path", value: p) }
                LabeledContent("Last applied", value: GitOpsRevision.short(f.lastAppliedRevision ?? f.artifactRevision) ?? "-")
                LabeledContent("Last attempted", value: GitOpsRevision.short(f.lastAttemptedRevision) ?? "-")
                if let i = f.interval { LabeledContent("Interval", value: i) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct FluxInventoryTab: View {
    let app: GitOpsApp
    var body: some View {
        let entries = FluxView(raw: app.raw, flavor: app.flavor).inventory
        if entries.isEmpty {
            ContentUnavailableView("No inventory", systemImage: "tray", description: Text("Flux has not recorded applied objects yet."))
        } else {
            Table(entries) {
                TableColumn("Kind") { e in Text(e.kind) }
                TableColumn("Name") { e in Text(e.name) }
                TableColumn("Namespace") { e in Text(e.namespace ?? "-") }
                TableColumn("Group") { e in Text(e.group.isEmpty ? "core" : e.group).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct FluxDependenciesTab: View {
    let app: GitOpsApp
    let model: TidesClusterModel
    var body: some View {
        let deps = FluxView(raw: app.raw, flavor: app.flavor).dependsOn
        let all = model.apps
        if deps.isEmpty {
            ContentUnavailableView("No dependencies", systemImage: "point.3.connected.trianglepath.dotted")
        } else {
            List(deps, id: \.name) { d in
                let target = all.first { $0.name == d.name && $0.namespace == d.namespace }
                HStack {
                    Text(d.name)
                    Text(d.namespace ?? "").foregroundStyle(.secondary)
                    Spacer()
                    if let target { HealthPill(app: target) } else { Text("not found").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

private struct FluxHistoryTab: View {
    let app: GitOpsApp
    var body: some View {
        let history = FluxView(raw: app.raw, flavor: app.flavor).helmHistory
        if history.isEmpty {
            ContentUnavailableView("No Helm history", systemImage: "clock")
        } else {
            Table(history) {
                TableColumn("#") { h in Text(h.version.map(String.init) ?? "-").monospacedDigit() }.width(40)
                TableColumn("Chart") { h in Text("\(h.chartName ?? "") \(h.chartVersion ?? "")") }
                TableColumn("App version") { h in Text(h.appVersion ?? "-") }
                TableColumn("Status") { h in Text(h.status ?? "-") }
                TableColumn("Deployed") { h in if let d = h.deployed { Text(d, style: .relative) } else { Text("-") } }
            }
        }
    }
}

private struct FluxDiffTab: View {
    var body: some View {
        ContentUnavailableView("Diff needs a local checkout", systemImage: "doc.on.doc",
                               description: Text("Flux does not keep the desired manifests in the cluster. Mapping a local folder and running `flux diff kustomization` in a guarded terminal session arrives with the terminal add-on."))
    }
}

// MARK: - Shared tabs

private struct ConditionsTab: View {
    let app: GitOpsApp
    let model: TidesClusterModel

    var body: some View {
        let conditions = app.tool == .argoCD ? ArgoView(raw: app.raw).conditions : GitOpsCondition.list(app.raw)
        let events = model.session.store(for: KubeEvent.self, namespace: app.namespace, fieldSelector: "involvedObject.name=\(app.name)")
        List {
            Section("Conditions") {
                if conditions.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(conditions) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(c.type).fontWeight(.medium); Text(c.status).foregroundStyle(.secondary); Spacer(); if let t = c.lastTransition { Text(t, style: .relative).foregroundStyle(.secondary) } }
                        if let m = c.message { Text(m).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
            Section("Events") {
                let items = events.items.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
                if items.isEmpty { Text("None").foregroundStyle(.secondary) }
                ForEach(items, id: \.metadata.uid) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(e.reason ?? "").fontWeight(.medium).foregroundStyle(e.isWarning ? Palette.warningText : Color.primary); Spacer(); if let t = e.lastSeen { Text(t, style: .relative).foregroundStyle(.secondary) } }
                        if let m = e.message { Text(m).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                    }
                }
            }
        }
        .whileVisible(id: app.id) { await events.run() }
    }
}

private struct ManifestTab: View {
    let app: GitOpsApp
    var body: some View {
        var raw = app.raw
        raw["metadata"]?["managedFields"] = nil
        return ScrollView {
            Text(YAMLCodec.dump(raw)).font(.whCode).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.m)
        }
    }
}
