import Testing
import Foundation
import Synchronization
@testable import WheelhouseKit

/// A secret store whose reads can be made to fail.
private final class FlakySecrets: AISecretStoring {
    private let items = Mutex<[String: String]>([:])
    let failReads = Mutex(false)
    let writes = Mutex(0)
    func read(account: String) throws -> String? {
        if failReads.withLock({ $0 }) { throw KeychainError.status(-25308) }
        return items.withLock { $0[account] }
    }
    func write(_ secret: String, account: String) throws { writes.withLock { $0 += 1 }; items.withLock { $0[account] = secret } }
    func delete(account: String) throws { items.withLock { $0[account] = nil } }
}

@Suite("Prices, caps and the daily total")
struct CostTests {
    @Test func theBundledPricesMatchTheDesign() {
        let opus = PriceTable.price(for: "claude-opus-5-5")
        #expect(opus.input == 4 && opus.output == 20 && opus.cacheRead == 0.20 && opus.cacheWrite == 5)
        #expect(PriceTable.price(for: "claude-sonnet-5-5").input == 2)
        let usage = AIUsage(inputTokens: 1_000_000, outputTokens: 1_000_000, cacheCreationTokens: 1_000_000, cacheReadTokens: 1_000_000)
        #expect(abs(opus.cost(of: usage) - (4 + 20 + 5 + 0.2)) < 1e-9)
    }

    @Test func anUnknownModelIsNeverFree() {
        #expect(PriceTable.price(for: "claude-future-9").input >= PriceTable.prices.values.map(\.input).max()!)
        #expect(PriceTable.price(for: nil) == PriceTable.unknown)
        #expect(PriceTable.cost(of: [AIUsage(inputTokens: 1_000_000)], defaultModel: "claude-sonnet-5-5") == 2)
    }

    @Test func capsAreClampedToTheirRange() {
        #expect(CostCaps().conversation == 2 && CostCaps().daily == 10)
        #expect(CostCaps(conversation: 0.01).conversation == 0.25)
        #expect(CostCaps(conversation: 900).conversation == 50)
    }

    @Test func theGateStopsAtEitherCapOnceTheNextRequestIsCounted() {
        #expect(CostGate.check(conversationSpent: 0.5, conversationCap: 2, dailySpent: 1, dailyCap: 10) == .open)
        #expect(CostGate.check(conversationSpent: 2, conversationCap: 2, dailySpent: 1, dailyCap: 10) == .conversationCapReached(spent: 2, cap: 2))
        #expect(CostGate.check(conversationSpent: 1, conversationCap: 2, dailySpent: 10, dailyCap: 10) == .dailyCapReached(spent: 10, cap: 10))
        #expect(CostGate.check(conversationSpent: 1.95, conversationCap: 2, dailySpent: 1, dailyCap: 10, nextInputEstimate: 0.1) == .conversationCapReached(spent: 1.95, cap: 2))
    }

    @Test func theDailyTotalPersistsAndRollsOverAtMidnight() throws {
        let url = tempDirectory().appending(path: "spend.json")
        let clock = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
        let store = DailySpendStore(url: url, now: { clock.withLock { $0 } })
        store.add(1.5)
        store.add(0.5)
        #expect(store.today == 2)
        #expect(DailySpendStore(url: url, now: { clock.withLock { $0 } }).today == 2)
        clock.withLock { $0.addTimeInterval(2 * 86_400) }
        #expect(store.today == 0)
        #expect(DailySpendStore(url: url, now: { clock.withLock { $0 } }).today == 0)
    }
}

@Suite("Conversation store")
struct ConversationStoreTests {
    private func record(_ id: String = "abc-1") -> ConversationRecord {
        var r = ConversationRecord(id: id, title: "Why is checkout pending")
        r.messages = [.user("secret question about checkout"), AIMessage(role: .assistant, content: [["type": "thinking", "thinking": "t", "signature": "sig", "future_field": 1.5], AIMessage.textBlock("answer")])]
        return r
    }

    @Test func conversationsRoundTripLosslesslyAndAreEncryptedOnDisk() async throws {
        let dir = tempDirectory()
        let store = ConversationStore(directory: dir, secrets: InMemoryAISecrets())
        let original = record()
        try await store.save(original)
        let loaded = try await store.load("abc-1")
        #expect(loaded.messages == original.messages)       // a thinking block with an unknown field survives untouched
        let raw = try Data(contentsOf: dir.appending(path: "abc-1.whchat"))
        #expect(raw.range(of: Data("secret question".utf8)) == nil)
        #expect(raw.range(of: Data("checkout".utf8)) == nil)
        let mode = (try FileManager.default.attributesOfItem(atPath: dir.appending(path: "abc-1.whchat").path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    @Test func theConversationIdIsAuthenticated() async throws {
        let dir = tempDirectory()
        let store = ConversationStore(directory: dir, secrets: InMemoryAISecrets())
        try await store.save(record())
        try FileManager.default.copyItem(at: dir.appending(path: "abc-1.whchat"), to: dir.appending(path: "other.whchat"))
        await #expect(throws: ConversationStoreError.unreadable) { try await store.load("other") }
        await #expect(throws: ConversationStoreError.badID) { try await store.load("../x") }
    }

    @Test func aKeyReadErrorFailsClosedAndNeverReplacesTheKey() async throws {
        let secrets = FlakySecrets()
        let dir = tempDirectory()
        let store = ConversationStore(directory: dir, secrets: secrets)
        try await store.save(record())
        #expect(secrets.writes.withLock { $0 } == 1)
        let fresh = ConversationStore(directory: dir, secrets: secrets)       // a new process: no cached key
        secrets.failReads.withLock { $0 = true }
        await #expect(throws: ConversationStoreError.keyUnavailable) { try await fresh.load("abc-1") }
        await #expect(throws: ConversationStoreError.keyUnavailable) { try await fresh.save(record("zzz")) }
        #expect(secrets.writes.withLock { $0 } == 1)        // no rotation
        secrets.failReads.withLock { $0 = false }
        #expect(try await fresh.load("abc-1").title == "Why is checkout pending")
    }

    @Test func aDamagedKeyIsNeverOverwritten() async throws {
        let secrets = InMemoryAISecrets()
        try secrets.write("not-base64-key", account: ConversationStore.keyAccount)
        let store = ConversationStore(directory: tempDirectory(), secrets: secrets)
        await #expect(throws: ConversationStoreError.keyUnavailable) { try await store.save(record()) }
        #expect(try secrets.read(account: ConversationStore.keyAccount) == "not-base64-key")
    }

    @Test func listingDeleteDeleteAllAndRetention() async throws {
        let dir = tempDirectory()
        let secrets = InMemoryAISecrets()
        let store = ConversationStore(directory: dir, secrets: secrets)
        var older = record("old-1"); older.updatedAt = Date(timeIntervalSince1970: 1_000)
        try await store.save(older)
        try await store.save(record("new-1"))
        #expect(try await store.list().map(\.id) == ["new-1", "old-1"])
        // Retention counts from the file's modification time.
        let old = dir.appending(path: "old-1.whchat")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-40 * 86_400)], ofItemAtPath: old.path)
        #expect(await store.purge(retention: .forever) == 0)
        #expect(await store.purge(retention: .days90) == 0)
        #expect(await store.purge(retention: .days30) == 1)
        #expect(try await store.list().map(\.id) == ["new-1"])
        try await store.delete("new-1")
        #expect(try await store.list().isEmpty)
        try await store.save(record("again-1"))
        try await store.deleteAll()
        #expect(try secrets.read(account: ConversationStore.keyAccount) == nil)     // the key goes too
        #expect(try await store.list().isEmpty)
        #expect(ConversationRetention.allCases.map(\.label) == ["7 days", "30 days", "90 days", "Forever"])
    }

    @Test func theApiKeyIsIdentifiedByItsLastFourCharactersOnly() throws {
        let keys = AnthropicKeyStore(secrets: InMemoryAISecrets())
        #expect(keys.identification() == nil)
        try keys.save("  \(testKey)\n")
        #expect(try keys.load() == testKey)
        #expect(keys.identification() == "••••" + testKey.suffix(4))
        try keys.remove()
        #expect(try keys.load() == nil)
    }

    @Test func aSentRequestIsRebuiltExactlyAndAChangedBuilderIsReported() throws {
        let tools = ToolCatalog.definitions(for: .firstMate(conversation: "c"), includeProposals: true)
        var r = ConversationRecord(id: "rec-1")
        r.messages = [.user("one"), .assistant("two")]
        let tail: [AIMessage] = [.user("three"), .system("note")]
        let built = AnthropicRequestBuilder.request(model: .standard, messages: r.messages + tail, tools: tools)
        let hash = AnthropicRequestBuilder.prefixHash(tools: tools)
        r.prefixes[hash] = AnthropicRequestBuilder.prefix(tools: tools)
        let sent = SentRequest(id: 1, at: Date(), model: "claude-opus-5-5", effort: "medium", historyCount: 2, tail: tail, prefixHash: hash, bodyHash: built.sha256, bytes: built.data.count, toolsAllowed: true)
        let rebuilt = try #require(r.reconstruct(sent))
        #expect(rebuilt.matches)
        #expect(rebuilt.body == built.data)
        var changed = sent
        changed.bodyHash = "0000"
        #expect(try #require(r.reconstruct(changed)).matches == false)     // an app update changed the bytes: say so
        r.prefixes[hash] = nil
        #expect(r.reconstruct(sent) == nil)
    }
}

@Suite("Tool input validation")
struct ToolInputValidatorTests {
    private let schema = ToolCatalog.definition(.getLogs).inputSchema

    @Test func validInputPasses() {
        #expect(ToolInputValidator.problem(for: ["cluster": "dev", "namespace": "apps", "pod": "web-1", "tail_lines": 100, "previous": true], schema: schema) == nil)
    }

    @Test func missingRequiredUnknownWrongTypeAndOutOfRangeAreRefused() {
        #expect(ToolInputValidator.problem(for: ["cluster": "dev"], schema: schema) != nil)
        #expect(ToolInputValidator.problem(for: ["cluster": "dev", "namespace": "a", "pod": "p", "extra": 1], schema: schema) != nil)
        #expect(ToolInputValidator.problem(for: ["cluster": "dev", "namespace": "a", "pod": 5], schema: schema) != nil)
        #expect(ToolInputValidator.problem(for: ["cluster": "dev", "namespace": "a", "pod": "p", "tail_lines": 99_999], schema: schema) != nil)
        let events = ToolCatalog.definition(.getEvents).inputSchema
        #expect(ToolInputValidator.problem(for: ["cluster": "dev", "type": "Bogus"], schema: events) != nil)
    }

    @Test func aNullIsNotAValueAndTheRootMustBeAnObject() {
        #expect(ToolInputValidator.problem(for: ["cluster": .null], schema: ToolCatalog.definition(.getEvents).inputSchema)?.contains("cluster") == true)
        #expect(ToolInputValidator.problem(for: ["a": ["b": [.null]]], schema: schema)?.contains("a.b[0]") == true)
        #expect(ToolInputValidator.problem(for: "text", schema: schema) != nil)
        #expect(ToolInputValidator.problem(for: [], schema: schema) != nil)
    }

    @Test func theEmptyInputOfAToolWithNoArgumentsIsValid() {
        #expect(ToolInputValidator.problem(for: [:], schema: ToolCatalog.definition(.listClusters).inputSchema) == nil)
        #expect(ToolInputValidator.problem(for: ["x": 1], schema: ToolCatalog.definition(.listClusters).inputSchema) != nil)
    }

    @Test func everyCatalogToolAcceptsItsOwnSampleInput() {
        for tool in ReadTool.allCases {
            let schema = ToolCatalog.definition(tool).inputSchema
            #expect(ToolInputValidator.problem(for: sampleInput(tool, cluster: "dev"), schema: schema) == nil, "\(tool)")
        }
        for tool in ProposalTool.allCases {
            let schema = ToolCatalog.definition(tool).inputSchema
            #expect(ToolInputValidator.problem(for: sampleProposalInput(tool, cluster: "dev"), schema: schema) == nil, "\(tool)")
        }
    }

    @Test func theUpdateGateAllowsFourPublishesPerSecond() {
        var gate = UpdateGate()
        let start = Date(timeIntervalSince1970: 1_000)
        var published = 0
        for tick in 0..<1_000 where gate.shouldPublish(at: start.addingTimeInterval(Double(tick) * 0.01)) { published += 1 }     // 10 s of 100 chunks/s
        #expect(published <= 41 && published >= 39)
        gate.reset()
        let again = gate.shouldPublish(at: start)
        #expect(again)
    }
}
