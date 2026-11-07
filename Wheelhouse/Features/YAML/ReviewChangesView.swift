import SwiftUI
import Observation
import WheelhouseKit
import WheelhouseUI

/// S15: diff of the edit against the live object, server dry-run, then Apply through the confirmation sheet.
@MainActor @Observable
final class ReviewModel {
    enum Phase { case loading, noChanges, conflict(latest: JSONValue), ready, failed(KubeError) }
    enum DryRun: Equatable { case idle, running, passed, invalid([YAMLIssue]), error(String) }

    let editor: YAMLEditorModel
    private(set) var phase: Phase = .loading
    private(set) var dryRun: DryRun = .idle
    private(set) var diff: [DiffLine] = []
    private(set) var stats = LineDiff.Stats(added: 0, removed: 0)
    var expandedFolds: Set<Int> = []
    private(set) var latest: JSONValue = .null
    private(set) var edited: JSONValue = .null
    private(set) var fieldManagers: [String] = []
    /// Field paths that changed both in my edit and on the server during the last rebase (mine won). Shown inside the review.
    private(set) var rebaseConflicts: [String] = []

    init(editor: YAMLEditorModel) { self.editor = editor }

    var rows: [DiffRow] { LineDiff.fold(diff, context: 3, expanded: expandedFolds) }

    var gitOpsManagers: [String] {
        fieldManagers.filter { m in ["argo", "flux", "helm", "kustomize"].contains { m.lowercased().contains($0) } }
    }

    /// Fetches the object fresh, checks `resourceVersion`, computes the diff and runs the server dry-run.
    func start() async {
        phase = .loading
        dryRun = .idle
        guard let parsed = YAMLEditValidator.validate(text: editor.draft, ref: editor.ref).value else {
            phase = .failed(.invalid(message: "The YAML has errors. Fix them in the editor first.", causes: []))
            return
        }
        edited = parsed
        do {
            let fresh = try await editor.client.getRaw(editor.ref.kind, name: editor.ref.name, namespace: editor.ref.namespace)
            latest = fresh
            fieldManagers = Array(Set((fresh.value(at: "metadata.managedFields")?.arrayValue ?? []).compactMap { $0["manager"]?.stringValue })).sorted()
            if YAMLNormalizer.resourceVersion(of: fresh) != editor.resourceVersion {
                phase = .conflict(latest: fresh)
                return
            }
            diff = LineDiff.diff(old: editor.comparable(YAMLNormalizer.editable(fresh)), new: editor.comparable(parsed))
            stats = LineDiff.stats(diff)
            guard stats.total > 0 else { phase = .noChanges; return }
            phase = .ready
            await runDryRun()
        } catch let e as KubeError {
            phase = .failed(e)
        } catch {
            phase = .failed(.unreachable(cause: error.localizedDescription))
        }
    }

    private func body() -> JSONValue {
        YAMLNormalizer.replaceBody(edited: edited, original: latest, resourceVersion: editor.resourceVersion)
    }

    func runDryRun() async {
        dryRun = .running
        dryRun = await performDryRun()
    }

    func performDryRun() async -> DryRun {
        do {
            _ = try await editor.client.replace(editor.ref.kind, name: editor.ref.name, namespace: editor.ref.namespace, body: body(), options: MutationOptions(dryRun: true))
            return .passed
        } catch let e as KubeError {
            if case .conflict = e { phase = .conflict(latest: await refreshedLatest()); return .error(e.summary) }
            switch e {
            case .invalid: return .invalid(YAMLIssues.issues(from: e, text: editor.draft))
            case .forbidden, .readOnly: return .error(e.summary)
            default: return .error(e.summary)
            }
        } catch { return .error(error.localizedDescription) }
    }

    /// Real apply. Re-checks the resourceVersion first so even clients that don't enforce it (demo) report conflicts.
    func apply() async throws {
        let fresh = try await editor.client.getRaw(editor.ref.kind, name: editor.ref.name, namespace: editor.ref.namespace)
        if YAMLNormalizer.resourceVersion(of: fresh) != editor.resourceVersion {
            latest = fresh
            phase = .conflict(latest: fresh)
            throw KubeError.conflict(message: "The object was modified by someone else while you were editing.")
        }
        do {
            let result = try await editor.client.replace(editor.ref.kind, name: editor.ref.name, namespace: editor.ref.namespace, body: body(), options: MutationOptions())
            editor.didApply(result)
        } catch KubeError.conflict(let m) {
            phase = .conflict(latest: await refreshedLatest())
            throw KubeError.conflict(message: m)
        }
    }

    /// A 409 means `latest` is stale: fetch the server's current copy so Rebase merges onto what is really there.
    private func refreshedLatest() async -> JSONValue {
        if let fresh = try? await editor.client.getRaw(editor.ref.kind, name: editor.ref.name, namespace: editor.ref.namespace) { latest = fresh }
        return latest
    }

    /// Re-applies my edits onto the newest server copy.
    func rebase() async {
        guard case .conflict(let latest) = phase else { return }
        let result = YAMLRebase.rebase(base: YAMLNormalizer.editable(editor.live), edited: edited, onto: YAMLNormalizer.editable(latest))
        editor.adoptRebase(draft: YAMLCodec.dump(result.merged), latest: latest)
        rebaseConflicts = result.conflicts
        await start()
    }
}

struct ReviewChangesView: View {
    let editor: YAMLEditorModel
    var onJump: @MainActor @Sendable (Int) -> Void
    var onDone: @MainActor @Sendable () -> Void

    @State private var model: ReviewModel
    @State private var confirm: ConfirmRequest?
    @State private var split = false
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(\.dismiss) private var dismiss

    init(editor: YAMLEditorModel, onJump: @escaping @MainActor @Sendable (Int) -> Void, onDone: @escaping @MainActor @Sendable () -> Void) {
        self.editor = editor
        self.onJump = onJump
        self.onDone = onDone
        _model = State(initialValue: ReviewModel(editor: editor))
    }

    private var ref: ResourceRef { editor.ref }
    private var canApply: Bool {
        if case .ready = model.phase, model.dryRun == .passed, !editor.cluster.readOnly { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ContextLine(cluster: editor.cluster, namespace: ref.namespace, kind: ref.kind.kind)
                    OwnershipBadgeSlot()   // empty until M9 injects a GitOps owner
                    if editor.cluster.isProduction {
                        Label("Production cluster. You’ll be asked to type “\(ref.name)” to apply.", systemImage: "shield.lefthalf.filled")
                            .font(.footnote).foregroundStyle(Palette.envProduction)
                    }
                    content
                }
                .padding(Spacing.l)
            }
            .background(Palette.groupedBackground)
            .navigationTitle("Review Changes")
            .whInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Back to Editor") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { presentConfirm() }
                        .buttonStyle(.glassProminent)
                        .disabled(!canApply)
                        .keyboardShortcut(.return, modifiers: .command)
                        .accessibilityIdentifier("yaml.review.apply")
                }
            }
            .confirmSheet($confirm)
        }
        .task { await model.start() }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if !model.rebaseConflicts.isEmpty { rebaseBanner }
        switch model.phase {
        case .loading:
            HStack(spacing: 10) { ProgressView(); Text("Comparing with the live object…").foregroundStyle(.secondary) }
                .frame(maxWidth: .infinity).padding(.vertical, Spacing.xxxl)
        case .noChanges:
            EmptyState(.empty(title: "No Changes", systemImage: "equal.circle", hint: "Your YAML matches the live object."))
                .frame(minHeight: 260)
        case .failed(let error):
            if case .invalid(let m, _) = error { StateBanner(.custom(tone: .critical, symbol: "xmark.octagon.fill", title: "Can’t review", message: m)) }
            else { EmptyState(EmptyStateKind(error: error, clusterName: editor.cluster.name)).frame(minHeight: 260) }
        case .conflict(let latest):
            conflictView(latest)
        case .ready:
            summary
            dryRunSection
            diffSection
        }
    }

    /// Rebase kept my values for fields that also changed on the server; the user must see that before applying.
    private var rebaseBanner: some View {
        let paths = model.rebaseConflicts
        return VStack(alignment: .leading, spacing: 6) {
            StateBanner(.custom(tone: .warning, symbol: "exclamationmark.arrow.triangle.2.circlepath", title: "Rebased with \(paths.count) overlapping field\(paths.count == 1 ? "" : "s")",
                                message: "These fields also changed on the server; your values were kept. Check the diff before applying."))
            ForEach(paths.prefix(8), id: \.self) { Text($0.isEmpty ? "(root)" : $0).font(.whCodeSmall).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if paths.count > 8 { Text("+ \(paths.count - 8) more").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private var summary: some View {
        VStack(spacing: 0) {
            summaryRow("Method", "Replace (PUT)")
            Divider()
            summaryRow("Concurrency", "resourceVersion \(editor.resourceVersion ?? "–")")
            Divider()
            summaryRow("Changes", "+\(model.stats.added)  −\(model.stats.removed) lines")
            if !model.fieldManagers.isEmpty {
                Divider()
                summaryRow("Managed by", model.fieldManagers.joined(separator: ", "))
            }
        }
        .padding(.horizontal, Spacing.m)
        .whCard()
        .overlay(alignment: .bottom) { EmptyView() }
        .accessibilityElement(children: .combine)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: Spacing.m)
            Text(value).font(.whCode).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    @ViewBuilder private var dryRunSection: some View {
        switch model.dryRun {
        case .idle, .running:
            StateBanner(.custom(tone: .info, symbol: "hourglass", title: "Server dry-run…", message: "Validating with the API server. Nothing is changed."))
        case .passed:
            StateBanner(.custom(tone: .healthy, symbol: "checkmark.circle.fill", title: "Dry-run passed", message: "The API server accepted these changes. Nothing has been changed yet."))
        case .error(let message):
            StateBanner(.custom(tone: .critical, symbol: "xmark.octagon.fill", title: "Dry-run failed", message: message))
        case .invalid(let issues):
            VStack(alignment: .leading, spacing: Spacing.s) {
                StateBanner(.custom(tone: .critical, symbol: "xmark.octagon.fill", title: "Validation failed", message: "\(issues.count) problem\(issues.count == 1 ? "" : "s") reported by the API server."))
                ForEach(issues) { issue in
                    Button {
                        if let line = issue.line { onJump(line) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let field = issue.field { Text(field).font(.whCodeSmall).foregroundStyle(Palette.criticalText) }
                            Text(issue.message).font(.footnote).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            if let line = issue.line { Text("Line \(line) · tap to fix in editor").font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .background(Palette.critical.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(issue.line == nil)
                }
            }
        }
        if !model.gitOpsManagers.isEmpty {
            StateBanner(.custom(tone: .warning, symbol: "arrow.triangle.2.circlepath", title: "Managed by \(model.gitOpsManagers.joined(separator: ", "))", message: "A GitOps controller may revert this change on its next sync."))
        }
    }

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                SectionHeader("Changes")
                Spacer()
                if hSize == .regular {
                    Picker("Layout", selection: $split) {
                        Text("Unified").tag(false)
                        Text("Split").tag(true)
                    }
                    .pickerStyle(.segmented).frame(width: 190)
                }
            }
            DiffView(rows: model.rows, split: split && hSize == .regular) { id in model.expandedFolds.insert(id) }
        }
    }

    private func conflictView(_ latest: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            StateBanner(.custom(tone: .warning, symbol: "exclamationmark.arrow.triangle.2.circlepath", title: "Changed on the server",
                                message: "\(ref.name) was modified since you opened it (resourceVersion \(editor.resourceVersion ?? "–") → \(YAMLNormalizer.resourceVersion(of: latest) ?? "–")). Rebase to re-apply your edits on top of the newest version, or discard them."))
            Button { Task { await model.rebase() } } label: {
                Label("Rebase My Edits", systemImage: "arrow.triangle.merge").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent).controlSize(.large)
            Button(role: .destructive) { editor.cancelEdit(); Task { await editor.load() }; onDone() } label: {
                Label("Discard My Edits & Reload", systemImage: "trash").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass).controlSize(.large)
        }
    }

    // MARK: Apply

    private func presentConfirm() {
        let stats = model.stats
        confirm = ConfirmRequest(
            title: "Apply changes to \(ref.name)?",
            message: "Replaces \(ref.kind.kind.lowercased())/\(ref.name) with your edited YAML (+\(stats.added) −\(stats.removed) lines).",
            verb: "Apply Changes",
            cluster: editor.cluster,
            namespace: ref.namespace,
            resource: "\(ref.kind.kind.lowercased())/\(ref.name)",
            confirmationText: ref.name,
            facts: [
                .init("Method", "Replace (PUT)"),
                .init("Concurrency", "resourceVersion \(editor.resourceVersion ?? "–")"),
                .init("Changes", "+\(stats.added) −\(stats.removed) lines"),
            ],
            isDisruptive: true,
            dryRun: { [model] in
                switch await model.performDryRun() {
                case .passed: return .passed("Server dry-run passed. Nothing has changed yet.")
                case .invalid(let issues): return .failed(issues.map { [$0.field, $0.message].compactMap { $0 }.joined(separator: ": ") }.joined(separator: "\n"))
                case .error(let m): return .failed(m)
                default: return .failed("Dry-run did not complete")
                }
            },
            action: { [model, onDone] in
                try await model.apply()
                onDone()
            })
    }
}

// MARK: - Diff rendering

struct DiffView: View {
    let rows: [DiffRow]
    var split: Bool
    var expand: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if split { splitBody } else { unifiedBody }
        }
        .background(Color.whCardBackground, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
    }

    private var unifiedBody: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                switch row {
                case .line(let l): lineView(l)
                case .fold(let id, let count): foldView(id, count)
                }
            }
        }
    }

    private func lineView(_ l: DiffLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(l.oldNumber)
            number(l.newNumber)
            Text(marker(l.kind)).font(.whCode.bold()).foregroundStyle(tint(l.kind)).frame(width: 18)
            Text(verbatim: l.text.isEmpty ? " " : l.text).font(.whCode).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .padding(.vertical, 1)
        .background(background(l.kind))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(l.kind == .added ? "Added" : l.kind == .removed ? "Removed" : "Unchanged"): \(l.text)")
    }

    private func foldView(_ id: Int, _ count: Int) -> some View {
        Button { expand(id) } label: {
            Label("\(count) unchanged line\(count == 1 ? "" : "s")", systemImage: "chevron.up.chevron.down")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 6)
                .background(Palette.fieldFill)
        }
        .buttonStyle(.plain)
    }

    // Split layout: pair removed/added runs side by side.
    private struct Pair: Identifiable { let id: String; var left: DiffLine?; var right: DiffLine?; var fold: (Int, Int)? }

    private var pairs: [Pair] {
        var out: [Pair] = []
        var removed: [DiffLine] = []
        var added: [DiffLine] = []
        func flush() {
            for i in 0..<max(removed.count, added.count) {
                out.append(Pair(id: "p\(removed.indices.contains(i) ? removed[i].id : added[i].id)-\(i)", left: removed.indices.contains(i) ? removed[i] : nil, right: added.indices.contains(i) ? added[i] : nil))
            }
            removed = []; added = []
        }
        for row in rows {
            switch row {
            case .fold(let id, let count): flush(); out.append(Pair(id: "f\(id)", fold: (id, count)))
            case .line(let l):
                switch l.kind {
                case .removed: removed.append(l)
                case .added: added.append(l)
                case .context: flush(); out.append(Pair(id: "c\(l.id)", left: l, right: l))
                }
            }
        }
        flush()
        return out
    }

    private var splitBody: some View {
        LazyVStack(spacing: 0) {
            ForEach(pairs) { p in
                if let fold = p.fold { foldView(fold.0, fold.1) }
                else {
                    HStack(alignment: .top, spacing: 1) {
                        half(p.left, side: .removed)
                        half(p.right, side: .added)
                    }
                }
            }
        }
    }

    private func half(_ l: DiffLine?, side: DiffLine.Kind) -> some View {
        HStack(alignment: .top, spacing: 0) {
            number(side == .removed ? l?.oldNumber : l?.newNumber)
            Text(verbatim: (l?.text.isEmpty ?? true) ? " " : (l?.text ?? " ")).font(.whCode).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(l.map { $0.kind == .context ? Color.clear : background($0.kind) } ?? Palette.fieldFill.opacity(0.5))
    }

    private func number(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "").font(.whCodeSmall).foregroundStyle(.tertiary).frame(width: 34, alignment: .trailing).padding(.trailing, 4)
            .accessibilityHidden(true)
    }
    private func marker(_ k: DiffLine.Kind) -> String { k == .added ? "+" : k == .removed ? "−" : " " }
    private func tint(_ k: DiffLine.Kind) -> Color { k == .added ? Palette.healthyText : k == .removed ? Palette.criticalText : .secondary }
    private func background(_ k: DiffLine.Kind) -> Color { k == .added ? Palette.diffAdd.opacity(0.16) : k == .removed ? Palette.diffDelete.opacity(0.14) : .clear }
}
