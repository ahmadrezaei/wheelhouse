import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Settings → First Mate (DESIGN-MAC section 12): the API key (this Mac only), models, cost caps, tool-call rows, per-cluster access,
/// redaction patterns, conversation retention and Delete All.
struct FirstMatePane: View {
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        let hub = env.firstMate
        Form {
            KeySection(hub: hub)
            ModelSection(preferences: hub.preferences, hub: hub)
            ClusterAccessSection(hub: hub)
            RedactionSection(preferences: hub.preferences)
            StorageSection(hub: hub)
            Section { FirstMateDisclosure() } header: { Text("Privacy") }
        }
        .formStyle(.grouped)
        .navigationTitle("First Mate")
    }
}

private struct KeySection: View {
    let hub: FirstMateHub
    @State private var candidate = ""
    @State private var working = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        Section {
            LabeledContent("API key") {
                if let id = hub.keyIdentification { Text(id).font(.system(.body, design: .monospaced)) } else { Text("None").foregroundStyle(.secondary) }
            }
            SecureField("Paste your Anthropic API key", text: $candidate)
                .textContentType(.password)
                .disabled(working)
                .accessibilityIdentifier("firstmate.settings.keyField")
            HStack {
                Button(hub.hasKey ? "Replace Key" : "Add Key") { Task { await save() } }
                    .disabled(candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                if hub.hasKey {
                    Button("Remove Key", role: .destructive) {
                        do { try hub.removeKey(); message = "Key removed." } catch { message = error.localizedDescription; failed = true }
                    }
                }
                if working { ProgressView().controlSize(.small) }
            }
            if let message { Text(message).font(.callout).foregroundStyle(failed ? Palette.criticalText : Palette.healthyText) }
        } header: { Text("API key") } footer: {
            Text("The key is checked with a Models API call, then stored in the Keychain on this Mac only: never synced, never written anywhere else, and only its last four characters are shown again.")
        }
    }

    private func save() async {
        working = true
        failed = false
        message = nil
        defer { working = false }
        do {
            let models = try await hub.validate(candidate: candidate)
            try hub.saveKey(candidate)
            candidate = ""
            message = "Key saved. \(models.count) models available."
        } catch {
            failed = true
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct ModelSection: View {
    @Bindable var preferences: FirstMatePreferences
    let hub: FirstMateHub

    var body: some View {
        Section {
            Picker("Model for new conversations", selection: $preferences.usesQuickByDefault) {
                Text("Claude Opus 5.5 · effort medium").tag(false)
                Text("Quick · Claude Sonnet 5.5 · effort low").tag(true)
            }
            LabeledContent("Investigate", value: "Same model, effort high (⌥↩)")
            Stepper(value: $preferences.conversationCap, in: CostCaps.conversationRange, step: 0.25) {
                LabeledContent("Cost cap per conversation", value: Money.text(preferences.conversationCap))
            }
            Stepper(value: $preferences.dailyCap, in: 0...1_000, step: 1) {
                LabeledContent("Cost cap per day", value: Money.text(preferences.dailyCap))
            }
            .onChange(of: preferences.dailyCap) { _, _ in hub.applyDailyCap() }
            Toggle("Show tool calls in the conversation", isOn: $preferences.showToolCalls)
        } header: { Text("Model and cost") } footer: {
            Text("Estimates use the price list that ships with the app. At a cap, the conversation offers Continue (+$2).")
        }
    }
}

private struct ClusterAccessSection: View {
    let hub: FirstMateHub
    @Environment(MacAppEnvironment.self) private var env
    @State private var revision = 0

    var body: some View {
        Section {
            let _ = revision
            ForEach(env.registry.clusters.filter { !$0.isDemo }) { cluster in
                Picker(selection: binding(cluster)) {
                    Text("Default (\(label(ToolboxPolicy.defaultAccess(for: cluster.environment))))").tag(ClusterAccess?.none)
                    ForEach(ClusterAccess.allCases, id: \.self) { Text(label($0)).tag(ClusterAccess?.some($0)) }
                } label: {
                    HStack(spacing: 6) { Text(cluster.name); EnvBadge(cluster.environment) }
                }
            }
            if env.registry.clusters.allSatisfy(\.isDemo) { Text("No clusters yet.").foregroundStyle(.secondary) }
        } header: { Text("First Mate access per cluster") } footer: {
            Text("Allowed is the default for Development, Personal and Staging. Production asks, per conversation and per cluster. Never hides the cluster from First Mate completely. Read-only clusters can be read.")
        }
    }

    private func binding(_ cluster: ClusterConfig) -> Binding<ClusterAccess?> {
        Binding(get: { hub.settings.firstMateAccess(for: cluster) }, set: { hub.settings.set($0, for: cluster.id); revision += 1 })
    }

    private func label(_ access: ClusterAccess) -> String {
        switch access {
        case .allowed: "Allowed"
        case .ask: "Ask"
        case .never: "Never"
        }
    }
}

private struct RedactionSection: View {
    @Bindable var preferences: FirstMatePreferences
    @State private var pattern = ""
    @State private var problem: String?

    var body: some View {
        Section {
            Text("Built in: private keys and certificates, JWTs, cloud and Git host tokens, Anthropic keys, Authorization headers, password and token key-value forms, URL credentials, kubeconfig tokens, and Secret values, which are never fetched.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(preferences.redactionPatterns, id: \.self) { item in
                HStack {
                    Text(item).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Remove") { preferences.redactionPatterns.removeAll { $0 == item } }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("Add a pattern (regular expression)", text: $pattern).onSubmit(add)
                Button("Add", action: add).disabled(pattern.isEmpty)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Palette.criticalText) }
        } header: { Text("Redaction") } footer: {
            Text("Matches are replaced with ‹redacted› in everything First Mate sends, including your own messages.")
        }
    }

    private func add() {
        guard !pattern.isEmpty else { return }
        guard (try? NSRegularExpression(pattern: pattern)) != nil else { problem = "That is not a valid regular expression."; return }
        problem = nil
        if !preferences.redactionPatterns.contains(pattern) { preferences.redactionPatterns.append(pattern) }
        pattern = ""
    }
}

private struct StorageSection: View {
    let hub: FirstMateHub
    @Bindable var preferences: FirstMatePreferences
    @State private var confirmDelete = false

    init(hub: FirstMateHub) {
        self.hub = hub
        self.preferences = hub.preferences
    }

    var body: some View {
        Section {
            Picker("Keep conversations", selection: $preferences.retention) {
                ForEach(ConversationRetention.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            Button("Delete All Conversations…", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete every First Mate conversation?", isPresented: $confirmDelete) {
                    Button("Delete All", role: .destructive) { Task { await hub.deleteAll() } }
                } message: { Text("This also deletes the key that encrypts them. It cannot be undone.") }
        } header: { Text("Conversations") } footer: {
            Text("Stored on this Mac only, encrypted with a key in the Keychain that never leaves this Mac.")
        }
    }
}
