import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// The packs this Mac knows: the built-in ones, local folders and git packs (ARCHITECTURE-MAC section 11).
///
/// A pack that is not built in is enabled only after its full declaration was shown and approved, and the approval is of one exact
/// `rigging.yaml` (its SHA-256). If the file changes later (a folder pack edited on disk) the pack is switched off until it is approved
/// again. Git packs live at `rigging/<name>@<commit>` and never update by themselves.
@MainActor @Observable
final class RiggingStore {
    struct Entry: Codable, Hashable, Identifiable {
        var name: String
        var source: RiggingPackSource
        var enabled: Bool
        /// The digest of the `rigging.yaml` the person approved. nil for built-in packs (they ship inside the app).
        var approvedDigest: String?
        var id: String { name }
    }

    struct Installed: Identifiable {
        var entry: Entry
        var loaded: LoadedRiggingPack?
        var problem: String?
        /// The file on disk is not the one that was approved.
        var changedSinceApproval = false
        var id: String { entry.name }
        var pack: RiggingPack? { loaded?.pack }
    }

    /// A pack waiting for the person's decision.
    struct Candidate: Identifiable {
        var id = UUID()
        var source: RiggingPackSource
        var loaded: LoadedRiggingPack
        /// True when this replaces an installed pack of the same name (an update).
        var replaces: Bool
        /// Where the pack it replaces came from, and the `rigging.yaml` that was approved (nil when nothing is replaced).
        var replacedSource: RiggingPackSource?
        var previousText: String?
        /// A sentence for the approval sheet when an installed pack of the same name is replaced by one from somewhere else.
        var replacementNotice: String? {
            guard replaces, let old = replacedSource else { return nil }
            let name = loaded.pack.metadata.name
            if old == source || (old.kind == source.kind && old.location == source.location) {
                return previousText == nil ? "Updates “\(name)”. Read the declaration again: the approved file is no longer on record, so no changes are listed."
                                           : "Updates “\(name)”: the lines that changed since the version you approved are listed below."
            }
            return "Replaces the installed pack “\(name)” from \(old.summary). Remove the old pack first if you did not expect this."
        }
        /// The lines that differ from the approved file (`+` added, `-` removed), at most 200.
        var changes: [String] {
            guard let previousText else { return [] }
            let before = previousText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let after = loaded.text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var out: [String] = []
            for change in after.difference(from: before) {
                switch change {
                case .insert(_, let line, _): out.append("+ \(line)")
                case .remove(_, let line, _): out.append("- \(line)")
                }
            }
            return Array(out.prefix(200))
        }
        var sections: [RiggingDeclaration.Section] { RiggingDeclaration.sections(for: loaded.pack) }
    }

    enum StoreError: Error, LocalizedError {
        case reserved(String), git(String)
        var errorDescription: String? {
            switch self {
            case .reserved(let name): "“\(name)” is the name of a built-in pack. Rename the pack to add it."
            case .git(let why): why
            }
        }
    }

    private(set) var installed: [Installed] = []
    /// Bumped on every change, so views and the sidebar rebuild.
    private(set) var revision = 0
    @ObservationIgnored var onChange: @MainActor () -> Void = {}

    @ObservationIgnored let root: URL
    @ObservationIgnored private let file: URL
    @ObservationIgnored private let builtIns: [LoadedRiggingPack]
    @ObservationIgnored private let gitLocator: @Sendable () -> URL?
    @ObservationIgnored private let networkEnvironment: [String: String]
    @ObservationIgnored private let allowLocalGit: Bool
    @ObservationIgnored private var entries: [Entry] = []

    init(paths: AppPaths, builtIns: [LoadedRiggingPack] = BuiltInRiggingPacks.all, allowLocalGit: Bool = false,
         gitLocator: @escaping @Sendable () -> URL? = { ExecutableLocator(searchPath: ["/usr/bin", "/opt/homebrew/bin", "/usr/local/bin"]).find("git") },
         networkEnvironment: [String: String] = GitPackFetcher.networkVariables(from: ProcessInfo.processInfo.environment)) {
        self.root = paths.root.appending(path: "rigging", directoryHint: .isDirectory)
        self.file = root.appending(path: "packs.json")
        self.builtIns = builtIns
        self.gitLocator = gitLocator
        self.allowLocalGit = allowLocalGit
        self.networkEnvironment = networkEnvironment
        load()
    }

    // MARK: Reading

    var active: [RiggingPack] { installed.compactMap { $0.entry.enabled && !$0.changedSinceApproval ? $0.pack : nil } }

    func installedPack(named name: String) -> Installed? { installed.first { $0.entry.name == name } }

    /// The views of the enabled packs for a kind, in pack order.
    func views(for kind: RiggingPack.KindMatch) -> [(pack: RiggingPack, view: RiggingPack.ViewSpec)] {
        active.flatMap { pack in pack.allViews.filter { $0.match == kind }.map { (pack, $0) } }
    }

    func view(pack name: String, id: String) -> (pack: RiggingPack, view: RiggingPack.ViewSpec)? {
        guard let pack = active.first(where: { $0.metadata.name == name }), let view = pack.view(id: id) else { return nil }
        return (pack, view)
    }

    /// The first enabled pack view for each kind, by `"<group>/<Kind>"`.
    var viewIndex: [String: (pack: String, view: String)] {
        var out: [String: (pack: String, view: String)] = [:]
        for pack in active { for view in pack.allViews where out["\(view.match.group)/\(view.match.kind)"] == nil { out["\(view.match.group)/\(view.match.kind)"] = (pack.metadata.name, view.viewID) } }
        return out
    }

    /// Per API group: the title and order the enabled packs ask for under Custom Resources.
    var sidebarLayouts: [String: (title: String?, order: [String])] {
        var out: [String: (title: String?, order: [String])] = [:]
        for pack in active {
            for group in pack.allSidebar {
                var layout = out[group.apiGroup] ?? (nil, [])
                if layout.title == nil { layout.title = group.title }
                layout.order += (group.kinds ?? []).filter { !layout.order.contains($0) }
                out[group.apiGroup] = layout
            }
        }
        return out
    }

    // MARK: Loading

    private func load() {
        var stored = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        // Every built-in pack is listed (off until the person turns it on); a stored entry only carries the person's choice.
        for built in builtIns where !stored.contains(where: { $0.name == built.pack.metadata.name }) {
            stored.append(Entry(name: built.pack.metadata.name, source: .builtIn, enabled: false))
        }
        stored.removeAll { e in e.source.kind == .builtIn && !builtIns.contains { $0.pack.metadata.name == e.name } }
        entries = stored
        rebuild()
    }

    /// Reads every pack again from where it lives (built-in from the bundle, folders and git packs from disk).
    func rebuild() {
        installed = entries.map { entry in
            var item = Installed(entry: entry)
            do {
                switch entry.source.kind {
                case .builtIn:
                    item.loaded = builtIns.first { $0.pack.metadata.name == entry.name }
                case .folder:
                    try loadApproved(URL(fileURLWithPath: entry.source.location ?? "/nonexistent", isDirectory: true), into: &item)
                case .git:
                    guard let commit = entry.source.commit else { throw RiggingPackError("The pinned commit is missing.") }
                    try loadApproved(root.appending(path: "\(entry.name)@\(commit)", directoryHint: .isDirectory), into: &item)
                }
                if let loaded = item.loaded, loaded.pack.metadata.name != entry.name { item.loaded = nil; item.problem = "The pack's name no longer matches." }
            } catch {
                item.problem = error.localizedDescription
            }
            return item
        }
        revision += 1
        onChange()
    }

    /// Reads a pack's folder and parses it only when the file is the one that was approved. A changed file is never parsed at launch
    /// (parsing untrusted text is what the approval is there to avoid); the pack just shows as changed.
    private func loadApproved(_ folder: URL, into item: inout Installed) throws {
        let raw = try RiggingPackFolder.read(folder)
        guard raw.digest == item.entry.approvedDigest else { item.changedSinceApproval = true; return }
        item.loaded = try Self.checked(RiggingPackFolder.parse(raw))
    }

    /// A second look at every terminal command with the terminal's own guard-bypass detector (`--kubeconfig`, `KUBECONFIG=`, `--server`,
    /// `--token`, …), on top of the template rules. A pack that fails is not loaded.
    static func checked(_ loaded: LoadedRiggingPack) throws -> LoadedRiggingPack {
        let problems = loaded.pack.allCommands.compactMap { command -> String? in
            guard let text = command.terminal else { return nil }
            let probe = text.replacing(/\{\{[^}]*\}\}/, with: "x")
            return UnguardedDetector.bypassReason(in: probe).map { "“\(command.title)” \($0), which would skip the terminal guard." }
        }
        guard problems.isEmpty else { throw RiggingPackError(problems) }
        return loaded
    }

    private func save() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let data = try? JSONEncoder().encode(entries) { try? data.write(to: file, options: .atomic) }
    }

    // MARK: Changing

    func setEnabled(_ name: String, _ enabled: Bool) {
        guard let i = entries.firstIndex(where: { $0.name == name }) else { return }
        // A pack whose file changed cannot be switched on again without a new approval.
        if enabled, installed.first(where: { $0.entry.name == name })?.changedSinceApproval == true { return }
        entries[i].enabled = enabled
        save()
        rebuild()
    }

    /// Reads a folder and returns what it would add. Nothing is stored until ``approve(_:)``.
    func candidate(folder: URL) throws -> Candidate {
        let loaded = try Self.checked(RiggingPackFolder.load(folder))
        let name = loaded.pack.metadata.name
        if builtIns.contains(where: { $0.pack.metadata.name == name }) { throw StoreError.reserved(name) }
        return Candidate(source: RiggingPackSource(kind: .folder, location: folder.standardizedFileURL.path), loaded: loaded, replaces: entries.contains { $0.name == name },
                         replacedSource: entries.first { $0.name == name }?.source, previousText: installedPack(named: name)?.loaded?.text)
    }

    /// Reads a pack whose file changed since it was approved, so the person can read it again and approve it. This is the only place a changed
    /// file is parsed, and only because the person asked to review it.
    func candidateForReview(_ name: String) throws -> Candidate {
        guard let item = installedPack(named: name), item.entry.source.kind != .builtIn else { throw RiggingPackError("That pack cannot be reviewed.") }
        let folder: URL
        if item.entry.source.kind == .git {
            guard let commit = item.entry.source.commit else { throw RiggingPackError("The pinned commit is missing.") }
            folder = root.appending(path: "\(name)@\(commit)", directoryHint: .isDirectory)
        } else {
            folder = URL(fileURLWithPath: item.entry.source.location ?? "/nonexistent", isDirectory: true)
        }
        let loaded = try Self.checked(RiggingPackFolder.load(folder))
        guard loaded.pack.metadata.name == name else { throw RiggingPackError("The pack's name no longer matches.") }
        return Candidate(source: item.entry.source, loaded: loaded, replaces: true, replacedSource: item.entry.source, previousText: item.loaded?.text)
    }

    /// Fetches a git pack into the app's folder (data only; no hook runs) and returns what it would add.
    func candidate(gitURL: String, ref: String?) async throws -> Candidate {
        guard let git = gitLocator() else { throw StoreError.git("git was not found on this Mac. Install the Xcode command line tools, or use a folder.") }
        let fetcher = GitPackFetcher(git: git, root: root, allowLocal: allowLocalGit, networkEnvironment: networkEnvironment)
        let fetched = try await fetcher.fetch(url: gitURL, ref: ref)
        _ = try Self.checked(fetched.loaded)
        let name = fetched.loaded.pack.metadata.name
        if builtIns.contains(where: { $0.pack.metadata.name == name }) {
            fetcher.prune(name: name, keep: entries.first { $0.name == name }.flatMap { $0.source.commit.map { "\(name)@\($0)" } })
            throw StoreError.reserved(name)
        }
        let source = RiggingPackSource(kind: .git, location: gitURL.trimmingCharacters(in: .whitespacesAndNewlines), commit: fetched.commit, ref: ref)
        return Candidate(source: source, loaded: fetched.loaded, replaces: entries.contains { $0.name == name },
                         replacedSource: entries.first { $0.name == name }?.source, previousText: installedPack(named: name)?.loaded?.text)
    }

    /// The person approved the declaration: store the pack, enabled, pinned to the digest that was shown.
    func approve(_ candidate: Candidate) {
        let name = candidate.loaded.pack.metadata.name
        let entry = Entry(name: name, source: candidate.source, enabled: true, approvedDigest: candidate.loaded.digest)
        if let i = entries.firstIndex(where: { $0.name == name }) { entries[i] = entry } else { entries.append(entry) }
        save()
        pruneGit(name: name)
        rebuild()
    }

    /// The person declined: a fetched git pack that is not the pinned one goes away.
    func discard(_ candidate: Candidate) {
        guard candidate.source.kind == .git else { return }
        pruneGit(name: candidate.loaded.pack.metadata.name)
    }

    func remove(_ name: String) {
        guard let entry = entries.first(where: { $0.name == name }), entry.source.kind != .builtIn else { return }
        entries.removeAll { $0.name == name }
        save()
        if entry.source.kind == .git { git()?.prune(name: name, keep: nil) }
        rebuild()
    }

    private func git() -> GitPackFetcher? {
        gitLocator().map { GitPackFetcher(git: $0, root: root, allowLocal: allowLocalGit) }
    }

    /// Keeps only the pinned commit's folder of a git pack.
    private func pruneGit(name: String) {
        let keep = entries.first { $0.name == name }.flatMap { e in e.source.kind == .git ? e.source.commit.map { "\(name)@\($0)" } : nil }
        git()?.prune(name: name, keep: keep)
    }

    /// Removes folders a crashed fetch left behind. Called once at start.
    func sweep() { git()?.sweepStaging() }
}
