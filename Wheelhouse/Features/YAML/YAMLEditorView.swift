import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S14 + F4: view an object as YAML, edit it, review the diff, apply.
struct YAMLEditorView: View {
    let ref: ResourceRef
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        // Keyed on the cluster's config revision too: the model captures cluster + client, so a settings change rebuilds it.
        if let cluster = registry.config(for: ref.clusterID), let key = registry.screenKey(for: ref.clusterID), let session = registry.session(for: ref.clusterID) {
            YAMLEditorContent(model: YAMLEditorModel(ref: ref, cluster: cluster, client: session.client))
                .id("\(ref.id)|\(key)")
        } else {
            EmptyState(.error(message: "This cluster is no longer available."))
        }
    }
}

private struct YAMLEditorContent: View {
    @State var model: YAMLEditorModel
    @State private var controller = CodeEditorController()
    @State private var showReview = false
    @State private var confirmDiscard = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var hSize
    @Environment(AppPreferences.self) private var preferences

    init(model: YAMLEditorModel) { _model = State(initialValue: model) }

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
                editor
                if model.isEditing { lintBar }
            }
        }
        .background(Palette.groupedBackground)
        .onAppear { model.revealOncePerSession = { [preferences] in preferences.revealSecretsOncePerSession } }
        .navigationTitle(model.ref.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isEditing)
        .toolbar { toolbar }
        .task { await model.load() }
        .onChange(of: model.draft) { model.draftChanged() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, model.secretRevealed, !model.isEditing { model.secretRevealed = false }
        }
        .sheet(isPresented: $showReview) {
            ReviewChangesView(editor: model, onJump: { line in
                showReview = false
                Task { try? await Task.sleep(for: .milliseconds(350)); controller.jump(toLine: line) }
            }, onDone: {
                showReview = false
            })
            .presentationDetents([.large])
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
                if model.isSecret {
                    StateBanner(.custom(tone: model.secretRevealed ? .warning : .info, symbol: model.secretRevealed ? "eye.fill" : "eye.slash.fill",
                                        title: model.secretRevealed ? "Secret values are visible" : "Secret values are hidden",
                                        message: model.secretRevealed ? "They hide again when you leave the app." : "Reveal them with Face ID to read or edit.")) {
                        if !model.isEditing {
                            Button(model.secretRevealed ? "Hide Values" : "Reveal Values", systemImage: model.secretRevealed ? "eye.slash" : "faceid") {
                                Task { await model.revealSecret() }
                            }
                            .font(.footnote.weight(.semibold)).padding(.top, 2)
                        }
                    }
                }
                if model.showServerFields && !model.isEditing {
                    StateBanner(.custom(tone: .info, symbol: "server.rack", title: "Showing server fields", message: "status, uid and resourceVersion are visible. managedFields stay hidden. Read-only."))
                }
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, Spacing.xs)
    }

    // MARK: Editor

    private var editor: some View {
        YAMLCodeEditor(
            text: Binding(get: { model.editorText }, set: { model.editorText = $0 }),
            isEditable: model.isEditing,
            wraps: model.wraps,
            diagnostics: model.isEditing ? model.diagnostics : [],
            controller: controller)
            .padding(.horizontal, Spacing.l)
            .padding(.bottom, model.isEditing ? 0 : Spacing.s)
            .accessibilityLabel(model.isEditing ? "YAML editor" : "YAML of \(model.ref.name)")
    }

    private var lintBar: some View {
        Group {
            if let d = model.diagnostics.first {
                Button { controller.jump(toLine: d.line) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.critical)
                        Text("Line \(d.line): \(d.message)").lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .font(.footnote).foregroundStyle(Palette.criticalText)
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy)
                    Text(model.hasChanges ? "Valid YAML · \(model.changeStats.total) changed line\(model.changeStats.total == 1 ? "" : "s")" : "Valid YAML · no changes")
                    Spacer(minLength: 0)
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .accessibilityElement(children: .combine)
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
                Button("Review") { controller.dismissKeyboard(); showReview = true }
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
                if !model.isEditing {
                    Toggle("Show Server Fields", systemImage: "server.rack", isOn: $model.showServerFields)
                }
                Button("Find", systemImage: "magnifyingglass") { controller.find() }
                    .keyboardShortcut("f", modifiers: .command)
                if !model.isEditing {
                    Button("Copy YAML", systemImage: "doc.on.doc") { UIPasteboard.general.string = model.viewText }
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
