import CryptoKit
import Foundation
import Synchronization

/// A place for one string secret per account. The Mac's real one is ``MacPrivateSecretStore`` (the Mac-private keychain group, this
/// device only, never synchronised); tests and performance replays use ``InMemoryAISecrets``. Nothing in this folder touches
/// the Keychain any other way.
public protocol AISecretStoring: Sendable {
    func read(account: String) throws -> String?
    func write(_ secret: String, account: String) throws
    func delete(account: String) throws
}

extension MacPrivateSecretStore: AISecretStoring {}

/// Secrets held in memory only.
public final class InMemoryAISecrets: AISecretStoring {
    private let items = Mutex<[String: String]>([:])
    public init() {}
    public func read(account: String) throws -> String? { items.withLock { $0[account] } }
    public func write(_ secret: String, account: String) throws { items.withLock { $0[account] = secret } }
    public func delete(account: String) throws { items.withLock { $0[account] = nil } }
}

/// The Anthropic API key. It is read only when a request is sent, never logged, and never shown again (the last four characters
/// identify it).
public struct AnthropicKeyStore: Sendable {
    public static let account = "api-key"
    private let secrets: any AISecretStoring

    public init(secrets: any AISecretStoring) { self.secrets = secrets }

    public func save(_ key: String) throws {
        try secrets.write(key.trimmingCharacters(in: .whitespacesAndNewlines), account: Self.account)
    }

    public func load() throws -> String? { try secrets.read(account: Self.account) }
    public func remove() throws { try secrets.delete(account: Self.account) }

    /// `••••1234`, or nil with no key.
    public func identification() -> String? {
        guard let key = try? load(), !key.isEmpty else { return nil }
        return "••••" + key.suffix(4)
    }
}

/// One request that left the Mac, for "What was sent" (ARCHITECTURE-MAC section 9.3).
///
/// The history is append-only, so a request is its stored prefix (system prompt and tools, kept once per hash), the first
/// `historyCount` messages of the conversation and the `tail` that was not yet part of it (the turn's own messages, which stay
/// here even when the turn was rolled back). The body is rebuilt from that and checked against `bodyHash`.
public struct SentRequest: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var at: Date
    public var model: String
    public var effort: String
    public var historyCount: Int
    public var tail: [AIMessage]
    public var prefixHash: String
    public var bodyHash: String
    public var bytes: Int
    public var toolsAllowed: Bool
}

public struct ConversationRecord: Codable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var profile: AIModelChoice
    public var messages: [AIMessage]
    public var sent: [SentRequest]
    public var prefixes: [String: JSONValue]
    public var spentDollars: Double
    public var capDollars: Double
    public var usage: AIUsage
    public var lastContext: String?

    public init(id: String, title: String = "New conversation", createdAt: Date = Date(), profile: AIModelChoice = .standard, capDollars: Double = CostCaps.defaultConversation) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.profile = profile
        self.messages = []
        self.sent = []
        self.prefixes = [:]
        self.spentDollars = 0
        self.capDollars = capDollars
        self.usage = AIUsage()
        self.lastContext = nil
    }

    /// The body of a recorded request, rebuilt. `matches` is false when this build no longer produces the recorded bytes (the
    /// system prompt, the tool list or the builder changed since); the viewer says so instead of showing something else as exact.
    public func reconstruct(_ request: SentRequest) -> (body: Data, matches: Bool)? {
        guard let prefix = prefixes[request.prefixHash], request.historyCount <= messages.count else { return nil }
        let effort = AIModelChoice.Effort(rawValue: request.effort) ?? .medium
        let built = AnthropicRequestBuilder.request(model: AIModelChoice(model: request.model, effort: effort),
                                                    messages: Array(messages.prefix(request.historyCount)) + request.tail,
                                                    prefix: prefix, toolsAllowed: request.toolsAllowed)
        return (built.data, built.sha256 == request.bodyHash)
    }
}

public struct ConversationSummary: Sendable, Identifiable, Equatable {
    public var id: String
    public var title: String
    public var updatedAt: Date
    public var spentDollars: Double
}

public enum ConversationRetention: Int, CaseIterable, Sendable {
    case days7 = 7, days30 = 30, days90 = 90, forever = 0
    public var label: String { self == .forever ? "Forever" : "\(rawValue) days" }
}

public enum ConversationStoreError: Error, Equatable, Sendable, LocalizedError {
    case keyUnavailable
    case badID
    case unreadable

    public var errorDescription: String? {
        switch self {
        case .keyUnavailable: "The conversation key could not be read from the Keychain, so no conversation was opened or saved."
        case .badID: "Bad conversation id."
        case .unreadable: "The conversation file could not be decrypted."
        }
    }
}

/// Encrypted conversations: `<directory>/<id>.whchat`, AES-GCM (CryptoKit) with a 256-bit key held through ``AISecretStoring``
/// (Mac-private keychain group, this device only). Never synced. The conversation id is authenticated data, so a file renamed to
/// another id does not open.
///
/// A new key is made only when the Keychain says there is none. If reading the key fails for any other reason the store fails
/// closed: a transient error must not replace the key and make every saved conversation unreadable.
public actor ConversationStore {
    public static let keyAccount = "conversation-key"
    public static let fileExtension = "whchat"

    private let directory: URL
    private let secrets: any AISecretStoring
    private var cachedKey: SymmetricKey?

    public init(directory: URL, secrets: any AISecretStoring) {
        self.directory = directory
        self.secrets = secrets
    }

    public func save(_ record: ConversationRecord) throws {
        let key = try symmetricKey()
        let plain = try JSONEncoder().encode(record)
        let sealed = try AES.GCM.seal(plain, using: key, authenticating: Data(record.id.utf8))
        guard let combined = sealed.combined else { throw ConversationStoreError.unreadable }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = try fileURL(record.id)
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func load(_ id: String) throws -> ConversationRecord {
        let key = try symmetricKey()
        let data = try Data(contentsOf: fileURL(id))
        do {
            let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(id.utf8))
            return try JSONDecoder().decode(ConversationRecord.self, from: opened)
        } catch { throw ConversationStoreError.unreadable }
    }

    /// Newest first. A file that cannot be opened is left alone and not listed.
    public func list() throws -> [ConversationSummary] {
        _ = try symmetricKey()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".\(Self.fileExtension)") }
            .compactMap { name -> ConversationSummary? in
                let id = String(name.dropLast(Self.fileExtension.count + 1))
                guard let record = try? load(id) else { return nil }
                return ConversationSummary(id: id, title: record.title, updatedAt: record.updatedAt, spentDollars: record.spentDollars)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    public func delete(_ id: String) throws { try? FileManager.default.removeItem(at: fileURL(id)) }

    /// Deletes every conversation and the key too, so what is left (a copied file) can never be read again.
    public func deleteAll() throws {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasSuffix(".\(Self.fileExtension)") { try? FileManager.default.removeItem(at: directory.appending(path: name)) }
        try secrets.delete(account: Self.keyAccount)
        cachedKey = nil
    }

    /// Removes conversations not touched for longer than `retention`. Returns how many went.
    @discardableResult
    public func purge(retention: ConversationRetention, now: Date = Date()) -> Int {
        guard retention != .forever else { return 0 }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var removed = 0
        for name in names where name.hasSuffix(".\(Self.fileExtension)") {
            let url = directory.appending(path: name)
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > Double(retention.rawValue) * 86_400 { try? FileManager.default.removeItem(at: url); removed += 1 }
        }
        return removed
    }

    private func fileURL(_ id: String) throws -> URL {
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { throw ConversationStoreError.badID }
        return directory.appending(path: "\(id).\(Self.fileExtension)")
    }

    private func symmetricKey() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        let key: SymmetricKey
        let stored: String?
        do { stored = try secrets.read(account: Self.keyAccount) } catch { throw ConversationStoreError.keyUnavailable }
        if let stored, let data = Data(base64Encoded: stored), data.count == 32 {
            key = SymmetricKey(data: data)
        } else if stored != nil {
            throw ConversationStoreError.keyUnavailable     // present but damaged: never overwrite it
        } else {
            key = SymmetricKey(size: .bits256)
            do { try secrets.write(key.withUnsafeBytes { Data($0) }.base64EncodedString(), account: Self.keyAccount) }
            catch { throw ConversationStoreError.keyUnavailable }
        }
        cachedKey = key
        return key
    }
}
