import SwiftUI
import WheelhouseKit

extension ClusterRegistry {
    /// Identity of "this cluster, as currently configured". Screens that capture a session, client or `ActionHost`
    /// use it as `.id(...)` so editing the cluster (read-only, environment, credentials, URL) rebuilds them instead of
    /// leaving them on a stale session. Reading `config(for:)` first registers the observation dependency.
    func screenKey(for id: ClusterID) -> String? {
        guard let config = config(for: id), let session = session(for: id) else { return nil }
        return "\(id)|\(config.modifiedAt.timeIntervalSince1970)|\(UInt(bitPattern: ObjectIdentifier(session).hashValue))"
    }
}

/// Shared by the Secret list and counts: a store that never retains Secret values.
@MainActor
final class SecretStoreCache {
    private var stores: [String: ResourceStore<Unstructured>] = [:]

    /// One stripped store per selected namespace (or the cluster-wide one for All).
    func group(session: ClusterSession, selection: NamespaceSelection, labelSelector: String?) -> NamespaceStoreGroup {
        let names = selection.names
        if names.isEmpty { return NamespaceStoreGroup(stores: [store(session: session, namespace: nil, labelSelector: labelSelector)]) }
        return NamespaceStoreGroup(stores: names.map { store(session: session, namespace: $0, labelSelector: labelSelector) })
    }

    func store(session: ClusterSession, namespace: String?, labelSelector: String?) -> ResourceStore<Unstructured> {
        let key = "\(namespace ?? "*")|\(labelSelector ?? "")"
        if let existing = stores[key] { return existing }
        let s = ResourceStore<Unstructured>(client: SecretStrippingClient(session.client), kind: .secret, namespace: namespace, labelSelector: labelSelector)
        stores[key] = s
        return s
    }
}
