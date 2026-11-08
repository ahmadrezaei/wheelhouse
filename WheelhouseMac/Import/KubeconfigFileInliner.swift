import Foundation
import WheelhouseDesktop

/// Turns a kubeconfig that points at files (`certificate-authority`, `client-certificate`, `client-key`, `tokenFile`) into one that
/// carries the data inline, so the shared parser sees a self-contained file. Paths resolve relative to the kubeconfig's folder.
///
/// This is the M1b stand-in for the loader that M3's `KubeconfigLoader.loadForImport` provides. It works line by line on the keys
/// `kubectl` writes, so it needs no YAML library and never rewrites anything else in the file.
///
/// SAFETY: while the gate is active, a referenced file under `~/.kube` is refused (symlinks resolved), exactly like the kubeconfig
/// itself. Only metadata is read for that check.
struct KubeconfigFileInliner {
    var gate: DevSafetyPolicy = .current
    /// Referenced files are certificates, keys and tokens; nothing legitimate is large.
    static let maxReferencedBytes = 256 * 1024

    enum Failure: LocalizedError, Equatable {
        case homeKube(String)
        case unreadable(String)
        case tooLarge(String)

        var errorDescription: String? {
            switch self {
            case .homeKube: "Development builds can't read ~/.kube."
            case .unreadable(let path): "The file \(path) referenced by this kubeconfig can't be read."
            case .tooLarge(let path): "The file \(path) referenced by this kubeconfig is too large."
            }
        }
    }

    private static let keyMap: [String: String] = [
        "certificate-authority": "certificate-authority-data",
        "client-certificate": "client-certificate-data",
        "client-key": "client-key-data",
    ]

    func inline(_ text: String, baseDirectory: URL) throws -> String {
        var out: [String] = []
        out.reserveCapacity(text.count / 40)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            out.append(try rewrite(String(line), baseDirectory: baseDirectory))
        }
        return out.joined(separator: "\n")
    }

    private func rewrite(_ line: String, baseDirectory: URL) throws -> String {
        // `<indent>[- ]key: value`
        guard let colon = line.firstIndex(of: ":") else { return line }
        let head = line[..<colon]
        let key = head.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        let isTokenFile = key == "tokenFile"
        guard Self.keyMap[key] != nil || isTokenFile else { return line }
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let hash = value.range(of: " #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if value.count >= 2, (value.first == "\"" && value.last == "\"") || (value.first == "'" && value.last == "'") { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty else { return line }

        let url = value.hasPrefix("/") ? URL(fileURLWithPath: value) : baseDirectory.appending(path: value)
        try assertAllowed(url)
        let data = try read(url, display: value)
        let prefix = String(head)
        if isTokenFile {
            let token = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let replacedKey = prefix.replacingOccurrences(of: "tokenFile", with: "token")
            return "\(replacedKey): \(token)"
        }
        let replacedKey = prefix.replacingOccurrences(of: key, with: Self.keyMap[key]!)
        return "\(replacedKey): \(data.base64EncodedString())"
    }

    private func assertAllowed(_ url: URL) throws {
        // `assertReadable` also covers symlinks and hard links into ~/.kube (device and inode), exactly like the kubeconfig itself.
        do { try gate.assertReadable(url) } catch { throw Failure.homeKube(url.path) }
    }

    private func read(_ url: URL, display: String) throws -> Data {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { throw Failure.unreadable(display) }
        if let size = attrs[.size] as? Int, size > Self.maxReferencedBytes { throw Failure.tooLarge(display) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(display) }
        return data
    }
}
