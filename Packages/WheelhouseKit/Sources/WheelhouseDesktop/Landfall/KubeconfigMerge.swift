#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import WheelhouseKit

public enum KubeconfigWriteError: Error, Equatable, Sendable, LocalizedError {
    case unreadable(String)
    case tooLarge
    /// More than one hard link: `rename` would silently break the link.
    case hardLinked
    case locked
    case changedSinceReview
    case backupFailed(String)
    case writeFailed(String)
    /// The result did not match; `restored` says whether the original is back in place.
    case verificationFailed(String, restored: Bool)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let why): "The kubeconfig could not be read: \(why)"
        case .tooLarge: "The kubeconfig is unusually large, so Wheelhouse does not change it."
        case .hardLinked: "The kubeconfig has more than one hard link, so Wheelhouse does not change it."
        case .locked: "Another program is changing the kubeconfig right now (config.lock exists). Try again in a moment."
        case .changedSinceReview: "The kubeconfig changed after you reviewed the merge. Review it again."
        case .backupFailed(let why): "The backup could not be made: \(why)"
        case .writeFailed(let why): "The kubeconfig could not be written: \(why)"
        case .verificationFailed(let why, let restored): "\(why) " + (restored ? "Your original file was put back." : "Restoring the original failed; the backup is next to the file.")
        }
    }
}

/// What a merge will do: shown before anything is written (ARCHITECTURE-MAC §4.9 step 1).
public struct KubeconfigMergePlan: Sendable, Equatable {
    /// The file that will be changed (symlinks resolved).
    public var target: URL
    /// The exact YAML of the entries to merge.
    public var yaml: String
    public var backup: URL?
    public var added: [String]
    public var replaced: [String]
    /// SHA-256 of the file as reviewed; nil when it does not exist yet.
    public var baseHash: String?
    public var currentContext: String?
}

public struct KubeconfigMergeResult: Sendable, Equatable {
    public var target: URL
    public var backup: URL?
    public var added: [String]
    public var replaced: [String]
}

/// The native merge (ARCHITECTURE-MAC §4.9). The vendor commands (`aws eks update-kubeconfig`, `gcloud … get-credentials`,
/// `az aks get-credentials`) are never run against a user's file: they change `current-context`.
///
/// Steps: plan (shows the YAML and the backup name) → lock → backup (0600) → merge in memory → write a temporary file in the same folder
/// → re-check the original has not changed → rename → read back and verify; on any mismatch the backup is restored.
extension KubeconfigWriter {
    static let maxSize = 4 << 20

    /// Refuses every write while the gate is active, and refuses a path under any `~/.kube` while the PROCESS gate is active even when
    /// an open policy was injected (so a test cannot reach the real file).
    func assertMayMerge(into target: URL) throws {
        try assertMayWrite()
        let probe = DevSafetyPolicy(isActive: true, home: gate.home)
        if DevSafety.isActive, probe.isUnderHomeKube(target) { throw DevSafetyError.homeKubeconfig(target.path) }
    }

    static func resolve(_ url: URL) -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return url.resolvingSymlinksInPath().standardizedFileURL }
        // A new file: resolve its folder so the temporary file and the target share one.
        return url.deletingLastPathComponent().resolvingSymlinksInPath().appending(path: url.lastPathComponent)
    }

    private static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private static func read(_ url: URL) throws -> (text: String?, data: Data?, mode: mode_t) {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return (nil, nil, 0o600) }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw KubeconfigWriteError.unreadable("not a regular file") }
        guard st.st_nlink == 1 else { throw KubeconfigWriteError.hardLinked }
        guard st.st_size <= maxSize else { throw KubeconfigWriteError.tooLarge }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw KubeconfigWriteError.unreadable("it is not UTF-8 text") }
        return (text, data, st.st_mode & 0o7777)
    }

    public func plan(entries: KubeconfigEntries, into url: URL, now: Date = Date(), backup wantsBackup: Bool = true) throws -> KubeconfigMergePlan {
        try assertMayMerge(into: url)               // from the path alone, before anything is looked at
        let target = Self.resolve(url)
        try assertMayMerge(into: target)
        let (text, data, _) = try Self.read(target)
        let yaml = try entries.yaml()
        let merged = try KubeconfigMergeEditor.merge(existing: text, entriesYAML: yaml)
        let fm = FileManager.default
        var backup: URL?
        if data != nil, wantsBackup {
            let base = "\(target.lastPathComponent).wheelhouse-backup-\(Self.stamp(now))"
            var candidate = target.deletingLastPathComponent().appending(path: base)
            var n = 2
            while fm.fileExists(atPath: candidate.path) { candidate = target.deletingLastPathComponent().appending(path: "\(base)-\(n)"); n += 1 }
            backup = candidate
        }
        let current = text.flatMap { t -> String? in
            guard let root = try? KubeconfigParser.parse(t) else { return nil }
            return root.currentContext
        }
        return KubeconfigMergePlan(target: target, yaml: yaml, backup: backup, added: merged.added, replaced: merged.replaced,
                                   baseHash: data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }, currentContext: current)
    }

    /// Plans and merges in one step (Landfall's own `landfall.yaml`).
    @discardableResult
    public func merge(entries: KubeconfigEntries, into url: URL, now: Date = Date(), backup: Bool = true) throws -> KubeconfigMergeResult {
        try merge(plan: try plan(entries: entries, into: url, now: now, backup: backup), entries: entries)
    }

    @discardableResult
    public func merge(plan: KubeconfigMergePlan, entries: KubeconfigEntries) throws -> KubeconfigMergeResult {
        try merge(plan: plan, entries: entries, afterWrite: nil)
    }

    /// `afterWrite` runs after the rename and before verification (tests corrupt the file there to exercise the restore).
    @discardableResult
    func merge(plan: KubeconfigMergePlan, entries: KubeconfigEntries, afterWrite: ((URL) throws -> Void)?) throws -> KubeconfigMergeResult {
        let target = plan.target
        try assertMayMerge(into: target)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // client-go's convention: `<file>.lock`, created exclusively.
        let lock = target.appendingPathExtension("lock")
        let lockFD = open(lock.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard lockFD >= 0 else { throw KubeconfigWriteError.locked }
        close(lockFD)
        defer { unlink(lock.path) }

        let (text, data, mode) = try Self.read(target)
        let hash = data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        guard hash == plan.baseHash else { throw KubeconfigWriteError.changedSinceReview }
        let yaml = try entries.yaml()
        guard yaml == plan.yaml else { throw KubeconfigWriteError.changedSinceReview }
        let merged = try KubeconfigMergeEditor.merge(existing: text, entriesYAML: yaml)
        _ = try KubeconfigParser.parse(merged.text)

        // 2. Backup (0600, exclusive: never overwrites an earlier one).
        if let data, let backup = plan.backup {
            let fd = open(backup.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
            guard fd >= 0 else { throw KubeconfigWriteError.backupFailed("\(backup.lastPathComponent) already exists") }
            defer { close(fd) }
            guard Self.writeAll(fd, data) else { unlink(backup.path); throw KubeconfigWriteError.backupFailed("it could not be written") }
        }

        // 4. Write atomically, keeping the original mode.
        func restore() -> Bool {
            guard let data else { return unlink(target.path) == 0 || !fm.fileExists(atPath: target.path) }
            return (try? Self.atomicWrite(data, to: target, mode: mode)) != nil
        }
        do { try Self.atomicWrite(Data(merged.text.utf8), to: target, mode: mode, expecting: (data, hash)) } catch let e as KubeconfigWriteError { throw e }
        catch { throw KubeconfigWriteError.writeFailed(error.localizedDescription) }

        // 5. Verify: read back; current-context and every untouched entry must be unchanged.
        do {
            try afterWrite?(target)
            let written = try String(contentsOf: target, encoding: .utf8)
            try KubeconfigMergeEditor.verify(before: text, after: written, entriesYAML: yaml)
            _ = try KubeconfigParser.parse(written)
        } catch {
            let restored = restore()
            throw KubeconfigWriteError.verificationFailed(error.localizedDescription, restored: restored)
        }
        return KubeconfigMergeResult(target: target, backup: plan.backup, added: merged.added, replaced: merged.replaced)
    }

    private static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { buffer -> Bool in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Temporary file in the same folder, the original mode, `fsync`, `rename`. With `expecting`, the target is compared once more just
    /// before the rename (size, mtime and content) and the write is abandoned when another program changed it.
    static func atomicWrite(_ data: Data, to target: URL, mode: mode_t, expecting: (Data?, String?)? = nil) throws {
        let tmp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).wheelhouse-tmp-\(UUID().uuidString)")
        let fd = open(tmp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw KubeconfigWriteError.writeFailed("a temporary file could not be created") }
        var ok = writeAll(fd, data) && fchmod(fd, mode) == 0 && fsync(fd) == 0
        close(fd)
        if ok, let expecting {
            let now = try? Data(contentsOf: target)
            ok = now == expecting.0
            if !ok { unlink(tmp.path); throw KubeconfigWriteError.changedSinceReview }
        }
        guard ok, rename(tmp.path, target.path) == 0 else {
            unlink(tmp.path)
            throw KubeconfigWriteError.writeFailed("the file could not be replaced")
        }
    }
}
#endif
