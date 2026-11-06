import SwiftUI
import Observation
import WheelhouseKit
import WheelhouseUI

/// State + logic behind the YAML editor (S14) and its review/apply flow (S15, F4).
@MainActor @Observable
final class YAMLEditorModel {
    enum Phase { case loading, loaded, failed(KubeError) }
    enum Mode { case view, edit }

    let ref: ResourceRef
    let cluster: ClusterConfig
    @ObservationIgnored let client: any KubeClientProtocol

    private(set) var phase: Phase = .loading
    /// The object exactly as last fetched.
    private(set) var live: JSONValue = .null
    private(set) var mode: Mode = .view
    var draft = ""
    var showServerFields = false
    var secretRevealed = false
    var wraps = true
    /// `false` when a SelfSubjectAccessReview says `update` is denied.
    private(set) var canUpdate = true
    private(set) var diagnostics: [YAMLDiagnostic] = []
    private(set) var parsedDraft: JSONValue?
    private(set) var changeStats = LineDiff.Stats(added: 0, removed: 0)
    var notice: Notice?

    struct Notice: Equatable { var text: String; var tone: StatusTone }

    @ObservationIgnored private var lintTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(ref: ResourceRef, cluster: ClusterConfig, client: any KubeClientProtocol) {
        self.ref = ref
        self.cluster = cluster
        self.client = client
    }

    // MARK: Derived

    var isSecret: Bool { ref.kind == .secret || SecretMasking.isSecret(live) }
    var resourceVersion: String? { YAMLNormalizer.resourceVersion(of: live) }
    var isEditing: Bool { mode == .edit }
    var canEdit: Bool {
        if case .loaded = phase { return !cluster.readOnly && canUpdate }
        return false
    }
    var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    var hasChanges: Bool { changeStats.total > 0 }
    var isDirty: Bool { isEditing && draft != baselineText }

    /// What the viewer shows.
    var viewText: String {
        guard case .loaded = phase else { return "" }
        var object = showServerFields ? YAMLNormalizer.withoutManagedFields(live) : YAMLNormalizer.editable(live)
        if isSecret, !secretRevealed { object = SecretMasking.masked(object, fingerprint: false) }
        return YAMLCodec.dump(object)
    }

    /// The editor's initial text for the current live object (real values).
    private var baselineText: String { YAMLCodec.dump(YAMLNormalizer.editable(live)) }

    /// Binding text for the editor depending on mode.
    var editorText: String {
        get { isEditing ? draft : viewText }
        set { if isEditing { draft = newValue } }
    }

    // MARK: Loading

    func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let raw = try await client.getRaw(ref.kind, name: ref.name, namespace: ref.namespace)
            live = raw
            phase = .loaded
            await checkPermission()
        } catch let e as KubeError {
            if case .cancelled = e { return }
            phase = .failed(e)
        } catch {
            if (error as? CancellationError) != nil { return }
            phase = .failed(.unreachable(cause: error.localizedDescription))
        }
    }

    private func checkPermission() async {
        guard !cluster.readOnly else { return }
        var spec: JSONValue = ["verb": "update", "resource": .string(ref.kind.plural), "group": .string(ref.kind.group), "name": .string(ref.name)]
        if let ns = ref.namespace { spec["namespace"] = .string(ns) }
        let body: JSONValue = ["apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview", "spec": ["resourceAttributes": spec]]
        if let result = try? await client.create(.selfSubjectAccessReview, namespace: nil, body: body, options: MutationOptions()),
           let allowed = result.value(at: "status.allowed")?.boolValue {
            canUpdate = allowed
        }
    }

    // MARK: Editing

    /// Starts editing. Secrets require the values to be revealed (Face ID) first.
    /// Reads `AppPreferences.revealSecretsOncePerSession`; set by the view.
    var revealOncePerSession: () -> Bool = { false }

    private func authorizeReveal(_ reason: String) async -> Bool {
        await SecretRevealGate.shared.authorize(oncePerSession: revealOncePerSession()) { await AppLockController.authenticate(reason: reason) }
    }

    func beginEdit() async {
        guard canEdit else { return }
        if isSecret, !secretRevealed {
            guard await authorizeReveal("Edit Secret values") else { return }
            secretRevealed = true
        }
        showServerFields = false
        draft = baselineText
        mode = .edit
        recompute()
    }

    func cancelEdit() {
        mode = .view
        draft = ""
        diagnostics = []
        parsedDraft = nil
        changeStats = .init(added: 0, removed: 0)
        if isSecret { secretRevealed = false }
    }

    func revealSecret() async {
        guard !secretRevealed else { secretRevealed = false; return }
        if await authorizeReveal("Reveal Secret values") { secretRevealed = true }
    }

    /// Debounced lint + change count.
    func draftChanged() {
        lintTask?.cancel()
        lintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    func recompute() {
        guard isEditing else { return }
        let (diags, value) = YAMLEditValidator.validate(text: draft, ref: ref)
        diagnostics = diags
        parsedDraft = value
        if let value {
            changeStats = LineDiff.stats(LineDiff.diff(old: comparable(YAMLNormalizer.editable(live)), new: comparable(value)))
        } else {
            changeStats = .init(added: 0, removed: 0)
        }
    }

    /// Canonical text for diffs; Secret values are replaced by fingerprints.
    func comparable(_ object: JSONValue) -> String {
        YAMLCodec.dump(isSecret ? SecretMasking.masked(object) : object)
    }

    // MARK: After review

    func adoptRebase(draft newDraft: String, latest: JSONValue) {
        live = latest
        draft = newDraft
        recompute()
    }

    func didApply(_ result: JSONValue) {
        if result.objectValue != nil { live = result }
        cancelEdit()
        show(Notice(text: "Applied · resourceVersion \(resourceVersion ?? "–")", tone: .healthy))
    }

    func show(_ n: Notice) {
        notice = n
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }
}
