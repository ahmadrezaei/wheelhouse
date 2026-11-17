#if os(macOS)
import Foundation

/// The operating-system side of a folder grant (bookmarks and security-scoped access), behind a seam so tests can inject every outcome.
public protocol ScopedAccessBackend: Sendable {
    /// Resolves an app-scoped bookmark. `stale` means the folder moved or the bookmark needs to be made again.
    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool)
    /// An app-scoped, read-only bookmark of a folder the user chose (the URL must carry the panel's access).
    func makeBookmark(for url: URL) throws -> Data
    /// `startAccessingSecurityScopedResource()`. False means the access was not granted.
    func start(_ url: URL) -> Bool
    func stop(_ url: URL)
}

public struct SystemScopedAccessBackend: ScopedAccessBackend {
    public init() {}

    public func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        var stale = false
        // `.withoutUI` and `.withoutMounting`: launching never blocks on a volume or shows a dialog.
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI, .withoutMounting], relativeTo: nil,
                          bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    public func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func start(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stop(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// What restoring one stored grant at launch came to.
public enum GrantOutcome: Sendable, Equatable {
    /// Access is held. `source` is the (possibly refreshed) source; `replacing` is the id it had before when anything changed.
    case active(source: MooringsSource, replacing: String?)
    /// The folder is gone (error 4, moved to the Trash, or a bookmark that does not resolve). Ask again.
    case folderGone(MooringsSource)
    /// The bookmark resolved but the system refused access. Ask again.
    case needsAccess(MooringsSource)
}

/// Holds one `startAccessingSecurityScopedResource()` per granted folder for the whole life of the app: the spike showed that `stop`
/// really revokes access, so a folder is only released when its source is removed (MAS-EDITION §9). Owned by ``MooringsService``,
/// which is an actor, so there is no lock here.
final class SecurityScopedAccess {
    private let backend: any ScopedAccessBackend
    /// Source id -> the URL access was started on, and so the one `stop` must be called on.
    private var held: [String: URL] = [:]

    init(backend: any ScopedAccessBackend) { self.backend = backend }

    func isHolding(_ id: String) -> Bool { held[id] != nil }

    /// A stored grant at launch. A source without a bookmark is returned untouched (nothing to resolve or hold).
    func restore(_ source: MooringsSource) -> GrantOutcome {
        guard let bookmark = source.bookmark else { return .active(source: source, replacing: nil) }
        let resolved: (url: URL, stale: Bool)
        do { resolved = try backend.resolve(bookmark) } catch { return .folderGone(source) }
        // A folder deleted in Finder is moved to the Trash and its bookmark resolves there, stale. That is gone, not moved.
        guard !Self.isInTrash(resolved.url) else { return .folderGone(source) }
        guard backend.start(resolved.url) else { return .needsAccess(source) }
        var refreshed = source
        refreshed.path = Self.normalizedPath(resolved.url)
        // Refresh while access is held (the spike: a stale bookmark must be re-made from the accessed URL).
        if resolved.stale, let fresh = try? backend.makeBookmark(for: resolved.url) { refreshed.bookmark = fresh }
        let oldID = source.id
        hold(refreshed.id, url: resolved.url)
        // The old id (a moved folder) does not stay held.
        if oldID != refreshed.id { release(oldID) }
        return .active(source: refreshed, replacing: refreshed == source ? nil : oldID)
    }

    /// A folder the user just picked in a panel: bookmark it at once, then hold access on the URL the bookmark resolves to, so every
    /// held URL is bookmark-derived and `stop` revokes it. The panel's own implicit access lasts until the app quits.
    func grant(_ picked: URL, kind: MooringsSource.Kind, recursive: Bool = false) throws -> MooringsSource {
        let bookmark = try backend.makeBookmark(for: picked)
        let resolved = try backend.resolve(bookmark)
        guard backend.start(resolved.url) else { throw GrantError.accessRefused(picked.path) }
        let source = MooringsSource(kind: kind, path: Self.normalizedPath(resolved.url), recursive: recursive, bookmark: bookmark)
        hold(source.id, url: resolved.url)
        return source
    }

    /// Stops the access of a removed source.
    func release(_ id: String) {
        guard let url = held.removeValue(forKey: id) else { return }
        backend.stop(url)
    }

    /// Starts the new access before the old one stops, so access never lapses on a re-grant.
    private func hold(_ id: String, url: URL) {
        let old = held[id]
        held[id] = url
        if let old { backend.stop(old) }
    }

    static func normalizedPath(_ url: URL) -> String { PathCanonicalizer.canonical(url) }

    static func isInTrash(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }
}

/// One spelling for a path whether or not it exists: the longest existing ancestor is resolved with `realpath` (so `/tmp` and
/// `/private/tmp` agree, which `URL.resolvingSymlinksInPath()` only does for paths that exist) and the rest is appended. Every
/// "is this inside that folder" check in the grant code goes through it on both sides.
enum PathCanonicalizer {
    static func canonical(_ url: URL) -> String { canonical(url.standardizedFileURL.path) }

    static func canonical(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        var existing = (path as NSString).standardizingPath
        var tail: [String] = []
        while existing != "/" {
            if let real = realpath(existing, nil) {
                defer { free(real) }
                return tail.reversed().reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
            }
            tail.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return "/" + tail.reversed().joined(separator: "/")
    }
}

public enum GrantError: Error, Equatable, Sendable, LocalizedError {
    case accessRefused(String)
    /// The home folder (or a folder that contains it) was chosen.
    case isHomeFolder
    case notKubeFolder
    case doesNotCover(needed: String)
    /// Not offered in this edition or in this state (a gated build never opens `~/.kube`).
    case notAvailable

    public var errorDescription: String? {
        switch self {
        case .accessRefused(let path): "macOS did not grant access to \((path as NSString).lastPathComponent)."
        case .isHomeFolder: "That is your whole home folder. Wheelhouse only needs the .kube folder inside it, so choose that one instead."
        case .notKubeFolder: "Choose the .kube folder. To use a different folder, use Add Folder… in Settings → Moorings."
        case .doesNotCover(let needed): "That folder doesn't contain \(needed). Choose \(needed) itself, or a folder above it that is not your home folder."
        case .notAvailable: "Folder access is only used in the App Store edition."
        }
    }
}

/// Which folders may be granted (pure, so every rule is a test).
public enum FolderGrantPolicy {
    private static func normalized(_ url: URL) -> String { PathCanonicalizer.canonical(url) }

    /// A folder equal to, or above, the account home would be whole-home access.
    static func isHomeOrAbove(_ picked: URL, home: URL) -> Bool {
        let p = normalized(picked), h = normalized(home)
        return h == p || h.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    /// The first-run grant: the `.kube` folder, never the home folder.
    public static func validateKubeFolder(_ picked: URL, home: URL) throws {
        if isHomeOrAbove(picked, home: home) { throw GrantError.isHomeFolder }
        guard picked.lastPathComponent == ".kube" || normalized(picked) == normalized(home.appending(path: ".kube")) else { throw GrantError.notKubeFolder }
    }

    /// Add Folder…: any folder except the home folder and the folders above it.
    public static func validateFolder(_ picked: URL, home: URL) throws {
        if isHomeOrAbove(picked, home: home) { throw GrantError.isHomeFolder }
    }

    /// Grant Folder… for a referenced file's folder: the picked folder must contain `needed` and must not be the home folder.
    public static func validateAccessGrant(_ picked: URL, needed: String, home: URL) throws {
        if isHomeOrAbove(picked, home: home) { throw GrantError.isHomeFolder }
        let p = normalized(picked), n = PathCanonicalizer.canonical(needed)
        guard n == p || n.hasPrefix(p + "/") else { throw GrantError.doesNotCover(needed: tildePath(needed, home: home)) }
    }

    /// The account's own `.kube` folder (the first-run grant goes to its own kind).
    public static func isAccountKubeFolder(_ url: URL, home: URL) -> Bool {
        normalized(url) == normalized(home.appending(path: ".kube"))
    }

    /// `~/.minikube` for a path under the account home (never `NSHomeDirectory()`, which is the container in the sandbox).
    public static func tildePath(_ path: String, home: URL) -> String {
        let h = normalized(home)
        let p = PathCanonicalizer.canonical(path)
        if p == h { return "~" }
        return p.hasPrefix(h + "/") ? "~" + p.dropFirst(h.count) : path
    }

    /// Whether to show "Grant access to your .kube folder": sandboxed, the gate is off (a gated build must never open `~/.kube`), and no
    /// working grant exists.
    public static func shouldOfferKubeGrant(sandboxed: Bool, gateActive: Bool, hasWorkingKubeFolder: Bool) -> Bool {
        sandboxed && !gateActive && !hasWorkingKubeFolder
    }
}

/// Which folders to ask for when referenced files are denied.
public enum AccessFolderPlanner {
    /// The common parent of all denied files under the account home when it is strictly below the home folder; otherwise each file's own
    /// parent folder. `~/.config/foo/ca.crt` therefore asks for `~/.config/foo`, never `~/.config`.
    /// Never the home folder or a folder above it (granting those is refused): files directly in the home folder are in
    /// ``filesNeedingMove(forDenied:accountHome:)`` instead.
    public static func folders(forDenied paths: [String], accountHome: URL) -> [String] {
        let home = PathCanonicalizer.canonical(accountHome)
        let files = paths.map { PathCanonicalizer.canonical($0) }.filter { !isHomeLevel($0, home: home) }
        guard !files.isEmpty else { return [] }
        let parents = files.map { ($0 as NSString).deletingLastPathComponent }
        let inHome = parents.filter { $0.hasPrefix(home + "/") }
        if inHome.count == parents.count, let common = commonParent(inHome), common.hasPrefix(home + "/") { return [common] }
        return Array(Set(parents)).sorted()
    }

    /// Files whose folder is the home folder (or above it): no grant can fix those, the person has to move them into a folder.
    public static func filesNeedingMove(forDenied paths: [String], accountHome: URL) -> [String] {
        let home = PathCanonicalizer.canonical(accountHome)
        return paths.map { PathCanonicalizer.canonical($0) }.filter { isHomeLevel($0, home: home) }.sorted()
    }

    static func isHomeLevel(_ file: String, home: String) -> Bool {
        let parent = (file as NSString).deletingLastPathComponent
        return parent == home || home.hasPrefix(parent == "/" ? "/" : parent + "/")
    }

    /// What to tell the person about a file that sits directly in their home folder.
    public static func moveMessage(forFile path: String) -> String {
        "\((path as NSString).lastPathComponent) is directly in your home folder. Wheelhouse can't be given your whole home folder, so move the file into a folder (for example ~/.kube) and point the kubeconfig at it."
    }

    static func commonParent(_ folders: [String]) -> String? {
        guard var common = folders.first?.split(separator: "/", omittingEmptySubsequences: true).map(String.init) else { return nil }
        for f in folders.dropFirst() {
            let parts = f.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            common = Array(zip(common, parts).prefix { $0 == $1 }.map(\.0))
        }
        return common.isEmpty ? nil : "/" + common.joined(separator: "/")
    }
}

// MARK: - Probing

public enum FileAccessResult: Sendable, Equatable {
    case readable
    /// The file does not exist (ENOENT, ENOTDIR): a missing file, not an access problem.
    case missing
    /// The sandbox refused a file that exists (EPERM): a folder grant can fix it.
    case needsAccess
    /// Refused by file modes (EACCES): a grant would not help.
    case denied
    case other
}

public protocol FileAccessProbing: Sendable {
    func probe(_ path: String) -> FileAccessResult
}

/// `stat` succeeds and `open` gives EPERM: needs access (MAS-EDITION §9). EACCES is never "needs access".
public struct POSIXFileAccessProbe: FileAccessProbing {
    public init() {}

    public func probe(_ path: String) -> FileAccessResult {
        var st = stat()
        guard stat(path, &st) == 0 else { return Self.classify(statErrno: errno, openErrno: nil) }
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return .readable }
        return Self.classify(statErrno: nil, openErrno: errno)
    }

    public static func classify(statErrno: Int32?, openErrno: Int32?) -> FileAccessResult {
        if let e = statErrno { return (e == ENOENT || e == ENOTDIR) ? .missing : .other }
        guard let e = openErrno else { return .readable }
        switch e {
        case EPERM: return .needsAccess
        case EACCES: return .denied
        case ENOENT, ENOTDIR: return .missing
        default: return .other
        }
    }

    /// `Data(contentsOf:)` reports the sandbox's refusal as Cocoa 257 with POSIX 1 underneath.
    public static func classify(error: Error) -> FileAccessResult {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError, posix == EPERM { return .needsAccess }
        if ns.domain == NSPOSIXErrorDomain { return classify(statErrno: nil, openErrno: Int32(ns.code)) }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoSuchFileError { return .missing }
        return .other
    }
}

#endif
