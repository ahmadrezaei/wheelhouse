import AppKit
import Observation
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The "Diff with local folder" state of one Flux Kustomization: which folder it maps to on this Mac, and the run of `flux diff` against it.
/// Nothing runs until the person asks (ARCHITECTURE-MAC §12.3: nothing at idle); the run is one task that Cancel stops.
@MainActor @Observable
final class FluxDiffModel {
    enum Phase: Equatable {
        case idle
        case running
        case noChanges
        case changes(String)
        case notInstalled
        case failed(String)
        case cancelled
    }

    private(set) var phase: Phase = .idle
    private(set) var folder: URL?
    let cluster: ClusterID
    let namespace: String
    let name: String
    private let mappings: FluxFolderMappings
    private let runDiff: @MainActor (URL) async throws -> FluxDiffOutput
    private var task: Task<Void, Never>?

    init(cluster: ClusterID, namespace: String, name: String, mappings: FluxFolderMappings = FluxFolderMappings(),
         runDiff: @escaping @MainActor (URL) async throws -> FluxDiffOutput) {
        self.cluster = cluster
        self.namespace = namespace
        self.name = name
        self.mappings = mappings
        self.runDiff = runDiff
        folder = mappings.folder(cluster: cluster, namespace: namespace, name: name)
    }

    var isMapped: Bool { folder != nil }
    var isRunning: Bool { phase == .running }

    /// Maps (or, with nil, unmaps) the local folder. The old result no longer describes the new folder.
    func map(_ url: URL?) {
        mappings.set(url, cluster: cluster, namespace: namespace, name: name)
        folder = mappings.folder(cluster: cluster, namespace: namespace, name: name)
        if !isRunning { phase = .idle }
    }

    func run() {
        guard !isRunning, let folder else { return }
        phase = .running
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let output = try await runDiff(folder)
                phase = output.hasChanges ? .changes(output.text) : .noChanges
            } catch is CancellationError {
                phase = .cancelled
            } catch FluxDiffError.notInstalled {
                phase = .notInstalled
            } catch {
                phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            task = nil
        }
    }

    /// Stops flux and closes its session; the run then ends as cancelled.
    func cancel() { task?.cancel() }

    /// Waits for the current run (tests).
    func finish() async { await task?.value }

    /// The live run: the user's flux, found by the locator, under a dry-run-only Gangway session.
    static func live(env: MacAppEnvironment, cluster: ClusterID, namespace: String, name: String) -> FluxDiffModel {
        FluxDiffModel(cluster: cluster, namespace: namespace, name: name) { folder in
            let snapshot = await MooringsController.shared?.shellEnvironment.current()
            let environment = EnvironmentBuilder(snapshot: snapshot, paths: env.paths, home: env.paths.home)
            guard let cli = FluxCLI.locate(ExecutableLocator(snapshot: snapshot, home: env.paths.home), environment: environment) else { throw FluxDiffError.notInstalled }
            let runner = FluxDiffRunner(cli: cli, gangway: try await env.gangway.service())
            return try await runner.diff(kustomization: name, namespace: namespace, folder: folder, cluster: cluster)
        }
    }
}

/// The Diff tab of a Flux Kustomization.
struct FluxDiffTab: View {
    let app: GitOpsApp
    let cluster: ClusterID
    @Environment(MacAppEnvironment.self) private var env
    @State private var model: FluxDiffModel?

    var body: some View {
        Group {
            if let model { FluxDiffContent(model: model) } else { ProgressView() }
        }
        .onDisappear { model?.cancel() }
        .task(id: app.id) {
            model?.cancel()
            model = FluxDiffModel.live(env: env, cluster: cluster, namespace: app.namespace ?? "flux-system", name: app.name)
        }
    }
}

private struct FluxDiffContent: View {
    let model: FluxDiffModel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                Label(model.folder?.path ?? "No local folder mapped", systemImage: "folder")
                    .foregroundStyle(model.isMapped ? .primary : .secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(model.isMapped ? "Change Folder…" : "Choose Folder…", action: choose).disabled(model.isRunning)
                if model.isMapped { Button("Unmap") { model.map(nil) }.disabled(model.isRunning) }
                if model.isRunning {
                    Button("Cancel") { model.cancel() }
                } else {
                    Button("Diff with Local Folder") { model.run() }.disabled(!model.isMapped)
                }
            }
            Divider()
            result
        }
        .padding(Spacing.m)
    }

    @ViewBuilder private var result: some View {
        switch model.phase {
        case .idle:
            if model.isMapped {
                Text("Runs `flux diff kustomization \(model.name)` against this folder. It only reads the cluster and asks the API server to dry-run; nothing is changed.")
                    .foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Map a local folder", systemImage: "folder.badge.questionmark",
                                       description: Text("Choose the folder of your Git checkout that this Kustomization applies. It is remembered on this Mac only."))
            }
        case .running: ProgressView("Running flux diff")
        case .noChanges: Label("The folder matches the cluster.", systemImage: "checkmark.circle").foregroundStyle(Palette.healthyText)
        case .changes(let text): ScrollView { FluxDiffText(text: text) }
        case .notInstalled:
            ContentUnavailableView("flux is not installed", systemImage: "wrench.and.screwdriver",
                                   description: Text("Wheelhouse uses your own flux CLI. Install it (for example with Homebrew) and run the diff again."))
        case .failed(let message): ScrollView { Text(message).font(.whCode).foregroundStyle(Palette.criticalText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        case .cancelled: Text("Cancelled.").foregroundStyle(.secondary)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Map Folder"
        panel.message = "Choose the local folder for Kustomization \(model.name)."
        if panel.runModal() == .OK { model.map(panel.url) }
    }
}

private struct FluxDiffText: View {
    let text: String
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.whCode)
                    .foregroundStyle(color(line))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .textSelection(.enabled)
    }

    private func color(_ raw: Substring) -> Color {
        let line = raw.drop { $0 == " " }
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return Palette.healthyText }
        if line.hasPrefix("-") { return Palette.criticalText }
        return .primary
    }
}
