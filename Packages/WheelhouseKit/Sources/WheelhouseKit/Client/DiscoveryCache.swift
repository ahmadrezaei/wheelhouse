import Foundation

/// Caches `DiscoveryInfo` per client with a TTL.
public actor DiscoveryCache {
    private var cached: DiscoveryInfo?
    private let ttl: TimeInterval
    public init(ttl: TimeInterval = 300) { self.ttl = ttl }

    public func info(using client: any KubeClientProtocol, forceRefresh: Bool = false) async throws -> DiscoveryInfo {
        if !forceRefresh, let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl { return cached }
        let fresh = try await client.discovery()
        cached = fresh
        return fresh
    }

    public func invalidate() { cached = nil }
}
