import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Owns the detail model for one release, so a table redraw never recreates it.
struct ReleaseDetailHost: View {
    @State private var model: ReleaseDetailModel
    let owner: GitOpsOwner?

    init(session: ClusterSession, services: ChartRoomServices, release: HelmReleaseSummary, owner: GitOpsOwner?, onDrift: ((DriftState) -> Void)? = nil) {
        let m = ReleaseDetailModel(session: session, services: services, namespace: release.namespace, name: release.name, summary: release)
        m.onDrift = onDrift
        _model = State(initialValue: m)
        self.owner = owner
    }

    var body: some View { ReleaseDetailView(model: model, owner: owner) }
}

/// A standalone release pane (`WorkspaceDestination.helmRelease`).
struct ReleaseScreen: View {
    let ref: HelmReleaseRef
    @Environment(ClusterRegistry.self) private var registry
    @Environment(\.chartRoomServices) private var services

    var body: some View {
        if let session = registry.session(for: ref.clusterID) {
            ReleaseStandalone(session: session, services: services, ref: ref)
        } else {
            ContentUnavailableView("Cluster Not Found", systemImage: "server.rack", description: Text("This pane refers to a cluster that is no longer configured."))
        }
    }
}

private struct ReleaseStandalone: View {
    @State private var model: ReleaseDetailModel
    init(session: ClusterSession, services: ChartRoomServices, ref: HelmReleaseRef) {
        _model = State(initialValue: ReleaseDetailModel(session: session, services: services, namespace: ref.namespace, name: ref.name, revision: ref.revision))
    }
    var body: some View { ReleaseDetailView(model: model, owner: nil) }
}

enum ReleaseTab: String, CaseIterable, Identifiable {
    case resources = "Resources", values = "Values", manifest = "Manifest", notes = "Notes", history = "History", hooks = "Hooks"
    var id: String { rawValue }
}

struct ReleaseDetailView: View {
    @Bindable var model: ReleaseDetailModel
    let owner: GitOpsOwner?
    @State private var tab: ReleaseTab = .resources
    @State private var reveal = RevealState()

    var body: some View {
        VStack(spacing: 0) {
            switch model.phase {
            case .loading:
                EmptyState(.loading)
            case .notFound:
                EmptyState(.empty(title: "Release Not Found", systemImage: "shippingbox", hint: "\(model.name) is not stored in \(model.namespace) any more."))
            case .failed(let message):
                EmptyState(.error(message: message)) { Button("Retry") { Task { await model.load() } } }
            case .loaded:
                header
                Divider()
                if let shown = model.shownRevision, shown.status.isPending { pendingBanner.padding([.horizontal, .top], Spacing.l) }
                Picker("Section", selection: $tab) { ForEach(ReleaseTab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().padding(Spacing.m)
                tabContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: model.name + model.namespace) {
            if model.summary == nil { await model.load() } else { await model.decodeShown() }
        }
        .accessibilityIdentifier("chartroom-release-detail")
    }

    // MARK: Header

    private var header: some View {
        let shown = model.shownRevision
        let release = model.release
        return VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                Text(model.name).font(.title2.weight(.semibold))
                if let status = shown?.status { HelmStatusPill(status: status) }
                if let owner { OwnershipBadgeSlot().environment(\.gitOpsOwner, owner) }
                Spacer()
                actions
            }
            HStack(spacing: Spacing.m) {
                if let chart = release?.chart.metadata {
                    Label("\(chart.name)-\(chart.version)" + (chart.appVersion.map { " → app \($0)" } ?? ""), systemImage: "shippingbox")
                }
                Label(model.namespace, systemImage: "square.dashed")
                if let shown { Label("revision \(shown.revision)", systemImage: "number") }
                if let date = release?.info.lastDeployed ?? shown?.modifiedAt {
                    Label(date.formatted(.relative(presentation: .numeric)), systemImage: "clock")
                }
            }
            .font(.footnote).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            if let shown, let current = model.summary?.current, shown.revision != current.revision {
                StateBanner(.custom(tone: .info, symbol: "clock.arrow.circlepath", title: "Viewing revision \(shown.revision)",
                                    message: "The current revision is \(current.revision).")) {
                    Button("Show Current") { Task { await model.show(revision: current.revision) } }.buttonStyle(.link)
                }
            }
            if let error = model.decodeError {
                StateBanner(.custom(tone: .warning, symbol: "exclamationmark.triangle", title: "This revision could not be read", message: error))
            }
        }
        .padding(Spacing.l)
    }

    private var actions: some View {
        HStack(spacing: Spacing.s) {
            Button("Upgrade…") {}.disabled(true)
            Button("Roll Back…") {}.disabled(true)
            Button("Uninstall…", role: .destructive) {}.disabled(true)
            Menu {
                Button("Copy helm status Command") { Pasteboard.copy("helm status \(model.name) -n \(model.namespace)") }
                Button("Copy helm get values Command") { Pasteboard.copy("helm get values \(model.name) -n \(model.namespace)") }
                Button("Copy helm history Command") { Pasteboard.copy("helm history \(model.name) -n \(model.namespace)") }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .help("Upgrade, roll back and uninstall arrive with the write path (M6b)")
    }

    private var pendingBanner: some View {
        StateBanner(.custom(tone: .warning, symbol: "hourglass", title: "A previous operation didn't finish",
                            message: "Roll back to the last deployed revision, or wait if an upgrade is still running in CI."))
    }

    // MARK: Tabs

    @ViewBuilder private var tabContent: some View {
        if model.release == nil && tab != .history {
            if model.decodeError == nil { EmptyState(.loading) } else { EmptyState(.empty(title: "No Details", systemImage: "doc.questionmark", hint: "The record could not be decoded.")) }
        } else {
            switch tab {
            case .resources: ResourcesTab(model: model).task(id: model.shownRevision?.id) { await model.checkDrift() }
            case .values: ValuesTab(model: model, reveal: $reveal)
            case .manifest: ManifestTab(model: model, reveal: $reveal)
            case .notes: NotesTab(release: model.release)
            case .history: HistoryTab(model: model)
            case .hooks: HooksTab(release: model.release, reveal: $reveal)
            }
        }
    }
}

// MARK: - Reveal (Touch ID)

/// Release values and Secret objects in a manifest stay masked until the user reveals them: the release record is a Secret.
struct RevealState {
    var revealed = false
}

private struct RevealButton: View {
    @Binding var reveal: RevealState
    @Environment(AppPreferences.self) private var preferences
    @State private var failure: String?

    var body: some View {
        Button {
            if reveal.revealed { reveal.revealed = false; return }
            Task {
                let ok = await SecretRevealGate.shared.authorize(oncePerSession: preferences.revealSecretsOncePerSession) {
                    await AppLockController.authenticate(reason: "Reveal Helm release values")
                }
                if ok { reveal.revealed = true; failure = nil } else { failure = "Authentication was not completed." }
            }
        } label: {
            Label(reveal.revealed ? "Hide" : "Reveal…", systemImage: reveal.revealed ? "eye.slash" : "eye")
        }
        .help(failure ?? "Values under keys that look sensitive are masked until you authenticate")
    }
}

// MARK: - Values

private struct ValuesTab: View {
    @Bindable var model: ReleaseDetailModel
    @Binding var reveal: RevealState
    @State private var computed = false

    var body: some View {
        let release = model.release
        let values = (computed ? release?.computedValues : release?.config) ?? .object([:])
        VStack(spacing: 0) {
            HStack {
                Picker("Values", selection: $computed) {
                    Text("User-supplied").tag(false)
                    Text("Computed (--all)").tag(true)
                }.pickerStyle(.segmented).frame(maxWidth: 280).labelsHidden()
                Spacer()
                if HelmValuesMask.containsSensitiveValues(values) { RevealButton(reveal: $reveal) }
            }
            .padding(.horizontal, Spacing.l).padding(.bottom, Spacing.s)
            CodeView(HelmValuesMask.yaml(values, revealed: reveal.revealed), language: .yaml, showsLineNumbers: true)
                .padding(.horizontal, Spacing.l).padding(.bottom, Spacing.l)
        }
    }
}

// MARK: - Manifest

private struct ManifestTab: View {
    @Bindable var model: ReleaseDetailModel
    @Binding var reveal: RevealState
    @State private var selected: String?
    @State private var against: Source = .release
    @State private var expanded: Set<Int> = []
    enum Source: String, CaseIterable, Identifiable { case release = "Release", diff = "Diff against live"; var id: String { rawValue } }

    var body: some View {
        let objects = HelmManifest.objects(in: model.release?.manifest ?? "")
        let current = objects.first { $0.id == selected } ?? objects.first
        HSplitView {
            List(objects, selection: $selected) { o in
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.name).fontWeight(.medium)
                    Text(o.kind).font(.caption).foregroundStyle(.secondary)
                }.tag(o.id)
            }
            .frame(minWidth: 160, idealWidth: 200, maxWidth: 280)
            VStack(spacing: 0) {
                HStack {
                    Picker("Source", selection: $against) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 280).labelsHidden()
                    Spacer()
                    if current?.kind == "Secret" { RevealButton(reveal: $reveal) }
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
                if let current {
                    switch against {
                    case .release:
                        CodeView(current.displayYAML(revealed: reveal.revealed), language: .yaml, showsLineNumbers: true)
                            .padding([.horizontal, .bottom], Spacing.l)
                    case .diff:
                        liveDiff(for: current)
                    }
                } else {
                    EmptyState(.empty(title: "No Objects", systemImage: "doc", hint: "This release has an empty manifest."))
                }
            }
        }
        .task(id: against) { if against == .diff { await model.checkDrift() } }
    }

    @ViewBuilder private func liveDiff(for object: HelmManifestObject) -> some View {
        if let drift = model.driftReport?.objects.first(where: { $0.id == object.id }) {
            switch drift.state {
            case .missing: EmptyState(.empty(title: "Not In The Cluster", systemImage: "questionmark.folder", hint: "This object is in the release manifest but the cluster does not have it."))
            case .unreadable(let why): EmptyState(.empty(title: "Can't Read The Live Object", systemImage: "hand.raised", hint: why))
            case .inSync: EmptyState(.empty(title: "In Sync", systemImage: "checkmark.circle", hint: "Everything the manifest sets matches the cluster."))
            case .drifted:
                let rows = LineDiff.fold(LineDiff.diff(old: drift.desiredYAML, new: drift.liveYAML), context: 3, expanded: expanded)
                ScrollView { DiffView(rows: rows, split: false, expand: { expanded.insert($0) }).padding([.horizontal, .bottom], Spacing.l) }
            }
        } else {
            EmptyState(.loading)
        }
    }
}

// MARK: - Resources

private struct ResourcesTab: View {
    @Bindable var model: ReleaseDetailModel

    var body: some View {
        let objects = HelmManifest.objects(in: model.release?.manifest ?? "")
        VStack(spacing: 0) {
            HStack {
                switch model.driftState {
                case .checking: ProgressView().controlSize(.small); Text("Checking live objects…").font(.footnote).foregroundStyle(.secondary)
                case .checked(let drifted, let total):
                    if drifted == 0 { Label("All \(total) objects match the manifest", systemImage: "checkmark.circle").foregroundStyle(Palette.healthyText) }
                    else { Label("\(drifted) of \(total) objects differ from the manifest", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warningText) }
                case .unavailable(let why): Label(why, systemImage: "hand.raised").foregroundStyle(.secondary)
                case nil: Text("Drift not checked").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await model.checkDrift(force: true) } } label: { Label("Check Drift", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(model.driftState == .checking)
            }
            .font(.footnote).padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Table(objects) {
                TableColumn("") { o in driftDot(for: o) }.width(24)
                TableColumn("Kind") { o in Text(o.kind) }.width(min: 90, ideal: 120)
                TableColumn("Name") { o in Text(o.name).fontWeight(.medium) }.width(min: 140, ideal: 200)
                TableColumn("Namespace") { o in Text(o.namespace ?? model.namespace).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
                TableColumn("Live") { o in Text(entry(for: o)?.liveSummary ?? "").foregroundStyle(.secondary) }.width(min: 70, ideal: 100)
            }
        }
    }

    private func entry(for object: HelmManifestObject) -> HelmDrift.ObjectDrift? { model.driftReport?.objects.first { $0.id == object.id } }

    @ViewBuilder private func driftDot(for object: HelmManifestObject) -> some View {
        switch entry(for: object)?.state {
        case nil: Circle().fill(Color.secondary.opacity(0.25)).frame(width: 8, height: 8).help("Not checked")
        case .inSync: Circle().fill(Palette.healthy).frame(width: 8, height: 8).help("In sync")
        case .drifted(let paths): Circle().fill(Palette.warning).frame(width: 8, height: 8).help("Differs: \(paths.prefix(3).joined(separator: ", "))")
        case .missing: Circle().fill(Palette.critical).frame(width: 8, height: 8).help("Missing from the cluster")
        case .unreadable(let why): Circle().fill(Color.secondary).frame(width: 8, height: 8).help(why)
        }
    }
}

// MARK: - Notes

struct NotesTab: View {
    let release: HelmRelease?

    var body: some View {
        let notes = release?.info.notes ?? ""
        if notes.isEmpty {
            EmptyState(.empty(title: "No Notes", systemImage: "note.text", hint: "This chart has no NOTES.txt."))
        } else {
            ScrollView {
                Text(Self.linked(notes)).font(.whCode).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.l)
            }
        }
    }

    /// NOTES.txt in monospace, with links clickable.
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let attributed = Range(range, in: out) else { continue }
            out[attributed].link = url
        }
        return out
    }
}

// MARK: - Hooks

private struct HooksTab: View {
    let release: HelmRelease?
    @Binding var reveal: RevealState
    @State private var selected: String?

    var body: some View {
        let hooks = release?.hooks ?? []
        if hooks.isEmpty {
            EmptyState(.empty(title: "No Hooks", systemImage: "link", hint: "This release has no hooks."))
        } else {
            VSplitView {
                Table(hooks.sorted { ($0.weight, $0.name) < ($1.weight, $1.name) }, selection: $selected) {
                    TableColumn("Name") { h in Text(h.name).fontWeight(.medium) }.width(min: 140, ideal: 200)
                    TableColumn("Kind") { h in Text(h.kind) }.width(min: 80, ideal: 100)
                    TableColumn("Events") { h in Text(h.events.joined(separator: ", ")).foregroundStyle(.secondary) }.width(min: 120, ideal: 180)
                    TableColumn("Weight") { h in Text("\(h.weight)").monospacedDigit() }.width(56)
                    TableColumn("Delete policy") { h in Text(h.deletePolicies.joined(separator: ", ")).foregroundStyle(.secondary) }.width(min: 100, ideal: 140)
                    TableColumn("Last run") { h in
                        if let run = h.lastRun {
                            StatusPill(tone: run.phase == "Succeeded" ? .healthy : run.phase == "Failed" ? .critical : .warning, text: run.phase)
                        } else { Text("—").foregroundStyle(.tertiary) }
                    }.width(min: 90, ideal: 110)
                }
                .frame(minHeight: 120)
                if let hook = hooks.first(where: { $0.id == selected }) {
                    VStack(alignment: .trailing, spacing: 0) {
                        if hook.kind == "Secret" { RevealButton(reveal: $reveal).padding(.horizontal, Spacing.l).padding(.top, Spacing.s) }
                        CodeView(hookYAML(hook), language: .yaml).padding(Spacing.l)
                    }
                } else {
                    Text("Select a hook to see its manifest.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    private func hookYAML(_ hook: HelmRelease.Hook) -> String {
        guard let object = HelmManifest.objects(in: hook.manifest).first else { return hook.manifest }
        return object.displayYAML(revealed: reveal.revealed)
    }
}

// MARK: - History and compare

private struct HistoryTab: View {
    @Bindable var model: ReleaseDetailModel
    @State private var selection: Set<String> = []
    @State private var showCompare = false

    var body: some View {
        let history = model.summary?.history ?? []
        let chosen = history.filter { selection.contains($0.id) }.map(\.revision).sorted()
        VStack(spacing: 0) {
            HStack {
                Button("View Revision") { if chosen.count == 1 { Task { await model.show(revision: chosen[0]) } } }
                    .disabled(chosen.count != 1)
                Button("Compare") {
                    showCompare = true
                    Task { await model.compare(chosen[0], chosen[1]) }
                }
                .disabled(chosen.count != 2)
                .help("Select two revisions to compare their values and manifests")
                Button("Roll Back to This Revision…") {}.disabled(true).help("Arrives with the write path (M6b)")
                Spacer()
                Text("\(history.count) revision\(history.count == 1 ? "" : "s")").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Table(history, selection: $selection) {
                TableColumn("Rev") { r in Text("\(r.revision)").monospacedDigit().task { await model.ensureRevision(r) } }.width(44)
                TableColumn("Status") { r in HelmStatusPill(status: r.status) }.width(min: 110, ideal: 130)
                TableColumn("Chart") { r in Text(model.revisions[r.revision].map { "\($0.chart.metadata.name)-\($0.chart.metadata.version)" } ?? "—").foregroundStyle(.secondary) }
                    .width(min: 120, ideal: 160)
                TableColumn("App version") { r in Text(model.revisions[r.revision]?.chart.metadata.appVersion ?? "—").foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                TableColumn("Updated") { r in
                    Text((model.revisions[r.revision]?.info.lastDeployed ?? r.modifiedAt).map { $0.formatted(.dateTime.month().day().hour().minute()) } ?? "—")
                        .foregroundStyle(.secondary)
                }.width(min: 100, ideal: 120)
                TableColumn("Description") { r in Text(model.revisions[r.revision]?.info.description ?? "").foregroundStyle(.secondary) }.width(min: 120, ideal: 200)
            }
        }
        .sheet(isPresented: $showCompare) { ComparisonSheet(model: model) }
    }
}

private struct ComparisonSheet: View {
    @Bindable var model: ReleaseDetailModel
    @Environment(\.dismiss) private var dismiss
    @State private var part = 0
    @State private var selected: String?
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compare Revisions").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(Spacing.l)
            Divider()
            if let error = model.comparisonError {
                EmptyState(.error(message: error))
            } else if let c = model.comparison {
                Picker("Part", selection: $part) {
                    Text("Values (+\(c.valuesStats.added) −\(c.valuesStats.removed))").tag(0)
                    Text("Manifest (+\(c.added) ~\(c.changed) −\(c.removed))").tag(1)
                }.pickerStyle(.segmented).labelsHidden().padding(Spacing.m)
                if part == 0 {
                    if c.valuesDiff.isEmpty || c.valuesStats.total == 0 {
                        EmptyState(.empty(title: "Values Are The Same", systemImage: "equal.circle", hint: "Secret values are compared by fingerprint and never shown."))
                    } else {
                        ScrollView { DiffView(rows: LineDiff.fold(c.valuesDiff, context: 3, expanded: expanded), split: false, expand: { expanded.insert($0) }).padding(Spacing.l) }
                    }
                } else {
                    HSplitView {
                        List(c.objects.filter { $0.change != .unchanged }, selection: $selected) { o in
                            HStack {
                                Text(o.change == .added ? "+" : o.change == .removed ? "−" : "~").font(.whCode.bold())
                                    .foregroundStyle(o.change == .added ? Palette.healthyText : o.change == .removed ? Palette.criticalText : Palette.warningText)
                                Text(o.id).font(.callout).lineLimit(1)
                            }.tag(o.id)
                        }
                        .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                        Group {
                            if let o = c.objects.first(where: { $0.id == selected }) {
                                ScrollView { DiffView(rows: LineDiff.fold(o.diff, context: 3, expanded: expanded), split: false, expand: { expanded.insert($0) }).padding(Spacing.l) }
                            } else {
                                Text(c.objects.contains { $0.change != .unchanged } ? "Select an object." : "The manifests are identical.")
                                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                    }
                }
            } else {
                EmptyState(.loading)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
    }
}
