import SwiftUI
import WheelhouseKit
import WheelhouseUI

extension HelmReleaseStatus {
    var tone: StatusTone {
        switch self {
        case .deployed: .healthy
        case .failed: .critical
        case .pendingInstall, .pendingUpgrade, .pendingRollback, .uninstalling: .warning
        case .superseded, .uninstalled, .unknown: .unknown
        }
    }

    var symbol: String {
        switch self {
        case .deployed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .pendingInstall, .pendingUpgrade, .pendingRollback: "hourglass"
        case .uninstalling: "trash"
        case .superseded: "arrow.uturn.backward.circle"
        case .uninstalled: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var title: String { rawValue }
}

struct HelmStatusPill: View {
    let status: HelmReleaseStatus
    var body: some View { StatusPill(tone: status.tone, text: status.title, symbol: status.symbol) }
}

/// The Releases section: a table per cluster, problems first, metadata-only until a row needs more.
struct ReleasesView: View {
    @Bindable var model: ReleasesModel
    var openRelease: (HelmReleaseRef) -> Void = { _ in }
    @State private var scopeText = ""
    @State private var flow: HelmFlowModel?
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .task(id: model.scope) { await model.load() }
        .sheet(item: $flow, onDismiss: { Task { await model.load() } }) { HelmFlowSheet(model: $0) }
        .onReceive(NotificationCenter.default.publisher(for: HelmFlowModel.didChangeRelease)) { _ in Task { await model.load() } }
        .accessibilityIdentifier("chartroom-releases")
    }

    private var toolbar: some View {
        HStack(spacing: Spacing.m) {
            Picker("Namespace", selection: $model.namespaceFilter) {
                Text("All namespaces").tag(String?.none)
                ForEach(model.knownNamespaces, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: 220)
            .disabled(model.scope != nil || model.knownNamespaces.isEmpty)
            if let scope = model.scope {
                Button("Show All Namespaces") { model.scope = nil }.help("Currently reading \(scope) only")
            }
            TextField("Filter", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Spacer()
            if let count = model.listing?.releases.count, model.phase == .loaded {
                Text("\(count) release\(count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Install…") {
                flow = HelmFlowModel(kind: .install, session: model.session, services: model.services, namespace: model.scope ?? "default", makeRunner: HelmToolbox.liveRunner(env))
            }
            .help("Install a chart from a repository, a path or an OCI reference")
            Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the list (metadata only)")
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            EmptyState(.loading)
        case .failed(let message):
            EmptyState(.error(message: message)) { Button("Retry") { Task { await model.load() } } }
        case .loaded:
            if case .forbidden(let namespace)? = model.failure {
                forbiddenState(namespace: namespace)
            } else if model.visibleReleases.isEmpty {
                emptyState
            } else {
                HSplitView {
                    table.frame(minWidth: 520)
                    if let id = model.selection, let release = model.listing?.releases.first(where: { $0.id == id }) {
                        ReleaseDetailHost(session: model.session, services: model.services, release: release, owner: model.owners[id],
                                          onDrift: { [weak model] state in model?.recordDrift(id: id, state: state) })
                            .id("\(id)#\(release.current.resourceVersion ?? "")")
                            .frame(minWidth: 420, idealWidth: 520)
                    }
                }
            }
        }
    }

    // MARK: States

    private var emptyState: some View {
        let text = model.search.isEmpty && model.namespaceFilter == nil ? nil : model.search
        return Group {
            if let text, !text.isEmpty {
                EmptyState(.filteredEmpty(filter: text))
            } else {
                EmptyState(.empty(title: model.scope.map { "No Helm releases in \($0)" } ?? "No Helm releases", systemImage: "shippingbox",
                                  hint: "Releases installed with Helm appear here. Installing arrives with the write path (M6b).")) {
                    Button("Install a Chart…") {}.disabled(true).help("Arrives with the write path (M6b)")
                }
            }
        }
    }

    private func forbiddenState(namespace: String?) -> some View {
        let scope = namespace ?? "this cluster"
        return ContentUnavailableView {
            Label("Helm Releases Not Readable", systemImage: "hand.raised")
        } description: {
            Text("Helm stores releases in Secrets. You need `list secrets` in \(scope) to see them.")
        } actions: {
            Button("Copy RBAC Rule") { Pasteboard.copy(HelmReleaseCatalog.rbacRule(namespace: namespace)) }
            if namespace == nil {
                HStack {
                    TextField("Try one namespace", text: $scopeText).textFieldStyle(.roundedBorder).frame(width: 180)
                        .onSubmit { applyScope() }
                    Button("Read Namespace") { applyScope() }.disabled(scopeText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("Show All Namespaces") { model.scope = nil }
            }
        }
    }

    private func applyScope() {
        let value = scopeText.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { model.scope = value }
    }

    // MARK: Table

    private var table: some View {
        Table(model.visibleReleases, selection: $model.selection) {
            TableColumn("Status") { r in
                HelmStatusPill(status: r.current.status).help(r.current.status.isPending ? "A previous operation did not finish" : r.current.status.title)
            }.width(min: 110, ideal: 130)
            TableColumn("Release") { r in
                HStack(spacing: 6) {
                    Text(r.name).fontWeight(.medium)
                    if let owner = model.owners[r.id] { OwnershipBadgeSlot().environment(\.gitOpsOwner, owner) }
                }
                .task { await model.ensureChartInfo(for: r) }
            }.width(min: 140, ideal: 200)
            TableColumn("Namespace") { r in Text(r.namespace).foregroundStyle(.secondary) }.width(min: 90, ideal: 130)
            TableColumn("Chart") { r in Text(model.chartInfo[r.id]?.chart ?? "—").foregroundStyle(.secondary) }.width(min: 120, ideal: 170)
            TableColumn("App version") { r in Text(model.chartInfo[r.id].flatMap { $0.appVersion.isEmpty ? nil : $0.appVersion } ?? "—").foregroundStyle(.secondary) }
                .width(min: 80, ideal: 100)
            TableColumn("Rev") { r in Text("\(r.current.revision)").monospacedDigit() }.width(40)
            TableColumn("Updated") { r in
                Text((model.chartInfo[r.id]?.updated ?? r.current.modifiedAt).map { $0.formatted(.relative(presentation: .numeric)) } ?? "—")
                    .foregroundStyle(.secondary)
            }.width(min: 80, ideal: 100)
            TableColumn("Drift") { r in driftCell(model.drift[r.id]) }.width(min: 70, ideal: 90)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let r = model.listing?.releases.first(where: { $0.id == id }) { menu(for: r) }
        } primaryAction: { ids in
            if let id = ids.first, let r = model.listing?.releases.first(where: { $0.id == id }) { model.selection = id; openRelease(ref(r)) }
        }
    }

    private func ref(_ r: HelmReleaseSummary) -> HelmReleaseRef {
        HelmReleaseRef(clusterID: model.clusterID, namespace: r.namespace, name: r.name, revision: nil)
    }

    @ViewBuilder private func driftCell(_ state: DriftState?) -> some View {
        switch state {
        case nil: Text("—").foregroundStyle(.tertiary).help("Checked when you open the release")
        case .checking: ProgressView().controlSize(.small)
        case .checked(let drifted, let total):
            if drifted == 0 { Label("In sync", systemImage: "checkmark").labelStyle(.titleAndIcon).foregroundStyle(Palette.healthyText).font(.caption) }
            else { Label("\(drifted)/\(total)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warningText).font(.caption) }
        case .unavailable(let why): Text("n/a").foregroundStyle(.tertiary).help(why)
        }
    }

    @ViewBuilder private func menu(for r: HelmReleaseSummary) -> some View {
        Button("Show Values") { model.selection = r.id }
        Button("Show Manifest") { model.selection = r.id }
        Button("Compare Revisions") { model.selection = r.id }.disabled(r.history.count < 2)
        Divider()
        Button("Copy helm status Command") { Pasteboard.copy("helm status \(r.name) -n \(r.namespace)") }
        Divider()
        Button("Upgrade…") {}.disabled(true)
        Button("Roll Back…") {}.disabled(true)
        Button("Uninstall…") {}.disabled(true)
        Text("Changes arrive with the write path (M6b)")
        Divider()
        Button("Open in Deck Terminal") {}.disabled(true)
        Button("Ask First Mate") {}.disabled(true)
    }
}
