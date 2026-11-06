import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable {
    case status(OSStatus)
    case encoding
}

/// Shared low-level keychain helpers.
enum KeychainAccess {
    /// `<TeamPrefix>.app.wheelhouse.shared`, discovered at runtime from the app's default access group so the same
    /// code works with any development team. nil when unsigned (unit tests, some simulator builds); items then use the default group.
    static let sharedGroup: String? = {
        let probe: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: "app.wheelhouse.probe", kSecAttrAccount: "probe",
            kSecReturnAttributes: true, kSecUseDataProtectionKeychain: true,
        ]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            var add = probe
            add.removeValue(forKey: kSecReturnAttributes)
            add[kSecValueData] = Data([0])
            status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecSuccess || status == errSecDuplicateItem {
                status = SecItemCopyMatching(probe as CFDictionary, &result)
            }
        }
        guard status == errSecSuccess, let attrs = result as? [String: Any], let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dot = group.firstIndex(of: ".") else { return nil }
        let prefix = group[..<dot]
        return "\(prefix).app.wheelhouse.shared"
    }()

    static func baseQuery(service: String, account: String) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        if let g = sharedGroup { q[kSecAttrAccessGroup] = g }
        return q
    }

    static func read(service: String, account: String, in backend: any KeychainBackend = SystemKeychain()) throws -> Data? {
        try backend.read(service: service, account: account)
    }

    /// Stores `data` as the synchronizable or the device-only variant of the item. The new variant is written FIRST and only
    /// then is the opposite variant removed, so a failed write never loses the credentials, and toggling iCloud sync never
    /// touches anything but the other variant.
    static func write(_ data: Data, service: String, account: String, synchronizable: Bool, in backend: any KeychainBackend = SystemKeychain()) throws {
        try backend.upsert(data, service: service, account: account, synchronizable: synchronizable)
        try backend.delete(service: service, account: account, synchronizable: !synchronizable)
    }

    /// Removes both variants.
    static func delete(service: String, account: String, in backend: any KeychainBackend = SystemKeychain()) throws {
        try backend.delete(service: service, account: account, synchronizable: nil)
    }
}

/// Primitive keychain operations behind ``KeychainAccess``; swapped for an in-memory fake in tests.
protocol KeychainBackend: Sendable {
    /// Either variant (device-only preferred).
    func read(service: String, account: String) throws -> Data?
    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws
    /// `synchronizable == nil` deletes both variants.
    func delete(service: String, account: String, synchronizable: Bool?) throws
}

struct SystemKeychain: KeychainBackend {
    func read(service: String, account: String) throws -> Data? {
        for variant in [false, true] {
            var q = KeychainAccess.baseQuery(service: service, account: account)
            q[kSecAttrSynchronizable] = variant
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            if let data = result as? Data { return data }
        }
        return nil
    }

    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        var q = KeychainAccess.baseQuery(service: service, account: account)
        q[kSecAttrSynchronizable] = synchronizable
        // Synchronizable items cannot be ThisDeviceOnly. AfterFirstUnlock is required for background refresh.
        let accessible = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        var add = q
        add[kSecValueData] = data
        add[kSecAttrAccessible] = accessible
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(q as CFDictionary, [kSecValueData: data, kSecAttrAccessible: accessible] as CFDictionary)
        }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(service: String, account: String, synchronizable: Bool?) throws {
        var q = KeychainAccess.baseQuery(service: service, account: account)
        q[kSecAttrSynchronizable] = synchronizable ?? kSecAttrSynchronizableAny
        let status = SecItemDelete(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

/// In-memory keychain for tests and previews. Models the two variants of an item as separate entries, like the real keychain.
final class InMemoryKeychain: KeychainBackend, @unchecked Sendable {
    private struct Key: Hashable { var service: String; var account: String; var synchronizable: Bool }
    private let lock = NSLock()
    private var items: [Key: Data] = [:]
    /// When set, `upsert` throws (to prove a failed add never loses the existing item).
    var failUpserts = false

    func read(service: String, account: String) throws -> Data? {
        lock.withLock { items[Key(service: service, account: account, synchronizable: false)] ?? items[Key(service: service, account: account, synchronizable: true)] }
    }
    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        try lock.withLock {
            if failUpserts { throw KeychainError.status(errSecInteractionNotAllowed) }
            items[Key(service: service, account: account, synchronizable: synchronizable)] = data
        }
    }
    func delete(service: String, account: String, synchronizable: Bool?) throws {
        lock.withLock {
            for variant in [false, true] where synchronizable == nil || synchronizable == variant {
                items[Key(service: service, account: account, synchronizable: variant)] = nil
            }
        }
    }
    func variants(service: String, account: String) -> (local: Data?, synced: Data?) {
        lock.withLock { (items[Key(service: service, account: account, synchronizable: false)], items[Key(service: service, account: account, synchronizable: true)]) }
    }
}
