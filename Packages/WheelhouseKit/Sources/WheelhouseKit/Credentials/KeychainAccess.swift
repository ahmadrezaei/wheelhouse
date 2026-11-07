import Foundation
import Security

public enum KeychainError: Error, Equatable, Sendable, LocalizedError {
    case status(OSStatus)
    case encoding
    /// A stored item exists but this build cannot decode it (typically written by a newer app). It is left untouched.
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .status(let s): "The Keychain returned an error (\(s))."
        case .encoding: "The credentials could not be encoded."
        case .unreadable: "These credentials were saved by a newer version of Wheelhouse. Update the app to change them."
        }
    }
}

/// Shared low-level keychain helpers.
enum KeychainAccess {
    /// `<TeamPrefix>.com.ahmadrezaei.wheelhouse.shared`, discovered at runtime from the app's default access group so the same
    /// code works with any development team. nil when unsigned (unit tests, some simulator builds); items then use the default group.
    static let defaultGroupSuffix = "com.ahmadrezaei.wheelhouse.shared"

    /// Suffix of the shared access group. Optional Info.plist key `WHKeychainGroupSuffix` overrides it (a target that needs a
    /// different group sets it); the iOS app, widget and share extension do not, so they keep ``defaultGroupSuffix``.
    static func groupSuffix(in bundle: Bundle = .main) -> String {
        if bundle === Bundle.main, let o = IsolationOverride.current { return o.sharedKeychainSuffix }
        guard let custom = bundle.object(forInfoDictionaryKey: "WHKeychainGroupSuffix") as? String else { return defaultGroupSuffix }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultGroupSuffix : trimmed
    }

    static func accessGroup(prefix: String, suffix: String) -> String { "\(prefix).\(suffix)" }

    /// The development team prefix, discovered from the app's default access group (see ``sharedGroup``). nil when unsigned.
    static let teamPrefix: String? = {
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
        return String(group[..<dot])
    }()

    static let sharedGroup: String? = teamPrefix.map { accessGroup(prefix: $0, suffix: groupSuffix()) }

    /// `accessGroup` defaults to ``sharedGroup`` (today's behaviour); nil leaves the item in the app's default group.
    static func baseQuery(service: String, account: String, accessGroup: String? = KeychainAccess.sharedGroup) -> [CFString: Any] {
        var q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecUseDataProtectionKeychain: true,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup] = g }
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

    /// Every stored variant of the item (see ``KeychainBackend/readAll(service:account:)``).
    static func readAll(service: String, account: String, in backend: any KeychainBackend = SystemKeychain()) throws -> [Data] {
        try backend.readAll(service: service, account: account)
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
    /// Every stored variant (device-only and synchronizable are queried separately); empty when there is no item.
    func readAll(service: String, account: String) throws -> [Data]
    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws
    /// `synchronizable == nil` deletes both variants.
    func delete(service: String, account: String, synchronizable: Bool?) throws
}

struct SystemKeychain: KeychainBackend {
    var accessGroup: String? = KeychainAccess.sharedGroup

    func read(service: String, account: String) throws -> Data? {
        for variant in [false, true] {
            var q = KeychainAccess.baseQuery(service: service, account: account, accessGroup: accessGroup)
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

    func readAll(service: String, account: String) throws -> [Data] {
        var out: [Data] = []
        for variant in [false, true] {
            var q = KeychainAccess.baseQuery(service: service, account: account, accessGroup: accessGroup)
            q[kSecAttrSynchronizable] = variant
            q[kSecReturnData] = true
            q[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(q as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw KeychainError.status(status) }
            if let data = result as? Data { out.append(data) }
        }
        return out
    }

    func upsert(_ data: Data, service: String, account: String, synchronizable: Bool) throws {
        var q = KeychainAccess.baseQuery(service: service, account: account, accessGroup: accessGroup)
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
        var q = KeychainAccess.baseQuery(service: service, account: account, accessGroup: accessGroup)
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
    func readAll(service: String, account: String) throws -> [Data] {
        lock.withLock { [false, true].compactMap { items[Key(service: service, account: account, synchronizable: $0)] } }
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
