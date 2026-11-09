#if os(macOS)
import CryptoKit
import Darwin
import Foundation

/// The pinned Trivy release (data shipped inside the app, `Resources/trivy/pin.json`). Complete or empty, never half filled.
public struct TrivyPin: Codable, Equatable, Sendable {
    public var version: String
    /// For example `trivy_0.60.0_macOS-ARM64.tar.gz`.
    public var archiveName: String
    public var url: URL
    public var archiveSHA256: String
    public var archiveSize: Int64
    /// SHA-256 of the `trivy` executable inside the archive: the trust anchor re-checked before the first run of every launch.
    public var binarySHA256: String

    public init(version: String, archiveName: String, url: URL, archiveSHA256: String, archiveSize: Int64, binarySHA256: String) {
        self.version = version
        self.archiveName = archiveName
        self.url = url
        self.archiveSHA256 = archiveSHA256
        self.archiveSize = archiveSize
        self.binarySHA256 = binarySHA256
    }

    public enum State: Equatable, Sendable {
        case available(TrivyPin)
        case unavailable(String)
    }

    public static let unavailableMessage = "This build of Wheelhouse does not include a pinned Trivy release, so it cannot download one. Install trivy yourself (for example with Homebrew) and set its path in Settings."

    /// Parses `pin.json`. Anything that is not complete (valid hashes, an https URL on the file name, a positive size) is "unavailable".
    public static func parse(_ data: Data) -> State {
        guard let pin = try? JSONDecoder().decode(TrivyPin.self, from: data), pin.isValid else { return .unavailable(unavailableMessage) }
        return .available(pin)
    }

    public static var bundled: State {
        guard let url = Bundle.module.url(forResource: "pin", withExtension: "json", subdirectory: "Resources/trivy"),
              let data = try? Data(contentsOf: url) else { return .unavailable(unavailableMessage) }
        return parse(data)
    }

    var isValid: Bool {
        func hex(_ s: String) -> Bool { s.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil }
        return !version.isEmpty && version.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && archiveName.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil
            && url.scheme == "https" && url.lastPathComponent == archiveName && hex(archiveSHA256) && hex(binarySHA256) && archiveSize > 0
    }
}

/// What the consent sheet shows before anything is downloaded: file name, URL, size and SHA-256 (all from the pin: no network call
/// happens before consent).
public struct TrivyConsent: Equatable, Sendable {
    public var fileName: String
    public var url: URL
    public var size: Int64
    public var sha256: String
    public var installLocation: URL
}

public enum ManagedTrivyError: Error, Equatable, Sendable, LocalizedError {
    case unavailable
    case insecureURL
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(what: String)
    case extractionFailed(String)
    case notARegularFile
    case badSignature(String)
    case tooLarge(limit: Int64)

    public var errorDescription: String? {
        switch self {
        case .unavailable: TrivyPin.unavailableMessage
        case .insecureURL: "The download address is not https."
        case .sizeMismatch(let e, let a): "The download is \(a) bytes, expected \(e). It was discarded."
        case .checksumMismatch(let what): "The \(what) does not match its pinned SHA-256. It was discarded."
        case .extractionFailed(let why): "The archive could not be unpacked: \(why)"
        case .notARegularFile: "The archive does not contain a plain trivy file."
        case .badSignature(let why): "The program's code signature is invalid: \(why)"
        case .tooLarge(let limit): "The download is larger than the pinned \(limit) bytes and was stopped."
        }
    }
}

/// Writes a URL's content to a file on disk (not into memory: the archive is large).
public protocol TrivyDownloader: Sendable {
    /// Writes at most `maxBytes` (more fails with ``ManagedTrivyError/tooLarge(limit:)``).
    func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws
}

/// The real downloader: an ephemeral URLSession that accepts only https and refuses any redirect that is not https. The body is
/// streamed to disk in 1 MB chunks and stopped as soon as it passes `maxBytes`.
public struct URLSessionTrivyDownloader: TrivyDownloader {
    public init() {}

    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(request.url?.scheme == "https" ? request : nil)
        }
    }

    public func download(_ url: URL, to destination: URL, maxBytes: Int64) async throws {
        guard url.scheme == "https" else { throw ManagedTrivyError.insecureURL }
        let session = URLSession(configuration: .ephemeral, delegate: HTTPSOnly(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response) = try await session.bytes(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw URLError(.badServerResponse) }
        if response.expectedContentLength > maxBytes { throw ManagedTrivyError.tooLarge(limit: maxBytes) }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        var total: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                total += Int64(buffer.count)
                if total > maxBytes { try? fm.removeItem(at: destination); throw ManagedTrivyError.tooLarge(limit: maxBytes) }
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        total += Int64(buffer.count)
        if total > maxBytes { try? fm.removeItem(at: destination); throw ManagedTrivyError.tooLarge(limit: maxBytes) }
        try handle.write(contentsOf: buffer)
    }
}

/// The managed, Mac-private Trivy install (ARCHITECTURE-MAC §6.1 item 3). DEVIATION from §6.1, which names `Vendor/trivy/VERSION` and
/// `SHA256SUMS`: the pin is one JSON file in this module's resources (`Resources/trivy/pin.json`), because the Mac-only Desktop module
/// already ships a resource folder and the pin carries the archive size and the binary hash as well. Same trust model: data inside the app.
///
/// Steps: consent first, then download, SHA-256 of the archive,
/// unpack, SHA-256 of the executable, install at `<AppPaths.root>/tools/trivy/<version>/trivy` (0755). Never auto-updated and never
/// bundled. Debug and Profile builds use their own isolated root, so a development build never touches the real install.
public struct ManagedTrivy: Sendable {
    public var paths: AppPaths
    public var pin: TrivyPin.State
    public var downloader: any TrivyDownloader

    public init(paths: AppPaths, pin: TrivyPin.State = TrivyPin.bundled, downloader: any TrivyDownloader = URLSessionTrivyDownloader()) {
        self.paths = paths
        self.pin = pin
        self.downloader = downloader
    }

    public var installDirectory: URL? {
        guard case .available(let p) = pin else { return nil }
        return paths.root.appending(path: "tools/trivy/\(p.version)", directoryHint: .isDirectory)
    }
    public var executableURL: URL? { installDirectory?.appending(path: "trivy") }

    public var consent: TrivyConsent? {
        guard case .available(let p) = pin, let dir = installDirectory else { return nil }
        return TrivyConsent(fileName: p.archiveName, url: p.url, size: p.archiveSize, sha256: p.archiveSHA256, installLocation: dir)
    }

    /// Downloads and installs. The caller calls this only after the user accepted the consent sheet.
    @discardableResult
    public func install() async throws -> URL {
        guard case .available(let p) = pin, let dir = installDirectory, let target = executableURL else { throw ManagedTrivyError.unavailable }
        guard p.url.scheme == "https" else { throw ManagedTrivyError.insecureURL }
        let fm = FileManager.default
        let work = paths.temporaryDirectory.appending(path: "wheelhouse-trivy-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: work) }
        let archive = work.appending(path: p.archiveName)
        try await downloader.download(p.url, to: archive, maxBytes: p.archiveSize)
        let size = ((try? fm.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.int64Value ?? -1
        guard size == p.archiveSize else { throw ManagedTrivyError.sizeMismatch(expected: p.archiveSize, actual: size) }
        guard try Self.sha256(of: archive) == p.archiveSHA256 else { throw ManagedTrivyError.checksumMismatch(what: "download") }
        let out = work.appending(path: "out", directoryHint: .isDirectory)
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let tar = try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/tar"), arguments: ["-xzf", archive.path, "-C", out.path, "trivy"],
                                                       environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(120)))
        guard tar.exit.succeeded else { throw ManagedTrivyError.extractionFailed(tar.stderrString) }
        let binary = out.appending(path: "trivy")
        guard Self.isRegularFile(binary.path) else { throw ManagedTrivyError.notARegularFile }
        guard try Self.sha256(of: binary) == p.binarySHA256 else { throw ManagedTrivyError.checksumMismatch(what: "program") }
        // If the vendor signs the program the signature must be valid. An unsigned program is allowed: the pinned hash is the trust anchor.
        let signature = try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/codesign"), arguments: ["-v", "--strict", binary.path],
                                                             environment: ["PATH": "/usr/bin:/bin"], timeout: .seconds(60)))
        if !signature.exit.succeeded, !signature.stderrString.contains("not signed at all") { throw ManagedTrivyError.badSignature(signature.stderrString) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: target)
        try fm.moveItem(at: binary, to: target)
        chmod(target.path, 0o755)
        Self.verified.withLock { $0.removeAll() }
        return target
    }

    /// The installed executable, only when it still matches the pinned hash. The hash is recomputed once per launch for a given file
    /// (path, size and modification time); a changed or replaced file is hashed again. nil when absent or different.
    public func verifiedExecutable() -> URL? {
        guard case .available(let p) = pin, let target = executableURL, Self.isRegularFile(target.path) else { return nil }
        var st = stat()
        guard stat(target.path, &st) == 0 else { return nil }
        let key = "\(target.path)|\(st.st_size)|\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)|\(st.st_ino)|\(p.binarySHA256)"
        if Self.verified.withLock({ $0.contains(key) }) { return target }
        guard (try? Self.sha256(of: target)) == p.binarySHA256 else { return nil }
        Self.verified.withLock { $0.insert(key) }
        return target
    }

    /// ``verifiedExecutable()`` without blocking the caller: hashing a 100 MB program takes a moment, so it runs on a utility queue.
    public func verifiedExecutableOffMain() async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            DispatchQueue.global(qos: .utility).async { continuation.resume(returning: self.verifiedExecutable()) }
        }
    }

    /// Removes the managed install.
    public func remove() {
        if let d = installDirectory { try? FileManager.default.removeItem(at: d) }
        Self.verified.withLock { $0.removeAll() }
    }

    // MARK: Helpers

    private static let verified = LockedSet()

    static func isRegularFile(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    /// Streams the file through SHA-256 in 1 MB chunks.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

private final class LockedSet: @unchecked Sendable {
    private let lock = NSLock()
    private var set = Set<String>()
    func withLock<T>(_ body: (inout Set<String>) -> T) -> T { lock.withLock { body(&set) } }
}
#endif
