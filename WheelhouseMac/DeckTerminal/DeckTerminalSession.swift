import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// One Deck Terminal pane's shell, its terminal view and the plumbing between them. Created by the pane view and kept for as long as the pane
/// exists (a hidden pane keeps its shell and its buffer; it only stops drawing).
@MainActor @Observable
final class DeckTerminalSession: TerminalSurfaceDelegate {
    /// The pane's identity in Gangway (`origin: .terminal(paneID:)`) and in the confirmation coordinator.
    let paneID = UUID().uuidString
    private(set) var model: LocalShellModel?
    private(set) var title: String
    private(set) var startError: String?
    private(set) var restoredFrom: String?
    /// Direct mode is offered only for a cluster the policy allows (re-checked at every shell start).
    private(set) var directAvailability: DirectKubeconfig.Availability = .unavailable("")
    @ObservationIgnored let surface = SwiftTermSurface()
    @ObservationIgnored private let env: MacAppEnvironment
    @ObservationIgnored private let spec: TerminalSpec
    @ObservationIgnored private var starting = false

    init(env: MacAppEnvironment, spec: TerminalSpec) {
        self.env = env
        self.spec = spec
        self.title = spec.title ?? "Terminal"
        surface.delegate = self
        surface.onTitle = { [weak self] in self?.title = Self.cleanTitle($0) }
    }

    /// A title comes from a program in the terminal: no control or bidi characters, and a length limit.
    static func cleanTitle(_ raw: String) -> String {
        String(TerminalInserter.sanitize(raw).text.prefix(80))
    }

    var cluster: ClusterConfig? { spec.clusterID.flatMap { env.registry.config(for: $0) } ?? env.registry.currentCluster }

    // MARK: Start and stop

    func start(direct: Bool = false) async {
        guard !starting, model == nil else { return }
        guard let cluster else { startError = "Choose a cluster for this terminal."; return }
        starting = true
        defer { starting = false }
        startError = nil
        let context = env.moorings.state.context(for: cluster.id)?.context
        if direct, context == nil { startError = "Direct mode needs a cluster from a kubeconfig file."; return }
        directAvailability = DirectKubeconfig.availability(for: cluster, hasKubeconfigContext: context != nil)
        let snapshot = await env.moorings.shellEnvironment.snapshot
        let configuration = Self.configuration(env: env, spec: spec, cluster: cluster, paneID: paneID, snapshot: snapshot, direct: direct ? context : nil,
                                               size: surface.size.cols > 0 ? surface.size : (100, 30), lastDirectory: restoredDirectory())
        let shell = LocalShellModel(configuration: configuration)
        shell.onOutput = { [weak self] in self?.surface.feed($0) }
        shell.bracketedPasteProvider = { [weak self] in self?.surface.isBracketedPasteEnabled ?? false }
        do {
            let service = direct ? nil : try await env.gangway.service()
            try await shell.start(gangway: service)
            model = shell
            if let restored = restoredDirectory(), spec.startDirectory == nil { restoredFrom = restored }
        } catch {
            startError = error.localizedDescription
        }
    }

    /// A fresh shell in the same place (after the session ended or a banner asked to restore).
    func restart(direct: Bool = false) async {
        let last = model?.workingDirectory
        await model?.close()
        model = nil
        if let last { rememberDirectory(last) }
        surface.reset()
        await start(direct: direct)
    }

    func close() async {
        if let last = model?.workingDirectory { rememberDirectory(last) }
        await model?.close()
        env.gangwaySheets.unregister(pane: paneID)
    }

    // MARK: Restoration (new shell, last directory; processes are never restored)

    private var directoryKey: String { "\(spec.clusterID ?? "-")|\(spec.namespace ?? "-")|\(spec.title ?? "-")|\(spec.startDirectory ?? "-")" }

    private func restoredDirectory() -> String? { Self.directories(env.paths)[directoryKey] }

    private func rememberDirectory(_ path: String) {
        var all = Self.directories(env.paths)
        all[directoryKey] = path
        if all.count > 200 { all = Dictionary(uniqueKeysWithValues: all.suffix(100)) }
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: env.paths.root.appending(path: "terminal-directories.json"), options: .atomic) }
    }

    private static func directories(_ paths: AppPaths) -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: paths.root.appending(path: "terminal-directories.json")))) ?? [:]
    }

    // MARK: Configuration

    static func configuration(env: MacAppEnvironment, spec: TerminalSpec, cluster: ClusterConfig, paneID: String, snapshot: ShellSnapshot?, direct: KubeconfigContext?,
                              size: (cols: Int, rows: Int), lastDirectory: String?) -> LocalShellModel.Configuration {
        let paths = env.paths
        let gate = DevSafetyPolicy.current
        // While the safety gate is active no real startup file of the person is read: the user's directories are an empty folder, and HOME
        // points at it too (so a profile cannot reach for ~/.kube either).
        let empty = paths.root.appending(path: "terminal-home", directoryHint: .isDirectory)
        if gate.isActive { try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true) }
        let account = DevSafetyPolicy.accountHome
        var base = snapshot?.vars ?? [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING"] where base[key] == nil {
            if let value = ProcessInfo.processInfo.environment[key] { base[key] = value }
        }
        base["PATH"] = snapshot?.path ?? ShellEnvironment.fallbackPath(home: account)
        let zshDir = gate.isActive ? empty : URL(fileURLWithPath: base["ZDOTDIR"] ?? base["HOME"] ?? account.path, isDirectory: true)
        let bashHome = gate.isActive ? empty : URL(fileURLWithPath: base["HOME"] ?? account.path, isDirectory: true)
        let shellPath = spec.shell ?? snapshot?.shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let startDirectory = (spec.startDirectory ?? lastDirectory).map { URL(fileURLWithPath: $0, isDirectory: true) }
        return LocalShellModel.Configuration(
            cluster: cluster, namespace: spec.namespace, shell: URL(fileURLWithPath: shellPath), startDirectory: startDirectory, mode: direct == nil ? .guarded : .direct,
            paneID: paneID, size: size, baseEnvironment: base, helmEnvironment: gate.isActive ? paths.helmEnvironment : [:],
            userFiles: .init(zshDirectory: zshDir, bashHome: bashHome), home: gate.isActive ? empty : nil,
            kubeCacheDir: paths.root.appending(path: "kubectl-cache", directoryHint: .isDirectory), directContext: direct, directRoot: paths.root,
            helper: PTYProcess.bundledHelper, gate: gate, activity: env.activity)
    }

    // MARK: TerminalSurfaceDelegate

    func terminalSurface(_ surface: any TerminalSurface, send data: Data) { model?.write(data) }
    func terminalSurface(_ surface: any TerminalSurface, didResize cols: Int, rows: Int) { model?.resize(cols: cols, rows: rows) }
}
