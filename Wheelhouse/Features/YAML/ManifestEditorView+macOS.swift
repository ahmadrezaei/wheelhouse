import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The Mac Manifest Editor (DESIGN-MAC section 6.8): what `Route.yaml` opens on the Mac. It is the iOS editor's flow with the same
/// model, the same Review sheet and the same dry-run, apply and `resourceVersion` rules, plus schema validation, completion, hover,
/// folding, a multi-document outline, Edit / Diff / Live segments and the GitOps ownership warning.
struct ManifestEditorView: View {
    let ref: ResourceRef
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        if let cluster = registry.config(for: ref.clusterID), let key = registry.screenKey(for: ref.clusterID), let session = registry.session(for: ref.clusterID) {
            ManifestEditorContent(model: YAMLEditorModel(ref: ref, cluster: cluster, client: session.client), session: session)
                .id("\(ref.id)|\(key)")
        } else {
            EmptyState(.error(message: "This cluster is no longer available."))
        }
    }
}

private struct ManifestEditorContent: View {
    @State var model: YAMLEditorModel
    let session: ClusterSession
    @State private var assist: ManifestAssistModel?
    @State private var controller = CodeEditorController()
    @State private var liveController = CodeEditorController()
    @State private var showReview = false
    @State private var confirmDiscard = false
    @State private var segment: ManifestSegment = .edit
    @State private var showOutline = true
    @State private var expandedFolds: Set<Int> = []
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppPreferences.self) private var preferences

    init(model: YAMLEditorModel, session: ClusterSession) {
        _model = State(initialValue: model)
        self.session = session
    }

    private var analysis: ManifestAnalysis { assist?.analysis ?? ManifestAnalysis() }

    var body: some View {
        VStack(spacing: Spacing.s) {
            header
            switch model.phase {
            case .loading:
                EmptyState(.loading)
            case .failed(let error):
                EmptyState(EmptyStateKind(error: error, clusterName: model.cluster.name)) {
                    Button("Try Again") { Task { await model.load() } }.buttonStyle(.glass)
                }
            case .loaded:
                if model.isEditing { segmentPicker }
                HStack(spacing: 0) {
                    if showOutline, analysis.outline.count > 1 { outline.frame(width: 210) }
                    VStack(spacing: Spacing.s) { content }
                }
                if model.isEditing, segment == .edit { lintBar }
            }
        }
        .background(Palette.groupedBackground)
        .onAppear { model.revealOncePerSession = { [preferences] in preferences.revealSecretsOncePerSession } }
        .navigationTitle(model.ref.name)
        .navigationBarBackButtonHidden(model.isEditing)
        .toolbar { toolbar }
        .task { await model.load() }
        .onAppear {
            SchemaServices.shared.editorOpened()
            if assist == nil { assist = ManifestAssistModel(session: session, namespace: model.ref.namespace) }
        }
        .onDisappear { SchemaServices.shared.editorClosed() }
        .onChange(of: model.draft) { model.draftChanged(); assist?.textChanged(model.editorText) }
        .onChange(of: model.isEditing) {
            assist?.textChanged(model.editorText, immediately: true)
            segment = .edit
            if model.isEditing { Task { await assist?.activate() } }          // schemas load on Edit, not on viewing
        }
        .onChange(of: model.showServerFields) { assist?.textChanged(model.editorText, immediately: true) }
        .onChange(of: model.live) { assist?.textChanged(model.editorText, immediately: true) }
        .onChange(of: assist != nil) { assist?.textChanged(model.editorText, immediately: true) }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, model.secretRevealed, !model.isEditing { model.secretRevealed = false }
        }
        .resolvingGitOpsOwner(of: model.live.isNull ? nil : model.live, cluster: model.ref.clusterID)
        .sheet(isPresented: $showReview) {
            ReviewChangesView(editor: model, onJump: { line in
                showReview = false
                Task { try? await Task.sleep(for: .milliseconds(350)); controller.jump(toLine: line) }
            }, onDone: {
                showReview = false
            })
            .frame(minWidth: 760, minHeight: 600)
        }
        .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { model.cancelEdit() }
            Button("Keep Editing", role: .cancel) {}
        }
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ContextLine(cluster: model.cluster, namespace: model.ref.namespace, kind: model.ref.kind.kind)
            if let n = model.notice {
                StateBanner(.custom(tone: n.tone, symbol: n.tone.symbol, title: n.text, message: nil))
            }
            if case .loaded = model.phase {
                if model.cluster.readOnly {
                    StateBanner(.readOnly)
                } else if !model.canUpdate {
                    StateBanner(.custom(tone: .warning, symbol: "hand.raised", title: "Read-only for you", message: "Your account isn’t allowed to update this object. The editor is view-only."))
                }
                if model.isEditing { GitOpsWarning() }
                if model.isSecret {
                    StateBanner(.custom(tone: model.secretRevealed ? .warning : .info, symbol: model.secretRevealed ? "eye.fill" : "eye.slash.fill",
                                        title: model.secretRevealed ? "Secret values are visible" : "Secret values are hidden",
                                        message: model.secretRevealed ? "They hide again when you leave the app." : "Reveal them with Touch ID to read or edit.")) {
                        if !model.isEditing {
                            Button(model.secretRevealed ? "Hide Values" : "Reveal Values", systemImage: model.secretRevealed ? "eye.slash" : "touchid") {
                                Task { await model.revealSecret() }
                            }
                            .font(.footnote.weight(.semibold)).padding(.top, 2)
                        }
                    }
                }
                if model.showServerFields && !model.isEditing {
                    StateBanner(.custom(tone: .info, symbol: "server.rack", title: "Showing server fields", message: "status, uid and resourceVersion are visible. managedFields stay hidden. Read-only."))
                }
                if let note = analysis.schemaNote {
                    StateBanner(.custom(tone: .info, symbol: "doc.text.magnifyingglass", title: note, message: nil))
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
    }

    // MARK: Segments and content

    private var segmentPicker: some View {
        Picker("View", selection: $segment) {
            ForEach(ManifestSegment.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 280)
        .accessibilityIdentifier("manifest.segments")
    }

    @ViewBuilder private var content: some View {
        switch model.isEditing ? segment : .edit {
        case .edit: editor
        case .diff: diffView
        case .live: liveView
        }
    }

    private var editor: some View {
        YAMLCodeEditor(
            text: Binding(get: { model.editorText }, set: { model.editorText = $0 }),
            isEditable: model.isEditing,
            wraps: model.wraps,
            diagnostics: model.isEditing ? model.diagnostics : [],
            controller: controller,
            schemaDiagnostics: model.isEditing ? analysis.schemaIssues : [],
            folds: analysis.folds,
            collapsedByDefault: ManifestFolding.defaultCollapsed(in: model.editorText, folds: analysis.folds),
            assist: assist)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, model.isEditing ? 0 : Spacing.s)
            .accessibilityLabel(model.isEditing ? "YAML editor" : "YAML of \(model.ref.name)")
    }

    private var liveText: String {
        var object = YAMLNormalizer.withoutManagedFields(model.live)
        if model.isSecret, !model.secretRevealed { object = SecretMasking.masked(object, fingerprint: false) }
        return YAMLCodec.dump(object)
    }

    private var liveView: some View {
        YAMLCodeEditor(text: .constant(liveText), isEditable: false, wraps: model.wraps, controller: liveController)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, Spacing.s)
            .accessibilityLabel("Live YAML of \(model.ref.name)")
    }

    @ViewBuilder private var diffView: some View {
        if let parsed = model.parsedDraft {
            let lines = LineDiff.diff(old: model.comparable(YAMLNormalizer.editable(model.live)), new: model.comparable(parsed))
            ScrollView {
                if lines.contains(where: { $0.kind != .context }) {
                    DiffView(rows: LineDiff.fold(lines, context: 3, expanded: expandedFolds), split: false) { expandedFolds.insert($0) }
                        .padding(Spacing.l)
                } else {
                    EmptyState(.empty(title: "No Changes", systemImage: "equal.circle", hint: "Your YAML matches the live object."))
                        .frame(minHeight: 200)
                }
            }
        } else {
            EmptyState(.empty(title: "Fix the YAML first", systemImage: "xmark.octagon", hint: "The diff needs valid YAML."))
        }
    }

    // MARK: Outline

    private var outline: some View {
        List(analysis.outline) { item in
            Button { controller.jump(toLine: item.startLine) } label: {
                HStack(spacing: 6) {
                    Text(item.title).font(.callout).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if item.errors > 0 { badge(item.errors, Palette.critical) }
                    if item.warnings > 0 { badge(item.warnings, Palette.warning) }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.title), \(item.errors) errors, \(item.warnings) warnings")
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("manifest.outline")
    }

    private func badge(_ n: Int, _ color: Color) -> some View {
        Text("\(n)").font(.caption2.weight(.semibold)).foregroundStyle(.white)
            .padding(.horizontal, 5).padding(.vertical, 1).background(color, in: Capsule())
    }

    // MARK: Lint bar

    /// Every finding the editor shows, in text order: YAML syntax first, then schema findings.
    private var issues: [(line: Int, message: String, error: Bool)] {
        (model.diagnostics.map { ($0.line, $0.message, $0.severity == .error) }
            + analysis.schemaIssues.map { ($0.span.line, $0.message, $0.severity == .error) })
            .sorted { $0.line < $1.line }
    }

    private func nextIssue() {
        let all = issues
        guard !all.isEmpty else { return }
        let target = all.first { $0.line > controller.caretLine } ?? all[0]
        controller.jump(toLine: target.line)
    }

    private var lintBar: some View {
        let all = issues
        return HStack(spacing: 8) {
            if let first = all.first {
                Button { controller.jump(toLine: first.line) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: first.error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill").foregroundStyle(first.error ? Palette.critical : Palette.warning)
                        Text("Line \(first.line): \(first.message)").lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(first.error ? Palette.criticalText : Palette.warningText)
                }
                .buttonStyle(.plain)
                Spacer(minLength: 0)
                if all.count > 1 {
                    Menu("\(all.count) issues") {
                        ForEach(Array(all.prefix(40).enumerated()), id: \.offset) { _, issue in
                            Button("Line \(issue.line): \(issue.message)") { controller.jump(toLine: issue.line) }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityIdentifier("manifest.issues")
                }
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy)
                Text(model.hasChanges ? "Valid YAML · \(model.changeStats.total) changed line\(model.changeStats.total == 1 ? "" : "s")" : "Valid YAML · no changes")
                Spacer(minLength: 0)
            }
        }
        .font(.footnote).foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if model.isEditing {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { model.isDirty ? (confirmDiscard = true) : model.cancelEdit() }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(model.ref.name).font(.headline).lineLimit(1)
                    Text(model.hasChanges ? "Edited · \(model.changeStats.total) change\(model.changeStats.total == 1 ? "" : "s")" : "No changes")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Review & Apply") { controller.dismissKeyboard(); showReview = true }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.hasErrors || !model.hasChanges)
                    .accessibilityIdentifier("yaml.review")
            }
        } else if case .loaded = model.phase, model.canEdit {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit", systemImage: "pencil") { Task { await model.beginEdit() } }
                    .accessibilityIdentifier("yaml.edit")
            }
        }
        ToolbarItem(placement: .secondaryAction) {
            Menu {
                Toggle("Soft Wrap", systemImage: "text.word.spacing", isOn: $model.wraps)
                Toggle("Outline", systemImage: "sidebar.left", isOn: $showOutline)
                if !model.isEditing {
                    Toggle("Show Server Fields", systemImage: "server.rack", isOn: $model.showServerFields)
                }
                Divider()
                Button("Find", systemImage: "magnifyingglass") { controller.find() }
                    .keyboardShortcut("f", modifiers: .command)
                if model.isEditing {
                    Button("Suggest (⎋ or F5)", systemImage: "text.badge.plus") { controller.complete() }
                    Button("Next Issue", systemImage: "exclamationmark.triangle") { nextIssue() }
                        .keyboardShortcut("'", modifiers: .command)
                    Button("Toggle Comment", systemImage: "number") { controller.toggleComment() }
                        .keyboardShortcut("/", modifiers: .command)
                }
                Button("Fold All", systemImage: "arrow.down.right.and.arrow.up.left") { controller.foldAll() }
                    .keyboardShortcut(.leftArrow, modifiers: [.option, .command])
                Button("Unfold All", systemImage: "arrow.up.left.and.arrow.down.right") { controller.unfoldAll() }
                    .keyboardShortcut(.rightArrow, modifiers: [.option, .command])
                if !model.isEditing {
                    Divider()
                    Button("Copy YAML", systemImage: "doc.on.doc") { Pasteboard.copy(model.viewText) }
                        .disabled(model.isSecret && !model.secretRevealed)
                    Button("Reload", systemImage: "arrow.clockwise") { Task { await model.load() } }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled({ if case .loaded = model.phase { false } else { true } }())
        }
    }
}

/// "Managed by Flux Kustomization apps": a change made here may be reverted at the next reconcile. Empty while no owner is known
/// (the detector is injected by the Mac app; see `GitOpsOwnership`).
private struct GitOpsWarning: View {
    @Environment(\.gitOpsOwner) private var owner

    var body: some View {
        if let owner {
            let tool = owner.tool == .flux ? "Flux" : "Argo CD"
            StateBanner(.custom(tone: .warning, symbol: "arrow.triangle.2.circlepath", title: "Managed by \(tool): \(owner.name)",
                                message: "\(tool) may revert a change made here at its next sync. Prefer changing the source in Git."))
                .accessibilityIdentifier("manifest.gitops")
        }
    }
}
