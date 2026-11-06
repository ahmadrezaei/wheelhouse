import SwiftUI
import WheelhouseKit

public enum DryRunOutcome: Sendable {
    case passed(String)
    case failed(String)
}

/// Describes one mutating action. Every mutation in the app goes through ``ConfirmSheet`` (DESIGN.md §7).
public struct ConfirmRequest: Identifiable {
    public struct Fact: Identifiable {
        public let id = UUID()
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public let id = UUID()
    public var title: String
    /// One sentence describing the effect.
    public var message: String
    /// Primary button label, e.g. "Restart Rollout", "Delete Pod".
    public var verb: String
    public var isDestructive: Bool
    public var cluster: ClusterConfig
    public var namespace: String?
    /// `deployment/payments-api`
    public var resource: String
    /// Name to type on production clusters (usually the object name, or the count for bulk deletes).
    public var confirmationText: String
    public var facts: [Fact]
    /// Kept for display/back-compat. On production clusters EVERY mutation needs type-to-confirm regardless of this flag (DESIGN.md §7).
    public var isDisruptive: Bool
    /// Force type-to-confirm on non-production clusters too.
    public var alwaysRequireTyping: Bool
    /// Server dry-run; the primary button stays disabled until it passes.
    public var dryRun: (@MainActor @Sendable () async -> DryRunOutcome)?
    public var action: @MainActor @Sendable () async throws -> Void
    /// Resolves the cluster's CURRENT configuration when the sheet renders and when the action runs (nil = the cluster is gone).
    /// When unset, the sheet looks the cluster up in the environment's `ClusterRegistry`; if there is none it falls back to `cluster`.
    public var currentConfig: (@MainActor () -> ClusterConfig?)?

    public init(title: String, message: String, verb: String, isDestructive: Bool = false, cluster: ClusterConfig, namespace: String? = nil,
                resource: String, confirmationText: String, facts: [Fact] = [], isDisruptive: Bool = true, alwaysRequireTyping: Bool = false,
                dryRun: (@MainActor @Sendable () async -> DryRunOutcome)? = nil, action: @escaping @MainActor @Sendable () async throws -> Void) {
        self.title = title
        self.message = message
        self.verb = verb
        self.isDestructive = isDestructive
        self.cluster = cluster
        self.namespace = namespace
        self.resource = resource
        self.confirmationText = confirmationText
        self.facts = facts
        self.isDisruptive = isDisruptive
        self.alwaysRequireTyping = alwaysRequireTyping
        self.dryRun = dryRun
        self.action = action
    }

    /// Production clusters: every mutation requires typing the confirmation text.
    public var requiresTyping: Bool { requiresTyping(for: cluster) }

    /// Typing requirement evaluated against a (possibly newer) cluster configuration.
    public func requiresTyping(for live: ClusterConfig) -> Bool { alwaysRequireTyping || live.environment.requiresTypeToConfirm }

    /// Why the action must not run against `live`, or nil when it may proceed. `live == nil` means the cluster no longer exists.
    public func refusal(live: ClusterConfig?) -> String? {
        guard let live else { return "This cluster was removed." }
        if live.readOnly { return "This cluster is read-only. Turn off read-only mode in cluster settings to make changes." }
        return nil
    }
}

/// The one confirmation sheet: shows cluster + namespace + resource first, runs the dry-run, enforces type-to-confirm on production.
public struct ConfirmSheet: View {
    private let request: ConfirmRequest
    @Environment(\.dismiss) private var dismiss
    @Environment(ClusterRegistry.self) private var registry: ClusterRegistry?
    @State private var typed = ""
    @State private var dryRun: DryRunState = .idle
    @State private var isRunning = false
    @State private var failure: String?
    @FocusState private var fieldFocused: Bool

    enum DryRunState { case idle, running, outcome(DryRunOutcome) }

    public init(_ request: ConfirmRequest) { self.request = request }

    /// The cluster as configured NOW (a settings change while the sheet is open must take effect), nil if it is gone.
    private var live: ClusterConfig? {
        if let resolver = request.currentConfig { return resolver() }
        if let registry { return registry.config(for: request.cluster.id) }
        return request.cluster
    }
    private var refusal: String? { request.refusal(live: live) }
    private var requiresTyping: Bool { live.map(request.requiresTyping(for:)) ?? true }

    private var typingOK: Bool { !requiresTyping || typed == request.confirmationText }
    private var dryRunOK: Bool {
        guard request.dryRun != nil else { return true }
        if case .outcome(.passed) = dryRun { return true }
        return false
    }
    private var canConfirm: Bool { typingOK && dryRunOK && !isRunning && refusal == nil }

    public var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(request.message).font(.body)
                }
                Section("Target") {
                    LabeledContent("Cluster") { HStack(spacing: 6) { Text(request.cluster.name); EnvBadge(request.cluster.environment) } }
                    if let ns = request.namespace { LabeledContent("Namespace", value: ns) }
                    LabeledContent("Resource") { Text(request.resource).font(.whCode).multilineTextAlignment(.trailing) }
                    ForEach(request.facts) { LabeledContent($0.label, value: $0.value) }
                }
                if request.dryRun != nil {
                    Section("Server dry-run") { dryRunView }
                }
                if let refusal {
                    Section { Label(refusal, systemImage: "lock.fill").foregroundStyle(Palette.infoText) }
                }
                if requiresTyping {
                    Section {
                        TextField("Type \(request.confirmationText)", text: $typed)
                            .font(.whCode).textInputAutocapitalization(.never).autocorrectionDisabled().focused($fieldFocused)
                            .overlay(alignment: .trailing) {
                                if typingOK { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy) }
                            }
                    } header: { Text("Confirm") } footer: {
                        Text(live?.isProduction ?? request.cluster.isProduction ? "Production cluster: type the name to enable the button." : "Type the name to enable the button.")
                    }
                }
                if let failure {
                    Section { Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText).font(.footnote) }
                }
                if request.isDestructive {
                    Section { Text("This cannot be undone.").font(.footnote).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(isRunning) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(request.verb, role: request.isDestructive ? .destructive : nil) { startRun() }
                        .buttonStyle(.glassProminent)
                        .tint(request.isDestructive ? Palette.critical : Palette.tint)
                        .disabled(!canConfirm)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                ContextLine(cluster: live ?? request.cluster, namespace: request.namespace, kind: nil).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            }
            .interactiveDismissDisabled(isRunning)
        }
        .task { await runDryRun() }
        .presentationDetents([.medium, .large])
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.cluster.name), \(request.namespace ?? "all namespaces"), \(request.resource)")
    }

    @ViewBuilder private var dryRunView: some View {
        switch dryRun {
        case .idle, .running: HStack { ProgressView(); Text("Validating with the API server…").foregroundStyle(.secondary) }
        case .outcome(.passed(let s)): Label(s, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.healthyText)
        case .outcome(.failed(let s)): Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText).font(.footnote)
        }
    }

    private func runDryRun() async {
        guard let dry = request.dryRun else { return }
        dryRun = .running
        dryRun = .outcome(await dry())
    }

    /// `isRunning` flips synchronously, before any suspension, so a double tap cannot start the action twice.
    private func startRun() {
        guard !isRunning, canConfirm else { return }
        isRunning = true
        failure = nil
        Task { await run() }
    }

    private func run() async {
        // Re-check against the live configuration immediately before mutating.
        let live = live
        if let refusal = request.refusal(live: live) { failure = refusal; isRunning = false; return }
        if let live, request.requiresTyping(for: live), typed != request.confirmationText { failure = "Type \(request.confirmationText) to confirm."; isRunning = false; return }
        do {
            try await request.action()
            dismiss()
        } catch {
            failure = (error as? KubeError)?.summary ?? error.localizedDescription
        }
        isRunning = false
    }
}

public extension View {
    /// Presents a ``ConfirmSheet`` for a request.
    func confirmSheet(_ request: Binding<ConfirmRequest?>) -> some View {
        sheet(item: request) { ConfirmSheet($0) }
    }
}
