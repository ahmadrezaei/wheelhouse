#if os(macOS)
import Foundation
import WheelhouseKit

public enum KubeconfigLoadError: Error, Equatable, Sendable, LocalizedError {
    case tooLarge(String)
    case unreadable(String)
    case invalid(String, String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let p): "This file is unusually large: \((p as NSString).lastPathComponent)."
        case .unreadable(let p): "\((p as NSString).lastPathComponent) could not be read."
        case .invalid(let p, let why): "\((p as NSString).lastPathComponent) is not a usable kubeconfig: \(why)"
        }
    }
}

/// One file as read from disk.
public struct LoadedFile: Sendable {
    public var url: URL
    /// realpath (symlinks resolved): the identity of the file.
    public var canonicalPath: String
    public var contentHash: String
    var document: KubeconfigParser.Document
}

public struct LoadedContext: Sendable {
    public var context: KubeconfigContext
    public var definingFile: String
    public var isCurrent: Bool
    /// File name of the earlier file that defines the same context name (default set only).
    public var shadowedBy: String?
}

public struct LoadedSet: Sendable {
    public var contexts: [LoadedContext] = []
    /// Content hash per canonical path, for the "unchanged, stop" check of the watcher.
    public var fileHashes: [String: String] = [:]
    /// Files that exist but could not be used (too large, not a kubeconfig). Missing files are skipped silently, like kubectl.
    public var issues: [String: String] = [:]
}

/// Emulates client-go's kubeconfig loading so the app sees what kubectl sees (ARCHITECTURE-MAC §4.2).
///
/// Every read goes through `DevSafetyPolicy.assertReadable`, so while the gate is active a path under `~/.kube` (or a symlink or
/// hard link into it) throws before the file is opened, for EVERY source type.
public struct KubeconfigLoader: Sendable {
    public static let maxFileSize = 4 << 20
    public var gate: DevSafetyPolicy

    public init(gate: DevSafetyPolicy = .current) { self.gate = gate }

    /// Reads one file. Returns nil when it does not exist.
    func readFile(_ url: URL) throws -> LoadedFile? {
        try gate.assertReadable(url)
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        // The canonical path is checked too: a symlink target may live under ~/.kube even when the link does not.
        try gate.assertReadable(canonical)
        var st = stat()
        guard stat(canonical.path, &st) == 0 else { return nil }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw KubeconfigLoadError.unreadable(url.path) }
        guard st.st_size <= Self.maxFileSize else { throw KubeconfigLoadError.tooLarge(url.path) }
        guard let data = try? Data(contentsOf: canonical) else { throw KubeconfigLoadError.unreadable(url.path) }
        guard let text = String(data: data, encoding: .utf8) else { throw KubeconfigLoadError.invalid(url.path, "it is not UTF-8 text") }
        do {
            // Relative paths in the file resolve against the folder of the path as given (client-go behaviour).
            let doc = try KubeconfigParser.parseDocument(text, baseDirectory: url.deletingLastPathComponent().standardizedFileURL)
            return LoadedFile(url: url, canonicalPath: canonical.path, contentHash: data.sha256Hex, document: doc)
        } catch let e as KubeconfigError {
            throw KubeconfigLoadError.invalid(url.path, "\(e)")
        }
    }

    /// The default set (`KUBECONFIG` entries in order, or `~/.kube/config`): merged, first definition of a name wins.
    public func loadDefaultSet(_ urls: [URL]) throws -> LoadedSet {
        var files: [LoadedFile] = []
        var set = LoadedSet()
        for url in urls {
            do {
                if let f = try readFile(url) { files.append(f); set.fileHashes[f.canonicalPath] = f.contentHash }
            } catch let e as DevSafetyError {
                throw e
            } catch {
                set.issues[url.path] = error.localizedDescription
            }
        }
        // Entries naming the same file twice are merged once.
        var seen = Set<String>()
        files = files.filter { seen.insert($0.canonicalPath).inserted }
        let merged = KubeconfigParser.merge(files.map(\.document), desktop: true)
        for m in merged.contexts {
            let shadowed = merged.shadowed.first { $0.name == m.context.name }
            set.contexts.append(LoadedContext(context: m.context, definingFile: files[m.fileIndex].canonicalPath,
                                              isCurrent: m.context.name == merged.currentContext,
                                              shadowedBy: nil))
            _ = shadowed
        }
        // Shadowed contexts are listed (not added): "shadowed by work.yaml".
        for s in merged.shadowed {
            let loser = files[s.fileIndex]
            if let ctx = Self.context(named: s.name, in: loser.document) {
                set.contexts.append(LoadedContext(context: ctx, definingFile: loser.canonicalPath, isCurrent: false,
                                                  shadowedBy: (files[s.shadowedByFileIndex].canonicalPath as NSString).lastPathComponent))
            }
        }
        return set
    }

    /// A file, folder entry or Landfall file on its own: one set per file, so duplicates are separate clusters.
    public func loadStandalone(_ url: URL) throws -> LoadedSet {
        var set = LoadedSet()
        do {
            guard let f = try readFile(url) else { return set }
            set.fileHashes[f.canonicalPath] = f.contentHash
            let merged = KubeconfigParser.merge([f.document], desktop: true)
            set.contexts = merged.contexts.map {
                LoadedContext(context: $0.context, definingFile: f.canonicalPath, isCurrent: $0.context.name == merged.currentContext, shadowedBy: nil)
            }
        } catch let e as DevSafetyError {
            throw e
        } catch {
            set.issues[url.path] = error.localizedDescription
        }
        return set
    }

    /// Standalone sets for every candidate file of a folder (one level deep, or all levels).
    public func loadFolder(_ folder: URL, recursive: Bool) throws -> LoadedSet {
        try gate.assertReadable(folder)
        try gate.assertReadable(folder.resolvingSymlinksInPath())
        var combined = LoadedSet()
        for url in Self.candidateFiles(in: folder, recursive: recursive) {
            let s = try loadStandalone(url)
            combined.contexts += s.contexts
            combined.fileHashes.merge(s.fileHashes) { a, _ in a }
            combined.issues.merge(s.issues) { a, _ in a }
        }
        return combined
    }

    /// `loadForImport(url:)` of ARCHITECTURE-MAC §4.8: resolves the realpath, applies the size limit and the gate, parses with
    /// `.desktop`. Throws ``DevSafetyError/homeKubeconfig(_:)`` for a file under `~/.kube` while the gate is active.
    public func loadForImport(url: URL) throws -> LoadedSet {
        try gate.assertReadable(url)
        let s = try loadStandalone(url)
        if s.contexts.isEmpty, let why = s.issues.values.first { throw KubeconfigLoadError.invalid(url.path, why) }
        return s
    }

    // MARK: Folder scanning

    /// File names a folder source considers: `*.yaml`, `*.yml`, `*config*`. Lock and temporary files are ignored.
    public static func isCandidateName(_ name: String) -> Bool {
        guard !isIgnoredName(name) else { return false }
        let lower = name.lowercased()
        return lower.hasSuffix(".yaml") || lower.hasSuffix(".yml") || lower.contains("config")
    }

    public static func isIgnoredName(_ name: String) -> Bool {
        name.hasSuffix(".lock") || name.hasPrefix(".#") || name.hasSuffix("~") || name.hasSuffix(".swp") || name.hasSuffix(".tmp")
            || name == ".DS_Store"
    }

    static func candidateFiles(in folder: URL, recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        if recursive {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
            for case let url as URL in e where isCandidateName(url.lastPathComponent) && (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.append(url)
            }
        } else if let names = try? fm.contentsOfDirectory(atPath: folder.path) {
            for n in names.sorted() where isCandidateName(n) {
                let url = folder.appending(path: n)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue { out.append(url) }
            }
        }
        return out
    }

    private static func context(named name: String, in doc: KubeconfigParser.Document) -> KubeconfigContext? {
        KubeconfigParser.merge([doc], desktop: true).contexts.first { $0.context.name == name }?.context
    }
}
#endif
