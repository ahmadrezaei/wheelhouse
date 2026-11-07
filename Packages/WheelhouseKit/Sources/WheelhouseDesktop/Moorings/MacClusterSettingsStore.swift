#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// An exec context adopted into the Keychain: the plugin stanza lives here (never on `ClusterConfig`, never synced) and the Keychain
/// item holds the CA only.
public struct ExecAdoption: Codable, Equatable, Sendable {
    public var spec: KubeconfigExecSpec
    public var specHash: String
    /// The kubeconfig the stanza came from (part of the credential cache key and the base of relative command paths).
    public var kubeconfigPath: String
    public init(spec: KubeconfigExecSpec, specHash: String, kubeconfigPath: String) {
        self.spec = spec
        self.specHash = specHash
        self.kubeconfigPath = kubeconfigPath
    }
}

/// Mac-only per-cluster safety settings, keyed by `ClusterID` for EVERY cluster including iCloud-synced ones. They never go on
/// `ClusterConfig` (ARCHITECTURE-MAC §1.4 rule 5). A missing entry or field always means the most restrictive behaviour.
///
/// Fields owned by later milestones (First Mate access, Beacon exposure, terminal mode, grants) are carried in `extra` verbatim, so
/// this store never drops what another milestone wrote.
public struct MacClusterSettings: Codable, Equatable, Sendable {
    public var execAdopted: ExecAdoption?
    public var extra: [String: JSONValue] = [:]

    public init(execAdopted: ExecAdoption? = nil) { self.execAdopted = execAdopted }

    private enum CodingKeys: String, CodingKey, CaseIterable { case execAdopted }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        execAdopted = try c.decodeIfPresent(ExecAdoption.self, forKey: .execAdopted)
        let all = try decoder.container(keyedBy: AnyKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        for key in all.allKeys where !known.contains(key.stringValue) { extra[key.stringValue] = try all.decode(JSONValue.self, forKey: key) }
    }

    public func encode(to encoder: Encoder) throws {
        var extraContainer = encoder.container(keyedBy: AnyKey.self)
        for (k, v) in extra { try extraContainer.encode(v, forKey: AnyKey(k)) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(execAdopted, forKey: .execAdopted)
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

/// `AppPaths.root/cluster-settings.json`. Settings of a cluster that iCloud removes are kept 30 days, then swept.
public final class MacClusterSettingsStore: Sendable {
    struct File: Codable {
        var version = 1
        var clusters: [ClusterID: MacClusterSettings] = [:]
        /// When a cluster was last seen missing, for the 30-day sweep.
        var orphanedAt: [ClusterID: Date] = [:]
    }
    private let fileURL: URL
    private let state: Mutex<File>

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(JSONFile.read(File.self, from: fileURL) ?? File())
    }

    public func settings(for id: ClusterID) -> MacClusterSettings? { state.withLock { $0.clusters[id] } }

    public func execAdoption(for id: ClusterID) -> ExecAdoption? { settings(for: id)?.execAdopted }

    public func update(_ id: ClusterID, _ change: (inout MacClusterSettings) -> Void) throws {
        let file = state.withLock { s -> File in
            var v = s.clusters[id] ?? MacClusterSettings()
            change(&v)
            s.clusters[id] = v
            s.orphanedAt[id] = nil
            return s
        }
        try JSONFile.write(file, to: fileURL)
    }

    /// Records which clusters exist now; entries of vanished clusters are swept after 30 days.
    public func reconcile(existing: Set<ClusterID>, now: Date = Date()) throws {
        let (file, changed) = state.withLock { s -> (File, Bool) in
            var changed = false
            for id in s.clusters.keys where !existing.contains(id) {
                if let at = s.orphanedAt[id] {
                    if now.timeIntervalSince(at) > 30 * 86_400 { s.clusters[id] = nil; s.orphanedAt[id] = nil; changed = true }
                } else { s.orphanedAt[id] = now; changed = true }
            }
            for id in existing where s.orphanedAt[id] != nil { s.orphanedAt[id] = nil; changed = true }
            return (s, changed)
        }
        if changed { try JSONFile.write(file, to: fileURL) }
    }
}
#endif
