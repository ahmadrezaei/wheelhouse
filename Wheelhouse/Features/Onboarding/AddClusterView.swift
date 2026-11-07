import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

/// S2 — add a cluster with a bearer token, or edit an existing one (reached from Settings → Clusters).
struct AddClusterView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    private let editingID: ClusterID?
    @State private var draft: ClusterDraft
    @State private var prometheusToken = ""
    @State private var test: ConnectionTestState = .idle
    @State private var importingCA = false
    @State private var confirmAddAnyway = false
    @State private var confirmDelete = false
    @State private var saveError: String?
    @State private var showProblems = false
    /// Set once the cluster is persisted; until then any client-certificate key created by Test Connection is an orphan.
    @State private var saved = false

    init(editing: ClusterConfig? = nil, registry: ClusterRegistry? = nil, prefill: ClusterDraft? = nil) {
        editingID = editing?.id
        if let editing {
            let d = ClusterDraft(editing: editing, secrets: registry?.secrets(for: editing.id) ?? ClusterSecrets())
            _draft = State(initialValue: d)
            _initialFingerprint = State(initialValue: d.testFingerprint)
            _prometheusToken = State(initialValue: PrometheusTokenStore.load(clusterID: editing.id) ?? "")
        } else {
            _draft = State(initialValue: prefill ?? ClusterDraft())
        }
    }

    private var isEditing: Bool { editingID != nil }

    var body: some View {
        Form {
            if registry.isDemoMode && !isEditing {
                Section { Label("You’re in Demo mode. Adding a real cluster will leave Demo mode.", systemImage: "sparkles").font(.footnote) }
            }
            clusterSection
            authSection
            tlsSection
            safetySection
            syncSection
            metricsSection
            advancedSection
            testSection
            if isEditing { deleteSection }
        }
        .navigationTitle(isEditing ? "Edit Cluster" : "Add Cluster")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cleanupIdentity(); if router.sheet != nil { router.dismissSheet() } else { dismiss() } }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isEditing ? "Save" : "Add") { attemptSave() }
            }
        }
        .fileImporter(isPresented: $importingCA, allowedContentTypes: [.data, .text, .x509Certificate, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { loadCA(from: url) }
        }
        .onDisappear { if !saved { cleanupIdentity() } }
        .task(id: draft.testFingerprint) {
            guard draft.isValid, !(isEditing && draft.token.isEmpty && draft.testFingerprint == initialFingerprint) else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { await runTest() }
        }
        .alert("Couldn’t verify this cluster", isPresented: $confirmAddAnyway) {
            Button("Add anyway") { save() }
            Button("Keep editing", role: .cancel) {}
        } message: { Text("The connection test did not succeed. You can fix the details later from Settings.") }
        .confirmationDialog("Remove \(draft.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Remove Cluster", role: .destructive) { deleteCluster() }
        } message: { Text("Deletes this cluster and its credentials from this device\(draft.iCloudSync ? " and from iCloud Keychain" : ""). The cluster itself is not touched.") }
        .alert("Couldn’t save", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }

    @State private var initialFingerprint = ""

    // MARK: Sections

    private var clusterSection: some View {
        Section {
            TextField("Name", text: $draft.name).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("API server URL", text: $draft.serverText, prompt: Text("https://api.example.com:6443"))
                .keyboardType(.URL).textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Default namespace (optional)", text: $draft.defaultNamespace).textInputAutocapitalization(.never).autocorrectionDisabled()
            if showProblems || draft.problems.contains(.httpNotAllowedForProduction) { ForEach(draft.problems, id: \.self) { Text($0.message).font(.footnote).foregroundStyle(Palette.criticalText) } }
            if draft.serverIsLocalhost {
                Label("127.0.0.1 / localhost only works from the Simulator or the Mac itself. On a real iPhone use the machine’s LAN address.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(Palette.warningText)
            }
            if draft.serverIsPlainHTTP {
                Label(draft.environment == .production ? "Production clusters require https://." : "Plain HTTP sends your token unencrypted. Use https:// unless this is a local test.", systemImage: "lock.open.fill")
                    .font(.footnote).foregroundStyle(Palette.warningText)
            }
        } header: { Text("Cluster") }
    }

    @ViewBuilder private var authSection: some View {
        Section {
            switch draft.authKind {
            case .clientCertificate:
                Label("Client certificate (from imported kubeconfig)", systemImage: "person.badge.key")
                Text("The certificate and key are stored in the Keychain. Re-import the kubeconfig to replace them.").font(.footnote).foregroundStyle(.secondary)
            default:
                HStack {
                    SecureField(isEditing ? "Bearer token (unchanged)" : "Bearer token", text: $draft.token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.password)
                    PasteButton(payloadType: String.self) { items in if let s = items.first { draft.token = s.trimmingCharacters(in: .whitespacesAndNewlines) } }
                        .labelStyle(.iconOnly).buttonBorderShape(.capsule)
                }
                if let exp = JWTInfo.expiry(of: draft.token) {
                    Label(exp < Date() ? "Token expired \(exp.formatted(.relative(presentation: .named)))" : "Token expires \(exp.formatted(date: .abbreviated, time: .omitted))",
                          systemImage: exp < Date() ? "exclamationmark.triangle.fill" : "clock")
                        .font(.footnote).foregroundStyle(exp < Date() ? Palette.criticalText : .secondary)
                }
            }
        } header: { Text("Authentication") } footer: {
            if draft.authKind == .token { Text("Use a ServiceAccount token, ideally with read-only RBAC. \(Text("kubectl create token").font(.whCodeSmall)) prints one. Stored only in the Keychain.") }
        }
    }

    private var tlsSection: some View {
        Section {
            if draft.caPEM.isEmpty {
                HStack {
                    Button { importingCA = true } label: { Label("Import CA certificate…", systemImage: "doc.badge.plus") }
                    Spacer()
                    PasteButton(payloadType: String.self) { items in if let s = items.first { draft.caPEM = s } }.labelStyle(.iconOnly).buttonBorderShape(.capsule)
                }
            } else {
                Label(CertificateSummary.subject(of: draft.caPEM).map { "CA: \($0)" } ?? "CA certificate (invalid)", systemImage: "checkmark.seal")
                    .foregroundStyle(draft.problems.contains(.caInvalid) ? Palette.criticalText : .primary)
                Button("Remove CA certificate", role: .destructive) { draft.caPEM = "" }
            }
            Toggle(isOn: $draft.skipTLSVerify) { Text("Skip TLS verification") }
                .disabled(!draft.skipTLSAllowed)
            if !draft.skipTLSAllowed {
                Text("Production clusters can never skip TLS verification.").font(.footnote).foregroundStyle(.secondary)
            } else if draft.skipTLSVerify {
                Label("Connection is not verified. Anyone on the network path could impersonate this cluster and read your token. Prefer adding the CA certificate. The cluster will carry a permanent UNVERIFIED TLS badge.", systemImage: "exclamationmark.octagon.fill")
                    .font(.footnote).foregroundStyle(Palette.criticalText)
            }
        } header: { Text("Server certificate") } footer: {
            Text("Needed for clusters with a private CA (kubeadm, k3s, minikube, kind). Public CAs work without it.")
        }
    }

    private var safetySection: some View {
        Section {
            Picker("Environment", selection: $draft.environment) {
                ForEach(ClusterEnvironment.allCases) { Text($0.title).tag($0) }
            }
            .onChange(of: draft.environment) { _, e in if e == .production { draft.skipTLSVerify = false } }
            if draft.environment == .production {
                Label("Destructive actions will require typing the resource name.", systemImage: "exclamationmark.shield").font(.footnote).foregroundStyle(Palette.envProduction)
            }
            HStack {
                Text("Colour")
                Spacer()
                ForEach(ClusterColor.allCases) { c in
                    Button { draft.color = c } label: {
                        Circle().fill(c.color).frame(width: 22, height: 22)
                            .overlay { if draft.color == c { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white) } }
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.rawValue.capitalized).accessibilityAddTraits(draft.color == c ? .isSelected : [])
                }
            }
            Toggle("Read-only mode", isOn: $draft.readOnly)
            if draft.readOnly { Toggle("Allow exec and port-forward", isOn: $draft.allowExecInReadOnly) }
        } header: { Text("Safety") } footer: {
            Text(draft.readOnly ? "Read-only clusters never send changes: scale, restart, delete and edit are hidden and refused." : "Turn on read-only to make this cluster view-only inside Wheelhouse, regardless of the token’s permissions.")
        }
    }

    private var syncSection: some View {
        Section {
            Toggle("Sync with iCloud Keychain", isOn: $draft.iCloudSync)
        } footer: {
            Text("Off by default. When on, this cluster and its credentials sync end-to-end encrypted via iCloud Keychain to your devices signed in with the same Apple Account. Turning it off later removes the item from iCloud, not from this device.")
        }
    }

    private var metricsSection: some View {
        Section {
            TextField("Prometheus URL", text: $draft.prometheusText, prompt: Text("https://prometheus.example.com"))
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            if !draft.prometheusText.isEmpty { SecureField("Prometheus bearer token (optional)", text: $prometheusToken).textInputAutocapitalization(.never).autocorrectionDisabled() }
        } header: { Text("Metrics (optional)") } footer: {
            Text("Leave empty to use metrics-server, or to auto-discover Prometheus inside the cluster.")
        }
    }

    private var advancedSection: some View {
        Section {
            TextField("TLS server name (optional)", text: $draft.tlsServerName, prompt: Text("api.cluster.example"))
                .textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("Advanced") } footer: {
            Text("The name the server certificate must be valid for, when it differs from the host in the server URL (kubeconfig tls-server-name).")
        }
    }

    private var testSection: some View {
        Section("Connection") {
            ConnectionTestCard(state: test, isLocalhost: draft.serverIsLocalhost,
                               target: draft.makeConfig().map { .init(host: $0.host, port: $0.server.port, authKind: $0.authKind.rawValue) }) { Task { await runTest() } }
                .disabled(!draft.isValid)
            if !draft.isValid && test == .idle { Text("Fill in the name, server URL and token to test the connection.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var deleteSection: some View {
        Section { Button("Remove Cluster…", role: .destructive) { confirmDelete = true } }
    }

    // MARK: Actions

    private func existingSecrets() -> ClusterSecrets { editingID.map { registry.secrets(for: $0) } ?? ClusterSecrets() }

    private func runTest() async {
        guard let config = draft.makeConfig() else { return }
        test = .running
        let secrets = draft.makeSecrets(existing: existingSecrets())
        let client = LiveKubeClient(config: config, secrets: secrets, tlsServerName: config.tlsServerName)
        let result = await ConnectionTester.run(client: client, namespace: config.defaultNamespace)
        if !Task.isCancelled { test = .done(result) }
    }

    private func cleanupIdentity() { if !isEditing { ClientIdentityBuilder.remove(label: ClientIdentityBuilder.label(for: draft.id)) } }

    private func attemptSave() {
        showProblems = true
        guard draft.isValid else { return }
        if case .done(let r) = test, r.succeeded { save() } else if isEditing { save() } else { confirmAddAnyway = true }
    }

    private func save() {
        guard let config = draft.makeConfig() else { return }
        if config.violatesHTTPProductionRule { saveError = ClusterDraft.Problem.httpNotAllowedForProduction.message; return }
        let isFirstRealCluster = !isEditing && (registry.isDemoMode || registry.clusters.isEmpty)
        do {
            let existing = existingSecrets()
            let secrets = draft.makeSecrets(existing: existing)
            if isEditing {
                // Unchanged secrets are not re-saved: a cluster whose credentials this build cannot read stays editable
                // (rename, safety flags) and its stored credentials are never touched.
                try registry.update(config, secrets: secrets == existing ? nil : secrets)
            } else {
                if registry.isDemoMode { preferences.demoMode = false; registry.exitDemoMode() }
                try registry.add(config, secrets: secrets)
                registry.select(config.id)
            }
            saved = true
            // Re-saved with the cluster's current sync flag (add the new variant first, then drop the old one).
            if !PrometheusTokenStore.save(draft.prometheusURL == nil ? nil : prometheusToken, clusterID: config.id, synchronizable: config.iCloudSync) {
                saveError = "The cluster was saved, but its Prometheus token could not be stored in the Keychain."
                return
            }
            if isFirstRealCluster { Task { await FirstClusterNotifications.requestIfNeeded(preferences: preferences) } }
            if isEditing { dismiss() } else if router.sheet != nil { router.dismissSheet() } else { dismiss() }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteCluster() {
        guard let id = editingID else { return }
        do {
            try registry.remove(id: id)
            PrometheusTokenStore.delete(clusterID: id)
            dismiss()
        } catch { saveError = error.localizedDescription }
    }

    private func loadCA(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { saveError = "That file isn’t readable text. Export the CA as PEM (.crt / .pem)."; return }
        if ClusterDraft.isValidCAPEM(text) { draft.caPEM = text } else { saveError = "No PEM certificate found in “\(url.lastPathComponent)”. DER (.cer) files must be converted to PEM first." }
    }
}

extension ClusterDraft {
    /// Changes in any of these re-trigger the automatic connection test.
    var testFingerprint: String { [serverText, token, caPEM, tlsServerName, skipTLSVerify.description, environment.rawValue, authKind.rawValue].joined(separator: "\u{1F}") }
}
