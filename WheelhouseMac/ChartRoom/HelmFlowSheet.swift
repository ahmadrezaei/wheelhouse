import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Completions and hover for a Helm values file, from the schema engine's `ValuesSchemaHints` (no cluster involved).
@MainActor
final class ValuesAssist: EditorAssisting {
    var hints: ValuesSchemaHints?
    init(hints: ValuesSchemaHints?) { self.hints = hints }
    func completions(text: String, offset: Int) async -> ManifestCompletionResult {
        hints?.completions(text: text, offset: offset) ?? ManifestCompletionResult(range: NSRange(location: offset, length: 0), items: [])
    }
    func hover(text: String, offset: Int) async -> ManifestHover? { hints?.hover(text: text, offset: offset) }
}

/// The install, upgrade, roll back and uninstall flow in one sheet: configure, review, confirm (the app's ConfirmSheet), progress.
struct HelmFlowSheet: View {
    @Bindable var model: HelmFlowModel
    @Environment(\.dismiss) private var dismiss
    @State private var findings: [ManifestDiagnostic] = []
    @State private var controller = CodeEditorController()
    @State private var assist: ValuesAssist

    init(model: HelmFlowModel) {
        self.model = model
        _assist = State(initialValue: ValuesAssist(hints: model.hints))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch model.step {
            case .configure: configure
            case .working(let text): VStack { ProgressView(text).padding() }.frame(maxWidth: .infinity, maxHeight: .infinity)
            case .review: HelmReviewView(model: model)
            case .running, .finished: progress
            }
            Divider()
            footer
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 560, idealHeight: 640)
        .sheet(item: $model.confirm) { request in ConfirmSheet(request) }
        .accessibilityIdentifier("chartroom-helm-flow")
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "shippingbox")
            Text("\(model.kind.title) \(model.releaseName.isEmpty ? "a chart" : model.releaseName)").font(.headline)
            EnvBadge(model.clusterConfig.environment)
            if model.clusterConfig.readOnly { FlagBadge("read-only", tone: .warning) }
            Spacer()
        }
        .padding(Spacing.l)
    }

    // MARK: Configure

    private var configure: some View {
        VStack(spacing: 0) {
            Form {
                if model.kind == .install { TextField("Release name", text: $model.releaseName) }
                TextField("Namespace", text: $model.namespace).disabled(model.kind != .install)
                if model.kind == .install || model.kind == .upgrade {
                    TextField("Chart (repo/name, path or oci://)", text: $model.chart)
                    TextField("Chart version (empty: latest)", text: $model.chartVersion)
                }
                if model.kind == .rollback {
                    Picker("Revision", selection: $model.targetRevision) {
                        ForEach(model.revisions, id: \.revision) { Text("\($0.revision)  \($0.status.rawValue)").tag(Optional($0.revision)) }
                    }
                }
                options
            }
            .formStyle(.grouped)
            .frame(maxHeight: model.kind == .install || model.kind == .upgrade ? 280 : .infinity)
            if model.kind == .install || model.kind == .upgrade {
                Divider()
                HStack {
                    Text("Values").font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(hintSummary).font(.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
                YAMLCodeEditor(text: $model.valuesText, isEditable: true, wraps: false, controller: controller, schemaDiagnostics: findings, assist: assist)
                    .padding(.horizontal, Spacing.l)
                    .accessibilityLabel("Values")
                if let first = findings.first(where: { $0.severity == .error }) {
                    Label(first.message, systemImage: "xmark.octagon.fill").font(.footnote).foregroundStyle(Palette.criticalText).padding(Spacing.s)
                }
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(Palette.criticalText).padding(Spacing.m).textSelection(.enabled)
            }
        }
        .task(id: model.valuesText) {
            guard let hints = model.hints else { findings = []; return }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            let text = model.valuesText
            findings = await Self.validate(hints, text)
        }
        .onChange(of: model.hints?.origin) { assist.hints = model.hints }
    }

    /// Off the main actor: a values file can be long.
    @concurrent private static func validate(_ hints: ValuesSchemaHints, _ text: String) async -> [ManifestDiagnostic] { hints.diagnostics(for: text) }

    private var hintSummary: String {
        switch model.hints?.origin {
        case .schema?: "Checked against the chart's values.schema.json"
        case .inferred?: "Types inferred from the chart's default values"
        default: "No schema for this chart"
        }
    }

    @ViewBuilder private var options: some View {
        switch model.kind {
        case .install:
            Toggle("Create the namespace", isOn: $model.createNamespace)
            Toggle("Skip CRDs", isOn: $model.skipCRDs)
        case .upgrade:
            Toggle("Keep the release's values and apply the new chart defaults", isOn: $model.resetThenReuse)
                .help("Needs helm 3.14 or newer")
            Toggle("Skip CRDs", isOn: $model.skipCRDs)
        case .uninstall:
            Toggle("Keep the release history", isOn: $model.keepHistory)
        case .rollback:
            EmptyView()
        }
        if model.kind != .uninstall {
            Toggle("Wait for the resources to be ready", isOn: $model.wait)
        }
        if model.kind == .install || model.kind == .upgrade {
            Toggle("Roll back automatically on failure", isOn: $model.rollbackOnFailure)
        }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            switch model.step {
            case .running: HStack { ProgressView().controlSize(.small); Text("helm is running…") }
            case .finished(let ok):
                Label(ok ? "\(model.kind.title) finished" : "\(model.kind.title) failed", systemImage: ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(ok ? Palette.healthyText : Palette.criticalText)
                if let error = model.error { Text(error).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            default: EmptyView()
            }
            ScrollView { Text(model.output.isEmpty ? " " : model.output).font(.whCode).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        }
        .padding(Spacing.l)
        .accessibilityIdentifier("chartroom-helm-progress")
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            switch model.step {
            case .configure:
                if let blocker = model.blocker { Text(blocker).font(.footnote).foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review…") { Task { await model.prepareReview() } }.keyboardShortcut(.defaultAction).disabled(model.blocker != nil)
            case .working:
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            case .review:
                Button("Back") { model.backToConfigure() }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("\(model.kind.title)…", role: model.kind == .uninstall ? .destructive : nil) { model.confirm = model.makeConfirmRequest() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.clusterConfig.readOnly)
                    .help(model.clusterConfig.readOnly ? "\(model.clusterConfig.name) is read-only. Allow changes in Cluster Settings." : "")
            case .running:
                Spacer()
                Button("Stop helm", role: .destructive) { model.cancel() }
            case .finished:
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(Spacing.l)
    }
}

// MARK: - Review

/// The diff, the hooks, the warnings and the exact object set (ARCHITECTURE-MAC section 5.2, step 4).
struct HelmReviewView: View {
    let model: HelmFlowModel
    @State private var part = 0
    @State private var selected: String?
    @State private var expanded: Set<Int> = []

    var body: some View {
        guard let review = model.review else { return AnyView(EmptyView()) }
        return AnyView(content(review))
    }

    private func content(_ review: HelmReviewData) -> some View {
        VStack(spacing: 0) {
            if !review.plan.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(review.plan.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warningText).font(.callout) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.m)
            }
            HStack {
                Text(summary(review)).font(.callout.weight(.medium))
                Spacer()
                Picker("Part", selection: $part) {
                    Text("Changes").tag(0)
                    Text("Hooks (\(review.plan.hooks.count))").tag(1)
                    Text("May change (\(review.plan.objects.count))").tag(2)
                    if review.notes != nil { Text("Notes").tag(3) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 460)
            }
            .padding(Spacing.m)
            Divider()
            switch part {
            case 0: changes(review)
            case 1: hooks(review)
            case 2: granted(review)
            default: ScrollView { Text(review.notes ?? "").font(.whCode).textSelection(.enabled).padding(Spacing.l).frame(maxWidth: .infinity, alignment: .leading) }
            }
        }
    }

    private func summary(_ review: HelmReviewData) -> String {
        if let c = review.comparison { return "+\(c.added) created  ~\(c.changed) changed  −\(c.removed) deleted" }
        if !review.created.isEmpty { return "+\(review.created.count) objects will be created" }
        if !review.removed.isEmpty { return "−\(review.removed.count) objects will be deleted" }
        return "No object changes"
    }

    @ViewBuilder private func changes(_ review: HelmReviewData) -> some View {
        if let c = review.comparison {
            HSplitView {
                List(c.objects.filter { $0.change != .unchanged }, selection: $selected) { o in
                    HStack {
                        Text(o.change == .added ? "+" : o.change == .removed ? "−" : "~").font(.whCode.bold())
                            .foregroundStyle(o.change == .added ? Palette.healthyText : o.change == .removed ? Palette.criticalText : Palette.warningText)
                        Text(o.id).font(.callout).lineLimit(1)
                    }.tag(o.id)
                }
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
                if let o = c.objects.first(where: { $0.id == selected }) {
                    ScrollView { DiffView(rows: LineDiff.fold(o.diff, context: 3, expanded: expanded), split: false, expand: { expanded.insert($0) }).padding(Spacing.l) }
                } else {
                    Text(c.objects.contains { $0.change != .unchanged } ? "Select an object." : "The manifests are identical.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        } else {
            let objects = review.created.isEmpty ? review.removed : review.created
            List(objects, selection: $selected) { o in
                Label(o.id, systemImage: review.created.isEmpty ? "minus.circle" : "plus.circle").tag(o.id)
            }
        }
    }

    @ViewBuilder private func hooks(_ review: HelmReviewData) -> some View {
        if review.plan.hooks.isEmpty {
            EmptyState(.empty(title: "No Hooks", systemImage: "link", hint: "This operation runs no hooks."))
        } else {
            Table(review.plan.hooks.sorted { ($0.weight, $0.name) < ($1.weight, $1.name) }) {
                TableColumn("Name") { Text($0.name).fontWeight(.medium) }
                TableColumn("Kind") { Text($0.kind) }.width(80)
                TableColumn("Events") { Text($0.events.joined(separator: ", ")).foregroundStyle(.secondary) }
                TableColumn("Weight") { Text("\($0.weight)").monospacedDigit() }.width(56)
                TableColumn("Delete policy") { Text($0.deletePolicies.joined(separator: ", ")).foregroundStyle(.secondary) }
            }
        }
    }

    private func granted(_ review: HelmReviewData) -> some View {
        let rows = review.plan.objects.sorted { ($0.resource, $0.namespace ?? "", $0.name ?? $0.namePrefix ?? $0.generateNamePrefix ?? "") < ($1.resource, $1.namespace ?? "", $1.name ?? $1.namePrefix ?? $1.generateNamePrefix ?? "") }
        return VStack(alignment: .leading, spacing: 0) {
            Text("helm may change exactly these objects while it runs. A request for anything else is refused and logged.")
                .font(.footnote).foregroundStyle(.secondary).padding(Spacing.m)
            List(rows, id: \.self) { o in
                HStack {
                    Text(o.group.isEmpty ? o.resource : "\(o.resource).\(o.group)").frame(minWidth: 180, alignment: .leading)
                    Text(o.namespace ?? "(cluster)").foregroundStyle(.secondary).frame(minWidth: 100, alignment: .leading)
                    Text(o.name ?? o.namePrefix.map { "\($0)*" } ?? o.generateNamePrefix.map { "\($0)*" } ?? "").font(.whCode)
                }
            }
        }
    }
}
