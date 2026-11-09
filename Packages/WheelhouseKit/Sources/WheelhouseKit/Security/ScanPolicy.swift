import Foundation

/// How a scan was started. A manual scan is the user's explicit request and overrides the energy rules.
public enum ScanTrigger: String, Codable, Sendable { case manual, scheduled }

/// What the Mac can afford right now.
public struct ScanConditions: Equatable, Sendable {
    public var onBattery: Bool
    public var lowPowerMode: Bool
    public var thermalState: ProcessInfo.ThermalState

    public init(onBattery: Bool = false, lowPowerMode: Bool = false, thermalState: ProcessInfo.ThermalState = .nominal) {
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
    }
}

/// ARCHITECTURE-MAC §6.1 and §12.3: scans never run on battery, in Low Power Mode or at thermal `serious` or worse, unless the user
/// started them manually. Pure.
public enum ScanGate {
    public enum Decision: Equatable, Sendable {
        case allowed
        case paused(PauseReason)
    }
    public enum PauseReason: String, Equatable, Sendable {
        case onBattery, lowPowerMode, thermal
        public var message: String {
            switch self {
            case .onBattery: "Paused: the Mac is on battery."
            case .lowPowerMode: "Paused: Low Power Mode is on."
            case .thermal: "Paused: the Mac is running hot."
            }
        }
    }

    /// `onlyOnPower` is the Settings switch ("scan only on power adapter", on by default); battery pauses only while it is on.
    public static func decide(trigger: ScanTrigger, conditions: ScanConditions, onlyOnPower: Bool = true) -> Decision {
        if trigger == .manual { return .allowed }
        if conditions.thermalState == .serious || conditions.thermalState == .critical { return .paused(.thermal) }
        if conditions.lowPowerMode { return .paused(.lowPowerMode) }
        if conditions.onBattery, onlyOnPower { return .paused(.onBattery) }
        return .allowed
    }

    /// Process QoS: `.utility` for a manual scan, `.background` for a scheduled one.
    public static func qos(for trigger: ScanTrigger) -> QualityOfService { trigger == .manual ? .utility : .background }
}

/// "Vulnerability DB at most once per 24 h, only when a scan is requested", decided from Trivy's own `metadata.json`.
public enum DBUpdatePolicy {
    public static let maximumAge: TimeInterval = 24 * 3_600
    public static let resultMaximumAge: TimeInterval = 7 * 86_400

    public static func needsDownload(metadata: TrivyDBMetadata?, now: Date = Date()) -> Bool {
        guard let downloaded = metadata?.downloadedAt else { return true }
        return now.timeIntervalSince(downloaded) >= maximumAge
    }

    /// A stored scan is reused while the DB version is unchanged and it is younger than 7 days. A mutable tag is never reused across
    /// a DB-less lookup because the tag may have moved: it reuses only within the same day.
    public static func canReuse(_ scan: ImageScanResult, dbVersion: String?, now: Date = Date()) -> Bool {
        guard let dbVersion, scan.dbVersion == dbVersion else { return false }
        let limit = scan.isMutable ? 86_400 : resultMaximumAge
        return now.timeIntervalSince(scan.scannedAt) < limit
    }
}

/// An image reference as scanned (`registry/repo[:tag][@digest]`). The grammar is checked before it reaches argv.
public struct ImageReference: Hashable, Sendable {
    public var registry: String
    public var repository: String
    public var tag: String?
    public var digest: String?

    public static let dockerHub = "docker.io"

    /// Parses a reference; nil when it is not a valid one (so nothing hostile, such as `-flag` or whitespace, reaches argv).
    public init?(_ raw: String) {
        var s = raw
        for prefix in ["docker-pullable://", "docker://"] where s.hasPrefix(prefix) { s.removeFirst(prefix.count) }
        guard !s.isEmpty, s.count <= 512, !s.hasPrefix("-"), !s.hasPrefix("sha256:"),
              s.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }),
              !s.contains("//"), !s.contains("..") else { return nil }
        var digest: String?
        if let at = s.firstIndex(of: "@") {
            let d = String(s[s.index(after: at)...])
            guard d.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
            digest = d
            s = String(s[..<at])
        }
        var tag: String?
        if let colon = s.lastIndex(of: ":"), !s[colon...].contains("/") {
            let t = String(s[s.index(after: colon)...])
            guard t.range(of: #"^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$"#, options: .regularExpression) != nil else { return nil }
            tag = t
            s = String(s[..<colon])
        }
        let parts = s.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: \.isEmpty) else { return nil }
        let first = parts[0]
        var registry = Self.dockerHub
        var path = parts
        if parts.count > 1, first.contains(".") || first.contains(":") || first == "localhost" {
            registry = first
            path = Array(parts.dropFirst())
        }
        if registry == "index.docker.io" || registry == "registry-1.docker.io" { registry = Self.dockerHub }
        if registry == Self.dockerHub, path.count == 1 { path.insert("library", at: 0) }
        let repository = path.joined(separator: "/")
        guard repository.range(of: #"^[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*(?:/[a-z0-9]+(?:(?:[._]|__|-+)[a-z0-9]+)*)*$"#, options: .regularExpression) != nil else { return nil }
        guard registry.range(of: #"^[A-Za-z0-9.-]+(?::\d{1,5})?$"#, options: .regularExpression) != nil else { return nil }
        self.registry = registry
        self.repository = repository
        self.tag = tag
        self.digest = digest
    }

    /// Scanned by tag (or with no tag at all, which means `latest`): the result can go stale.
    public var isMutable: Bool { digest == nil }

    /// What is passed to trivy: the digest form when there is one.
    public var scanTarget: String {
        let base = "\(registry)/\(repository)"
        if let digest { return "\(base)@\(digest)" }
        return "\(base):\(tag ?? "latest")"
    }

    /// A running container's reference: `imageID` (`docker-pullable://repo@sha256:…`) when it names a digest, else the tag form
    /// (mutable). A bare `sha256:` imageID is the image's config ID (side-loaded images, CRI-O), not a manifest digest a registry
    /// knows, so it is not used.
    public static func forContainer(image: String, imageID: String?) -> ImageReference? {
        if let imageID, let pinned = ImageReference(imageID), pinned.digest != nil { return pinned }
        return ImageReference(image)
    }
}

/// Builds the minimal `config.json` of a per-scan `DOCKER_CONFIG` directory: only the `auths` entry of the registry being scanned
/// (ARCHITECTURE-MAC §6.1 (c)). It never carries `credsStore` or `credHelpers`, and decodes nothing it does not need.
public enum DockerConfigBuilder {
    /// The pull-secret keys that name the same registry as `registry`.
    static func matches(key: String, registry: String) -> Bool {
        var host = key.lowercased()
        for prefix in ["https://", "http://"] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        host = String(host.split(separator: "/").first ?? "")
        let hub: Set = ["docker.io", "index.docker.io", "registry-1.docker.io"]
        if hub.contains(host), hub.contains(registry) { return true }
        return host == registry
    }

    /// `secretData` is the decoded `.dockerconfigjson` of a `kubernetes.io/dockerconfigjson` pull secret. Returns nil when no entry
    /// matches (a legacy `.dockercfg` is not supported).
    public static func minimalConfig(fromDockerConfigJSON secretData: Data, registry: String) -> Data? {
        guard let json = try? JSONValue.parse(secretData), let auths = json["auths"]?.objectValue else { return nil }
        var chosen: [String: JSONValue] = [:]
        for (key, entry) in auths.sorted(by: { $0.key < $1.key }) where matches(key: key, registry: registry) {
            guard let auth = authEntry(entry) else { continue }
            chosen = auth
            break
        }
        guard !chosen.isEmpty else { return nil }
        let key = [ImageReference.dockerHub, "index.docker.io", "registry-1.docker.io"].contains(registry) ? "https://index.docker.io/v1/" : registry
        let out: JSONValue = .object(["auths": .object([key: .object(chosen)])])
        return try? out.data(pretty: true)
    }

    /// Keeps only `auth`, `username`/`password` (folded into `auth`) or `identitytoken`.
    private static func authEntry(_ entry: JSONValue) -> [String: JSONValue]? {
        if let auth = entry["auth"]?.stringValue, !auth.isEmpty { return ["auth": .string(auth)] }
        if let user = entry["username"]?.stringValue, let password = entry["password"]?.stringValue, !user.isEmpty {
            return ["auth": .string(Data("\(user):\(password)".utf8).base64EncodedString())]
        }
        if let token = entry["identitytoken"]?.stringValue, !token.isEmpty { return ["identitytoken": .string(token)] }
        return nil
    }
}
