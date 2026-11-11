import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// App-global First Mate state (ARCHITECTURE-MAC section 9): the key, the conversation store, today's spend, the one proposal
/// coordinator and the conversations that are open. Built lazily, on the first use of First Mate; nothing here runs at launch.
///
/// A panel (the inspector's First Mate segment, or a full pane) names a *slot*, the `ConversationID` of its destination (`"inspector"`,
/// `"triage"`, or the id of a saved conversation). The hub maps each slot to a conversation, so grants and proposals are
/// keyed by conversation and a slot can be pointed at another conversation or a new one.
@MainActor @Observable
final class FirstMateHub {
    let preferences: FirstMatePreferences
    let keys: AnthropicKeyStore
    let store: ConversationStore
    let daily: DailySpendStore
    let coordinator = ProposalCoordinator()
    let settings: FirstMateClusterSettings
    /// Whether an API key is stored (the setup card shows when not). Refreshed when the key changes.
    private(set) var hasKey: Bool
    private(set) var keyIdentification: String?
    private(set) var recent: [ConversationSummary] = []
    /// Bumped when a slot is pointed at another conversation, so panels showing it rebuild.
    private(set) var slotRevision = 0

    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let activity: any ActivityLogging
    @ObservationIgnored private let clientFactory: @MainActor (AnthropicKeyStore) -> any AIMessaging
    @ObservationIgnored private var sessions: [String: FirstMateSession] = [:]
    @ObservationIgnored private var slots: [String: String] = [:]

    init(registry: ClusterRegistry, settingsStore: MacClusterSettingsStore, preferences: FirstMatePreferences, keySecrets: any AISecretStoring,
         conversationSecrets: any AISecretStoring, directory: URL, dailyFile: URL?, activity: any ActivityLogging,
         clientFactory: @escaping @MainActor (AnthropicKeyStore) -> any AIMessaging = FirstMateHub.liveClient) {
        self.registry = registry
        self.preferences = preferences
        self.keys = AnthropicKeyStore(secrets: keySecrets)
        self.store = ConversationStore(directory: directory, secrets: conversationSecrets)
        self.daily = DailySpendStore(url: dailyFile)
        self.settings = FirstMateClusterSettings(store: settingsStore)
        self.activity = activity
        self.clientFactory = clientFactory
        self.hasKey = (try? keys.load())?.isEmpty == false
        self.keyIdentification = keys.identification()
    }

    /// The real client: the key is read from the Keychain only when a request is sent.
    static func liveClient(_ keys: AnthropicKeyStore) -> any AIMessaging {
        AnthropicClient(keyProvider: { try keys.load() })
    }

    /// The Mac's real stores: Mac-private keychain items (the Debug group while the safety gate is active) and the app-support folder.
    static func live(registry: ClusterRegistry, settingsStore: MacClusterSettingsStore, paths: AppPaths, activity: any ActivityLogging) -> FirstMateHub {
        FirstMateHub(registry: registry, settingsStore: settingsStore, preferences: FirstMatePreferences(),
                     keySecrets: MacPrivateSecretStore(.anthropicKey), conversationSecrets: MacPrivateSecretStore(.firstMateConversationKey),
                     directory: paths.root.appending(path: "FirstMate", directoryHint: .isDirectory),
                     dailyFile: paths.root.appending(path: "FirstMate-spend.json"), activity: activity)
    }

    /// Removes conversations past the retention setting. Cheap: it lists one folder.
    func start() {
        let retention = preferences.retention
        let store = store
        Task(priority: .utility) { await store.purge(retention: retention) }
    }

    // MARK: Key

    func saveKey(_ key: String) throws {
        try keys.save(key)
        refreshKey()
    }

    func removeKey() throws {
        try keys.remove()
        refreshKey()
    }

    func refreshKey() {
        hasKey = (try? keys.load())?.isEmpty == false
        keyIdentification = keys.identification()
    }

    /// Asks the Models API (and so validates the key) with a candidate key that is not stored yet.
    func validate(candidate: String) async throws -> [AIModelInfo] {
        let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await AnthropicClient(keyProvider: { candidate }).models()
    }

    // MARK: Conversations

    /// The conversation shown in `slot`, created on first use (or opened from disk when the slot names a saved conversation).
    func session(for slot: String) -> FirstMateSession {
        if let id = slots[slot], let session = sessions[id] { return session }
        let session = makeSession(id: UUID().uuidString, record: nil)
        slots[slot] = session.id
        return session
    }

    /// Starts a fresh conversation in `slot` (⌥⌘J). The old one stays in the list, saved.
    @discardableResult
    func newConversation(in slot: String) -> FirstMateSession {
        let session = makeSession(id: UUID().uuidString, record: nil)
        slots[slot] = session.id
        slotRevision += 1
        return session
    }

    /// Opens a saved conversation in `slot`.
    func open(_ id: String, in slot: String) async {
        if let existing = sessions[id] { slots[slot] = existing.id; slotRevision += 1; return }
        guard let record = try? await store.load(id) else { return }
        let session = makeSession(id: id, record: record)
        slots[slot] = session.id
        slotRevision += 1
    }

    func refreshList() async {
        recent = (try? await store.list()) ?? []
    }

    func delete(_ id: String) async {
        // Stop the conversation and let a queued save land first, so the file cannot be written again after it is deleted.
        if let session = sessions[id] { session.detach(); await session.flushStorage() }
        sessions[id] = nil
        slots = slots.filter { $0.value != id }
        slotRevision += 1
        try? await store.delete(id)
        await refreshList()
    }

    func deleteAll() async {
        let open = Array(sessions.values)
        for session in open { session.detach() }
        for session in open { await session.flushStorage() }
        sessions = [:]
        slots = [:]
        slotRevision += 1
        try? await store.deleteAll()
        recent = []
    }

    private func makeSession(id: String, record: ConversationRecord?) -> FirstMateSession {
        let grants = ConversationGrants(conversation: id)
        let policy = ToolboxPolicy(caller: .firstMate(conversation: id), settings: settings, grants: grants)
        let source = RegistryToolboxSource(registry: registry)
        let redactor = preferences.redactor
        let runner = ToolboxRunner(toolbox: ClusterToolbox(source: source, policy: policy, redactor: redactor),
                                   proposals: ProposalTools(source: source, policy: policy, coordinator: coordinator))
        let session = FirstMateSession(id: id, record: record, client: clientFactory(keys), tools: runner, coordinator: coordinator, grants: grants,
                                       store: store, daily: daily, redactor: redactor, profile: preferences.defaultProfile,
                                       capDollars: preferences.conversationCap)
        session.dailyCap = preferences.dailyCap
        sessions[id] = session
        return session
    }

    /// The daily cap changed in Settings: open conversations follow.
    func applyDailyCap() { sessions.values.forEach { $0.dailyCap = preferences.dailyCap } }

    // MARK: Activity

    /// A proposal the person declined is recorded like an applied one (the confirmation sheet records the applied ones).
    func recordDecline(_ change: ProposedChange) {
        activity.record(ActivityEntry(cluster: change.cluster, origin: change.origin, verb: "decline proposal", object: change.id, result: "declined"))
    }

    // MARK: Replay (development builds only)

    /// A hub for performance runs: a replay client, in-memory secrets, a temporary folder, a private defaults suite and a spend total that
    /// is never saved, so the run never reaches the network or the Keychain and never touches a person's conversations.
    static func replay(registry: ClusterRegistry, settingsStore: MacClusterSettingsStore, activity: any ActivityLogging, client: any AIMessaging) -> FirstMateHub {
        let suite = UserDefaults(suiteName: "wheelhouse.firstmate.replay") ?? .standard
        let preferences = FirstMatePreferences(defaults: suite)
        preferences.conversationCap = 50
        preferences.dailyCap = 1_000
        let secrets = InMemoryAISecrets()
        try? secrets.write("replay-key", account: AnthropicKeyStore.account)
        let directory = FileManager.default.temporaryDirectory.appending(path: "wheelhouse-firstmate-replay-\(UUID().uuidString)", directoryHint: .isDirectory)
        return FirstMateHub(registry: registry, settingsStore: settingsStore, preferences: preferences, keySecrets: secrets, conversationSecrets: InMemoryAISecrets(),
                            directory: directory, dailyFile: nil, activity: activity, clientFactory: { _ in client })
    }
}
