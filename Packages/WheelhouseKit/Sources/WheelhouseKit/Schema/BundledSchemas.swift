import Foundation

/// The OpenAPI schemas shipped inside the app (`BundledData/openapi/k8s-<minor>.json.lzfse`), used when a cluster does not serve
/// `/openapi/v3` or the user may not read it. A cluster picks the file of the nearest Kubernetes minor version.
public struct BundledSchemas: Sendable {
    /// The files, by minor version (`"1.32"`).
    private let files: [String: URL]

    public init(directory: URL?) {
        var found: [String: URL] = [:]
        if let directory, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for name in names where name.hasPrefix("k8s-") && name.hasSuffix(".json.lzfse") {
                let minor = String(name.dropFirst(4).dropLast(".json.lzfse".count))
                found[minor] = directory.appending(path: name)
            }
        }
        files = found
    }

    /// The copy inside WheelhouseKit's resource bundle.
    public static let standard = BundledSchemas(directory: standardDirectory)
    static let standardDirectory = Bundle.module.url(forResource: "BundledData", withExtension: nil)?.appending(path: "openapi")

    public var minors: [String] { files.keys.sorted { Self.order($0, $1) } }

    /// The bundled minor closest to `serverVersion` (`v1.31.4`, `1.32`, …); ties go to the newer one. Without a version: the newest.
    public func nearestMinor(to serverVersion: String?) -> String? {
        guard !files.isEmpty else { return nil }
        guard let want = serverVersion.flatMap(Self.minorNumber) else { return minors.last }
        return files.keys.min { a, b in
            let da = abs((Self.minorNumber(a) ?? 0) - want), db = abs((Self.minorNumber(b) ?? 0) - want)
            return da != db ? da < db : (Self.minorNumber(a) ?? 0) > (Self.minorNumber(b) ?? 0)
        }
    }

    /// Loads the group-versions of a minor version. `nil` when the file is missing or unreadable.
    func load(minor: String) -> [String: LoadedSchemaDocument]? {
        guard let url = files[minor], let packed = try? Data(contentsOf: url),
              let data = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let root = try? JSONValue.fastParse(data), let groups = root["groupVersions"]?.objectValue else { return nil }
        return groups.mapValues { LoadedSchemaDocument(components: $0) }
    }

    /// `v1.32.4+k3s1` → 32 (the minor number); nil when it does not look like a version.
    static func minorNumber(_ version: String) -> Int? {
        let digits = version.drop { $0 == "v" || $0 == "V" }
        let parts = digits.split(whereSeparator: { $0 == "." || $0 == "+" || $0 == "-" })
        guard parts.count >= 2, Int(parts[0]) != nil else { return nil }
        return Int(parts[1].prefix { $0.isNumber })
    }

    private static func order(_ a: String, _ b: String) -> Bool { (minorNumber(a) ?? 0) < (minorNumber(b) ?? 0) }
}
