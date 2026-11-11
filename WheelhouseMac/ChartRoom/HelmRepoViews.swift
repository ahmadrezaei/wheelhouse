import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Repository changes (ARCHITECTURE-MAC section 5.2): `helm repo add`, `update` and `remove` through `Subprocess`, never through Gangway (no
/// cluster is involved). A password goes through `--password-stdin` and is kept in the Mac-private keychain group.
@MainActor @Observable
final class RepositoryActions {
    private(set) var busy = false
    private(set) var message: String?
    private(set) var failed = false

    private let makeCLI: @MainActor () async throws -> HelmCLI
    private let secrets = MacPrivateSecretStore(.helmRepositoryPassword)

    init(makeCLI: @escaping @MainActor () async throws -> HelmCLI) { self.makeCLI = makeCLI }

    private func run(_ title: String, _ work: (HelmRepoRunner) async throws -> Void) async -> Bool {
        busy = true
        message = nil
        failed = false
        defer { busy = false }
        do {
            try await work(HelmRepoRunner(cli: try await makeCLI()))
            message = title
            return true
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            failed = true
            return false
        }
    }

    func add(name: String, url: String, username: String, password: String) async -> Bool {
        let ok = await run("Added \(name)") { try await $0.add(name: name, url: url, username: username.isEmpty ? nil : username, password: password.isEmpty ? nil : password) }
        if ok, !password.isEmpty { try? secrets.write(password, account: name) }
        if ok { _ = await run("Updated \(name)") { try await $0.update(names: [name]) } }
        return ok
    }

    func update(names: [String] = []) async -> Bool { await run(names.isEmpty ? "Updated all repositories" : "Updated \(names.joined(separator: ", "))") { try await $0.update(names: names) } }

    func remove(name: String) async -> Bool {
        let ok = await run("Removed \(name)") { try await $0.remove(name: name) }
        if ok { try? secrets.delete(account: name) }
        return ok
    }
}

struct AddRepositorySheet: View {
    var actions: RepositoryActions
    var onAdded: () -> Void
    @State var name: String
    @State var url: String
    @State private var username = ""
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    init(actions: RepositoryActions, name: String = "", url: String = "", onAdded: @escaping () -> Void) {
        self.actions = actions
        self.onAdded = onAdded
        _name = State(initialValue: name)
        _url = State(initialValue: url)
    }

    private var valid: Bool { HelmInputCheck.isValidRepositoryName(name) && HelmInputCheck.isValidRepositoryURL(url) && (password.isEmpty || !username.isEmpty) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name)
                TextField("URL (https:// or oci://)", text: $url)
                TextField("Username (optional)", text: $username)
                SecureField("Password (optional)", text: $password)
                Text("A password is passed to helm through a pipe. Helm keeps it in its own repositories file; a copy is kept in the Keychain on this Mac only.").font(.footnote).foregroundStyle(.secondary)
                if let message = actions.message, actions.failed { Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText).font(.footnote).textSelection(.enabled) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if actions.busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    Task {
                        if await actions.add(name: name, url: url, username: username, password: password) { onAdded(); dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction).disabled(!valid || actions.busy)
            }
            .padding(Spacing.l)
        }
        .frame(width: 480, height: 360)
    }
}

/// Artifact Hub search. Off by default (Settings → Chart Room): the only third-party request Chart Room makes, one GET per search.
struct ArtifactHubSheet: View {
    var actions: RepositoryActions
    var onAdded: () -> Void
    @State private var query = ""
    @State private var results: [ArtifactHubPackage] = []
    @State private var searching = false
    @State private var error: String?
    @State private var adding: ArtifactHubPackage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search Artifact Hub", text: $query).textFieldStyle(.roundedBorder).onSubmit { Task { await search() } }
                Button("Search") { Task { await search() } }.disabled(ArtifactHub.searchURL(query: query) == nil || searching)
                Button("Done") { dismiss() }
            }
            .padding(Spacing.l)
            Divider()
            if let error { EmptyState(.error(message: error)) }
            else if searching { EmptyState(.loading) }
            else if results.isEmpty { EmptyState(.empty(title: "Search Artifact Hub", systemImage: "magnifyingglass", hint: "Results are charts from public repositories. Adding one adds its repository to your helm configuration.")) }
            else {
                List(results) { package in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(package.name).fontWeight(.medium)
                            Text("\(package.repositoryName) · \(package.version)\(package.summary.map { " · \($0)" } ?? "")").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Add Repository…") { adding = package }
                    }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .sheet(item: $adding) { package in
            AddRepositorySheet(actions: actions, name: package.repositoryName, url: package.repositoryURL, onAdded: onAdded)
        }
    }

    private func search() async {
        guard let url = ArtifactHub.searchURL(query: query) else { return }
        searching = true
        error = nil
        defer { searching = false }
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            results = ArtifactHub.decode(data)
        } catch {
            results = []
            self.error = "Artifact Hub could not be reached: \(error.localizedDescription)"
        }
    }
}
