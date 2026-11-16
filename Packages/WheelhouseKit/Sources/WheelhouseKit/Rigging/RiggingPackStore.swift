import CryptoKit
import Darwin
import Foundation

/// A pack read from disk or the app bundle, with the digest of the exact bytes that were parsed.
public struct LoadedRiggingPack: Hashable, Sendable {
    public var pack: RiggingPack
    /// SHA-256 (hex) of `rigging.yaml`. An enabled pack whose digest changes is switched off until it is approved again.
    public var digest: String
    public var text: String
}

/// Reads a pack folder. A pack is data only, so the reader refuses what could reach outside the folder: a symlink anywhere in it
/// (including `rigging.yaml` itself), a folder with too much in it, or a `rigging.yaml` that is not a plain file.
public enum RiggingPackFolder {
    public static let maxEntries = 500
    public static let maxTotalBytes = 5 * 1024 * 1024
    public static let fileName = "rigging.yaml"

    public static func load(_ folder: URL) throws -> LoadedRiggingPack {
        try audit(folder)
        let data = try readRegularFile(folder.appending(path: fileName).path, limit: RiggingPackParser.maxBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw RiggingPackError("rigging.yaml is not UTF-8 text.") }
        let pack = try RiggingPackParser.parse(text)
        return LoadedRiggingPack(pack: pack, digest: digest(of: data), text: text)
    }

    public static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Opens without following a final symlink and checks the descriptor, so the file that is read is the file that was checked.
    static func readRegularFile(_ path: String, limit: Int) throws -> Data {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw RiggingPackError(errno == ELOOP ? "rigging.yaml is a symbolic link; packs may not contain links." : "The folder has no readable rigging.yaml.") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw RiggingPackError("rigging.yaml is not a regular file.") }
        guard st.st_size <= off_t(limit) else { throw RiggingPackError("rigging.yaml is larger than \(limit / 1024) KB.") }
        return try FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true).readToEnd() ?? Data()
    }

    /// Walks the folder without following links. `.git` is skipped (nothing reads it, and a git pack's is removed after the checkout).
    static func audit(_ folder: URL) throws {
        let fm = FileManager.default
        func type(_ url: URL) -> FileAttributeType? { (try? fm.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType }
        guard type(folder) == .typeDirectory else {
            throw RiggingPackError(type(folder) == .typeSymbolicLink ? "The pack folder is a symbolic link; choose the real folder." : "That is not a folder.")
        }
        var entries = 0
        var bytes = 0
        func walk(_ dir: URL) throws {
            for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
                guard name != "..", name != "." else { throw RiggingPackError("A pack may not contain “..” paths.") }
                if dir == folder, name == ".git" { continue }
                let url = dir.appending(path: name)
                entries += 1
                guard entries <= maxEntries else { throw RiggingPackError("The pack folder holds more than \(maxEntries) items.") }
                switch type(url) {
                case .typeSymbolicLink?: throw RiggingPackError("“\(name)” is a symbolic link; packs may not contain links.")
                case .typeDirectory?: try walk(url)
                case .typeRegular?:
                    bytes += ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
                    guard bytes <= maxTotalBytes else { throw RiggingPackError("The pack folder is larger than \(maxTotalBytes / 1024 / 1024) MB.") }
                default: throw RiggingPackError("“\(name)” is not a regular file or folder.")
                }
            }
        }
        try walk(folder)
    }
}

/// The packs that ship inside the app (`BundledData/rigging/packs/*.yaml`).
public enum BuiltInRiggingPacks {
    public static let directory: URL? = Bundle.module.url(forResource: "BundledData", withExtension: nil)?.appending(path: "rigging/packs")

    /// Every bundled pack that parses; the unit tests assert none is dropped.
    public static let all: [LoadedRiggingPack] = {
        guard let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.filter { $0.hasSuffix(".yaml") }.sorted().compactMap { name in
            guard let data = try? Data(contentsOf: directory.appending(path: name)), let text = String(data: data, encoding: .utf8),
                  let pack = try? RiggingPackParser.parse(text) else { return nil }
            return LoadedRiggingPack(pack: pack, digest: RiggingPackFolder.digest(of: data), text: text)
        }
    }()

    public static let names = ["cert-manager", "karpenter", "keda", "external-secrets", "cloudnative-pg", "istio", "velero", "gateway-api"]
}
