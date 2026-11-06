import Foundation

/// One-slot handoff of a kubeconfig from the Share extension to the app. The content holds private keys and tokens, so it lives
/// in the shared keychain access group (device-only, never synchronizable), never as a file in the App Group container.
public struct PendingKubeconfigStore: Sendable {
    public struct Item: Codable, Equatable, Sendable {
        public var text: String
        public var name: String?
        public var savedAt: Date
        public init(text: String, name: String?, savedAt: Date) { self.text = text; self.name = name; self.savedAt = savedAt }
    }

    public static let service = "com.ahmadrezaei.wheelhouse.pending-kubeconfig"
    static let account = "pending"
    /// Items older than this are dropped without being offered.
    public static let maxAge: TimeInterval = 3600

    private let backend: any KeychainBackend
    private let now: @Sendable () -> Date

    public init() { self.init(backend: SystemKeychain(), now: { Date() }) }

    init(backend: any KeychainBackend, now: @escaping @Sendable () -> Date) {
        self.backend = backend
        self.now = now
    }

    /// Replaces any previous pending item.
    public func save(text: String, name: String?) throws {
        let data = try JSONEncoder().encode(Item(text: text, name: name, savedAt: now()))
        try KeychainAccess.write(data, service: Self.service, account: Self.account, synchronizable: false, in: backend)
    }

    /// Returns the pending item (if fresh) and deletes it. Expired or corrupt items are deleted silently.
    public func take() -> Item? {
        guard let data = try? KeychainAccess.read(service: Self.service, account: Self.account, in: backend) else { return nil }
        try? KeychainAccess.delete(service: Self.service, account: Self.account, in: backend)
        guard let item = try? JSONDecoder().decode(Item.self, from: data) else { return nil }
        let age = now().timeIntervalSince(item.savedAt)
        guard age < Self.maxAge else { return nil }
        return item
    }

    /// Deletes the pending item when it is older than ``maxAge`` (or unreadable) without returning it. The Share extension calls
    /// this on start so an unclaimed kubeconfig does not outlive its hour just because the app was never opened.
    public func purgeIfStale() {
        guard let data = try? KeychainAccess.read(service: Self.service, account: Self.account, in: backend) else { return }
        if let item = try? JSONDecoder().decode(Item.self, from: data), now().timeIntervalSince(item.savedAt) < Self.maxAge { return }
        try? KeychainAccess.delete(service: Self.service, account: Self.account, in: backend)
    }

    public func clear() { try? KeychainAccess.delete(service: Self.service, account: Self.account, in: backend) }
}
