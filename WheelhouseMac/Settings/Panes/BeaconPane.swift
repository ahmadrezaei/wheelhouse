import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Settings → Beacon: the on/off switch (Touch ID or the password every time it is turned on), the approved clients and their scopes,
/// and the snippets for Claude Code and Claude Desktop (ARCHITECTURE-MAC section 10).
struct BeaconPane: View {
    var body: some View {
        Form {
            if let model = BeaconModelHub.shared.model {
                Content(model: model)
            } else {
                Text("Beacon isn’t available.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Beacon")
    }

    private struct Content: View {
        let model: BeaconModel
        @State private var newName = ""

        var body: some View {
            Section {
                LabeledContent("Beacon") {
                    if model.isOn {
                        Button("Stop Beacon", role: .destructive) { model.turnOff() }
                    } else {
                        Button("Turn On…") { Task { await model.turnOn() } }
                    }
                }
                if model.isOn { LabeledContent("Connected clients", value: "\(model.sessionCount)") }
                if let error = model.lastError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.footnote) }
            } header: { Text("Status") } footer: {
                Text("Off by default. Turning it on asks for Touch ID or your password every time. AI tools connect through a helper (wheelhouse-mcp) that you add to their configuration below.")
            }
            Section {
                Text("Beacon only guards what an agent does through Beacon. An agent that has its own shell (Claude Code, an IDE agent) can still run kubectl against ~/.kube/config directly, outside Wheelhouse. Run such agents inside a Deck Terminal, where their kubectl calls go through Gangway and get a confirmation on Production.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("What Beacon does not cover") }
            Section("Clients") {
                if model.clients.isEmpty { Text("No clients yet. Create one, then add it to Claude Code or Claude Desktop.").foregroundStyle(.secondary) }
                ForEach(model.clients) { client in ClientRow(model: model, client: client) }
                HStack {
                    TextField("Name (for example Claude Code)", text: $newName)
                    Button("Create Client") { model.createClient(label: newName); newName = "" }.disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private struct ClientRow: View {
        let model: BeaconModel
        let client: BeaconClientRecord
        @State private var showSecret = false

        private var clusters: [ClusterConfig] { model.registry.clusters.filter { !$0.isDemo } }

        var body: some View {
            DisclosureGroup {
                LabeledContent("Program", value: client.launcherDescription ?? "Not claimed yet: the first connection asks you to approve it.")
                ForEach(clusters) { cluster in
                    HStack {
                        Toggle(isOn: Binding(get: { client.readClusters.contains(cluster.id) }, set: { on in
                            var read = client.readClusters
                            if on { read.insert(cluster.id) } else { read.remove(cluster.id) }
                            Task { await model.setScope(client.id, read: read, changeRequests: client.changeRequestClusters) }
                        })) { HStack(spacing: 6) { Text(cluster.name); EnvBadge(cluster.environment) } }
                        Spacer()
                        // Change requests: never for Production or read-only clusters. Enabling one asks for Touch ID.
                        let blocked = cluster.environment == .production || cluster.readOnly
                        Toggle("Change requests", isOn: Binding(get: { client.changeRequestClusters.contains(cluster.id) }, set: { on in
                            var changes = client.changeRequestClusters
                            if on { changes.insert(cluster.id) } else { changes.remove(cluster.id) }
                            Task { await model.setScope(client.id, read: client.readClusters, changeRequests: changes) }
                        }))
                        .disabled(blocked || !client.readClusters.contains(cluster.id))
                        .help(blocked ? "Change requests are never offered for Production or read-only clusters." : "Each request still waits for your confirmation.")
                    }
                }
                Button(showSecret ? "Hide Snippets" : "Show Snippets") { showSecret.toggle() }
                if showSecret { snippets }
                Button("Revoke", role: .destructive) { model.revoke(client.id) }
            } label: {
                HStack { Text(client.label); Spacer(); Text(client.isBound ? "Approved" : "Waiting for first connection").font(.caption).foregroundStyle(.secondary) }
            }
        }

        @ViewBuilder private var snippets: some View {
            if let command = model.claudeCodeCommand(for: client.id) {
                Text(command).font(.whCode).textSelection(.enabled)
                HStack {
                    Button("Copy") { model.copyToPasteboard(command) }
                    Button("Add to Claude Code") {
                        Task { await model.addToClaudeCode(client.id, locator: ExecutableLocator(snapshot: nil)) }
                    }
                    if model.canAddToClaudeDesktop {
                        Button("Add to Claude Desktop") { model.addToClaudeDesktop(client.id) }
                    } else {
                        Text("Add to Claude Desktop is off in development builds.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let json = model.projectJSON(for: client.id) {
                Text(".mcp.json").font(.caption).foregroundStyle(.secondary)
                Text(json).font(.whCode).textSelection(.enabled)
                Label(BeaconClientConfig.projectFileWarning, systemImage: "exclamationmark.shield").font(.caption).foregroundStyle(.orange)
                Button("Copy .mcp.json") { model.copyToPasteboard(json) }
            }
        }
    }
}
