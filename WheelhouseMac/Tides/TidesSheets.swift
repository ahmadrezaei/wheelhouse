import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Sync options (DESIGN-MAC §6.10): prune, dry run, apply out-of-sync only, selected resources, revision. Continuing opens the
/// ConfirmSheet; nothing is written from here.
struct ArgoSyncOptionsSheet: View {
    let app: GitOpsApp
    let onContinue: (ArgoSyncRequest) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var revision = ""
    @State private var prune = false
    @State private var dryRun = false
    @State private var outOfSyncOnly = false
    @State private var chosen: Set<String> = []
    @State private var restrict = false

    var body: some View {
        let argo = ArgoView(raw: app.raw)
        let resources = argo.resources.filter { !$0.hook }
        NavigationStack {
            Form {
                Section("Revision") {
                    TextField("Revision", text: $revision, prompt: Text(argo.targetRevision ?? "HEAD"))
                    Text("Empty syncs to the application's target revision.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Options") {
                    Toggle("Prune resources Git no longer has", isOn: $prune)
                    if prune {
                        let n = argo.pruneCandidates.count
                        Label(n == 0 ? "Nothing is waiting to be pruned." : "\(n) resource\(n == 1 ? "" : "s") would be deleted. You will see the list before confirming.",
                              systemImage: n == 0 ? "checkmark.circle" : "trash").font(.callout)
                    }
                    Toggle("Dry run (compare only)", isOn: $dryRun)
                    Toggle("Apply out-of-sync resources only", isOn: $outOfSyncOnly)
                }
                Section("Resources") {
                    Toggle("Sync only selected resources", isOn: $restrict)
                    if restrict {
                        List(resources) { r in
                            Toggle(isOn: Binding(get: { chosen.contains(r.id) }, set: { if $0 { chosen.insert(r.id) } else { chosen.remove(r.id) } })) {
                                HStack { Text(r.display); if r.sync == .outOfSync { StatusPill(tone: .warning, text: "Out of Sync") } }
                            }
                        }.frame(minHeight: 120, maxHeight: 220)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Sync \(app.name)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue…") {
                        let selected = restrict ? resources.filter { chosen.contains($0.id) }.map(ArgoSyncResource.init) : []
                        let trimmed = revision.trimmingCharacters(in: .whitespaces)
                        onContinue(ArgoSyncRequest(revision: trimmed.isEmpty ? nil : trimmed, prune: prune, dryRun: dryRun,
                                                   applyOutOfSyncOnly: outOfSyncOnly, resources: selected))
                    }
                    .disabled(restrict && chosen.isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 460)
    }
}

/// Connect to Argo CD (DESIGN-MAC decision 17): the token is kept in the Mac-private keychain group, on this device only, and is
/// used for reading diffs through the Kubernetes service proxy. Wheelhouse never writes to Argo CD with it.
struct ArgoConnectSheet: View {
    let session: ClusterSession
    let connection: ArgoConnection
    let done: () -> Void
    @State private var location = ArgoServiceLocation()
    @State private var token = ""
    @State private var status: String?
    @State private var testing = false
    @State private var hasToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Argo CD server, as the Kubernetes API server reaches it") {
                    TextField("Namespace", text: $location.namespace)
                    TextField("Service", text: $location.service)
                    TextField("Port", text: $location.port)
                    Picker("Scheme", selection: $location.scheme) {
                        Text("https").tag("https")
                        Text("http (server runs with --insecure)").tag("http")
                    }
                }
                Section("Token") {
                    SecureField(hasToken ? "Token stored. Enter a new one to replace it" : "Argo CD API token", text: $token)
                    Text("Stored on this Mac only (Mac-private keychain group, this device only), never synced to iCloud. Create a read-only token for a project role with `argocd proj role create-token`.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status { Text(status).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Connect to Argo CD")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close", action: done) }
                ToolbarItem { Button("Test") { Task { await test() } }.disabled(testing || (token.isEmpty && !hasToken)) }
                ToolbarItem { Button("Remove Token", role: .destructive) { remove() }.disabled(!hasToken) }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(token.isEmpty) }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .onAppear {
            location = connection.location(for: session.id)
            hasToken = connection.hasToken(session.id)
        }
    }

    private func save() {
        connection.setLocation(location, for: session.id)
        if connection.writeToken(token, session.id) {
            token = ""
            hasToken = true
            status = "Saved."
        } else {
            status = "The keychain refused the token."
        }
    }

    private func remove() {
        _ = connection.writeToken(nil, session.id)
        hasToken = false
        status = "Removed."
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let candidate = token.isEmpty ? connection.readToken(session.id) : token
        guard let candidate else { return }
        status = "Asking Argo CD…"
        do {
            let user = try await ArgoAPI(client: session.client, location: location, token: candidate).checkToken()
            status = "Connected" + (user.map { " as \($0)" } ?? "") + "."
        } catch {
            status = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
