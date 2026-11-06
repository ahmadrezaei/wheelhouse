import Foundation
import Testing
@testable import WheelhouseKit

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ d: Date) { date = d }
    var now: Date { lock.withLock { date } }
    func advance(_ s: TimeInterval) { lock.withLock { date = date.addingTimeInterval(s) } }
}

@Suite struct ShareExtensionTests {
    // MARK: Attachment decoding

    @Test func decodesUTF8AndStripsBOM() throws {
        #expect(try SharedAttachment.decode(Data("apiVersion: v1\n".utf8)) == "apiVersion: v1\n")
        #expect(try SharedAttachment.decode(Data([0xEF, 0xBB, 0xBF] + Array("a: 1".utf8))) == "a: 1")
        #expect(try SharedAttachment.decode(text: "clusters: []") == "clusters: []")
    }

    @Test func rejectsBadInput() {
        #expect(throws: SharedAttachment.Failure.empty) { try SharedAttachment.decode(Data()) }
        #expect(throws: SharedAttachment.Failure.empty) { try SharedAttachment.decode(text: "  \n ") }
        #expect(throws: SharedAttachment.Failure.notUTF8) { try SharedAttachment.decode(Data([0xFF, 0xFE, 0x00, 0xD8])) }
    }

    @Test func sizeCap() throws {
        let max = SharedAttachment.maxBytes
        #expect(max == 1_048_576)
        #expect(throws: SharedAttachment.Failure.tooLarge) { try SharedAttachment.decode(Data(repeating: 0x61, count: max + 1)) }
        #expect(try SharedAttachment.decode(Data(repeating: 0x61, count: max)).utf8.count == max)
        #expect(throws: SharedAttachment.Failure.tooLarge) { try SharedAttachment.decode(text: String(repeating: "a", count: 11), maxBytes: 10) }
    }

    @Test func readsFileAndChecksSizeFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let small = dir.appendingPathComponent("config")
        try Data("kind: Config\n".utf8).write(to: small)
        #expect(try SharedAttachment.read(fileURL: small) == "kind: Config\n")
        #expect(throws: SharedAttachment.Failure.tooLarge) { try SharedAttachment.read(fileURL: small, maxBytes: 4) }
        #expect(throws: SharedAttachment.Failure.unreadable) { try SharedAttachment.read(fileURL: dir.appendingPathComponent("missing")) }
    }

    // MARK: Pending store

    private func store(_ kc: InMemoryKeychain, _ clock: Clock) -> PendingKubeconfigStore {
        PendingKubeconfigStore(backend: kc, now: { clock.now })
    }

    @Test func roundTripDeletesOnRead() throws {
        let kc = InMemoryKeychain()
        let s = store(kc, Clock(Date(timeIntervalSince1970: 1_000_000)))
        try s.save(text: "secret: yes", name: "config.yaml")
        let item = try #require(s.take())
        #expect(item.text == "secret: yes")
        #expect(item.name == "config.yaml")
        #expect(s.take() == nil)
        #expect(kc.variants(service: PendingKubeconfigStore.service, account: PendingKubeconfigStore.account).local == nil)
    }

    @Test func storedDeviceOnlyNotSynchronizable() throws {
        let kc = InMemoryKeychain()
        try store(kc, Clock(.now)).save(text: "x: 1", name: nil)
        let v = kc.variants(service: PendingKubeconfigStore.service, account: PendingKubeconfigStore.account)
        #expect(v.local != nil)
        #expect(v.synced == nil)
    }

    @Test func expiryAtOneHour() throws {
        let kc = InMemoryKeychain()
        let clock = Clock(Date(timeIntervalSince1970: 2_000_000))
        let s = store(kc, clock)
        try s.save(text: "a: 1", name: "a")
        clock.advance(3599)
        #expect(s.take()?.text == "a: 1")
        try s.save(text: "b: 1", name: "b")
        clock.advance(3600)
        #expect(s.take() == nil)
        // Expired item was deleted silently.
        #expect(kc.variants(service: PendingKubeconfigStore.service, account: PendingKubeconfigStore.account).local == nil)
    }

    @Test func newSaveReplacesOldAndCorruptIsDropped() throws {
        let kc = InMemoryKeychain()
        let s = store(kc, Clock(.now))
        try s.save(text: "one: 1", name: "1")
        try s.save(text: "two: 2", name: "2")
        #expect(s.take()?.name == "2")
        try kc.upsert(Data("not json".utf8), service: PendingKubeconfigStore.service, account: PendingKubeconfigStore.account, synchronizable: false)
        #expect(s.take() == nil)
        #expect(kc.variants(service: PendingKubeconfigStore.service, account: PendingKubeconfigStore.account).local == nil)
    }

    // MARK: Inbox and deep link

    @MainActor @Test func inboxRevisionBumpsEvenForSameText() {
        let inbox = KubeconfigInbox()
        inbox.offer(text: "a: 1", name: "f")
        let r1 = inbox.revision
        inbox.offer(text: "a: 1", name: "f")
        #expect(inbox.revision == r1 + 1)
        #expect(inbox.take()?.name == "f")
        #expect(inbox.take() == nil)
    }

    @Test func importDeepLink() throws {
        #expect(DeepLink.isImport(try #require(URL(string: "wheelhouse://import"))))
        #expect(DeepLink.isImport(DeepLink.importURL))
        #expect(DeepLink.isImport(try #require(URL(string: "wheelhouse://import/"))))
        #expect(!DeepLink.isImport(try #require(URL(string: "wheelhouse://import/extra"))))
        #expect(!DeepLink.isImport(try #require(URL(string: "wheelhouse://cluster/abc"))))
        #expect(!DeepLink.isImport(try #require(URL(string: "https://import"))))
        // The cluster parser must not claim it.
        #expect(DeepLink(url: DeepLink.importURL) == nil)
    }
}
