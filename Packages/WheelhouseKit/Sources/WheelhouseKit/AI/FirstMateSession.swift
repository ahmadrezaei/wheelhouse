import Foundation
import Observation

/// Runs First Mate's tools for the session: the read tools through ``ClusterToolbox`` and the proposal tools through
/// ``ProposalTools``. Neither can change a cluster (ARCHITECTURE-MAC section 9.2); this type holds no client.
public protocol FirstMateToolRunning: Sendable {
    var definitions: [ToolDefinition] { get }
    func run(name: String, input: JSONValue) async -> ToolOutput
}

public struct ToolboxRunner: FirstMateToolRunning {
    private let toolbox: ClusterToolbox
    private let proposals: ProposalTools

    public init(toolbox: ClusterToolbox, proposals: ProposalTools) {
        self.toolbox = toolbox
        self.proposals = proposals
    }

    public var definitions: [ToolDefinition] { ToolCatalog.definitions(for: toolbox.policy.caller, includeProposals: true) }

    public func run(name: String, input: JSONValue) async -> ToolOutput {
        if ProposalTool(rawValue: name) != nil { return await proposals.call(named: name, input: input) }
        return await toolbox.call(named: name, input: input)
    }
}

/// What First Mate is looking at, sent as a note after the user's next message when it changes.
public struct FirstMateContext: Sendable, Equatable {
    public var description: String
    public init(description: String) { self.description = description }
}

/// One row of the transcript. The view shows rows lazily; the session keeps them small.
public struct TranscriptItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case user(String)
        case assistant(String)
        case thinking(String)
        /// A tool call row: collapsed to a sentence, with the bytes that were read.
        case tool(ToolRow)
        case proposal(id: String)
        case notice(String)
    }

    public var id: String
    public var kind: Kind
}

public struct ToolRow: Sendable, Equatable {
    public var toolUseID: String
    public var name: String
    public var title: String
    public var input: String
    public var resultBytes: Int?
    public var isError: Bool
    public var finished: Bool
}

/// A conversation with First Mate: the loop of ARCHITECTURE-MAC section 9.2.
///
/// 1. Send; stream text and thinking.
/// 2. On `tool_use`, check `max_tokens` and `refusal` first, validate every input against its schema (an invalid one becomes an
///    `is_error` result), run the calls (at most 4 at a time; proposal tools one by one so `p-N` ids are deterministic) and
///    return **all** results in **one** user message, in call order. Loop.
/// 3. At most 25 tool calls per user turn; then a final turn with a system note and `tool_choice` none.
///
/// **Atomic turns.** A turn's messages (the user's text, the system notes after it, tool results) are committed to the history only
/// together with the assistant message that answers them. A turn that fails, is stopped or is refused leaves the history as it was,
/// so the next request is always valid and the history stays append-only (editing it would invalidate the cache and the thinking).
/// System notes (a changed selection, "proposal applied / declined") wait in ``pendingNotes`` and go out right after the next user
/// message, never between an assistant turn and the user's message.
@MainActor @Observable
public final class FirstMateSession {
    public enum State: Equatable {
        case idle
        case sending
        case runningTools(Int)
        case blocked(CostGate)
        case failed(String)
        case refused(category: String?, explanation: String)
        case cutOff
    }

    public static let maxToolCalls = 25
    public static let maxParallelTools = 4

    public let id: String
    public private(set) var items: [TranscriptItem] = []
    public private(set) var state: State = .idle
    /// Streamed text, published to the view at most four times a second.
    public private(set) var liveText = ""
    public private(set) var liveThinking = ""
    public private(set) var publishCount = 0
    /// A Production cluster that asked to be read; the view shows the Allow prompt.
    public private(set) var pendingPermission: ClusterID?
    /// Text to put back in the composer after a turn was rolled back.
    public private(set) var draftToRestore: String?
    public private(set) var storageProblem: String?
    public private(set) var cacheMissWarnings = 0
    public var context: FirstMateContext?
    public let coordinator: ProposalCoordinator
    public let grants: ConversationGrants

    public var profile: AIModelChoice { record.profile }
    public var title: String { record.title }
    public var spentDollars: Double { record.spentDollars }
    public var capDollars: Double { record.capDollars }
    public var usage: AIUsage { record.usage }
    public var sentRequests: [SentRequest] { record.sent }
    public var isBusy: Bool {
        switch state {
        case .sending, .runningTools: true
        default: false
        }
    }
    /// The text of the turn that is waiting (sending, failed or refused), before it is part of the history.
    public var pendingUserText: String? { turnIsOpening ? pending.first(where: { $0.role == .user })?.text : nil }
    public var canRetry: Bool { !pending.isEmpty && !isBusy }
    public var snapshot: ConversationRecord { record }

    private var record: ConversationRecord
    @ObservationIgnored private let client: any AIMessaging
    @ObservationIgnored private let tools: any FirstMateToolRunning
    @ObservationIgnored private let store: ConversationStore?
    @ObservationIgnored private let daily: DailySpendStore
    @ObservationIgnored private let redactor: Redactor
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var pendingNotes: [String] = []
    /// The messages of the turn in progress that are not in the history yet.
    @ObservationIgnored private var pending: [AIMessage] = []
    @ObservationIgnored private var turnIsOpening = true
    @ObservationIgnored private var turnProfile: AIModelChoice?
    @ObservationIgnored private var toolCallsThisTurn = 0
    @ObservationIgnored private var contextForTurn: String?
    @ObservationIgnored private var openingDraft = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveChain: Task<Void, Never>?
    @ObservationIgnored private var rawText = ""
    @ObservationIgnored private var rawThinking = ""
    @ObservationIgnored private var gate = UpdateGate()
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var lastCacheRead: Int?
    @ObservationIgnored private var lastRequestKey: String?
    @ObservationIgnored private var toolRowIndex: [String: Int] = [:]

    public init(id: String = UUID().uuidString, record: ConversationRecord? = nil, client: any AIMessaging, tools: any FirstMateToolRunning,
                coordinator: ProposalCoordinator, grants: ConversationGrants? = nil, store: ConversationStore? = nil, daily: DailySpendStore,
                redactor: Redactor = Redactor(), profile: AIModelChoice = .standard, capDollars: Double = CostCaps.defaultConversation,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let existing = record ?? ConversationRecord(id: id, createdAt: now(), profile: profile, capDollars: capDollars)
        self.id = existing.id
        self.record = existing
        self.client = client
        self.tools = tools
        self.coordinator = coordinator
        self.grants = grants ?? ConversationGrants(conversation: existing.id)
        self.store = store
        self.daily = daily
        self.redactor = redactor
        self.now = now
        rebuildItems()
    }

    // MARK: Settings of the conversation

    /// Switching model mid-conversation is allowed; the cache restarts and earlier reasoning is not read by the other model.
    public func setProfile(_ choice: AIModelChoice) {
        guard choice != record.profile else { return }
        record.profile = choice
        persist()
    }

    /// "Continue (+$2)".
    public func raiseCap(by dollars: Double = CostCaps.continueStep) {
        record.capDollars += dollars
        if case .blocked = state { state = .idle }
        persist()
    }

    /// A note for the model, appended after the user's next message (never in between).
    public func queueNote(_ text: String) { pendingNotes.append(redactor.redact(text)) }

    /// The person allowed a Production cluster for this conversation. The model is told in the next message.
    public func allow(_ cluster: ClusterID) {
        grants.grant(cluster)
        pendingPermission = nil
        queueNote("The user allowed reading cluster \(cluster) in this conversation. Retry the reads that needed it.")
    }

    public func dismissPermissionPrompt() { pendingPermission = nil }
    public func consumeDraftRestore() { draftToRestore = nil }

    // MARK: Sending

    /// Sends `text`. `investigate` raises the effort to high for this send (⌥↩).
    public func send(_ text: String, investigate: Bool = false) {
        guard !isBusy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // A turn that failed or was refused after tool results were exchanged must be closed first: the history would otherwise end with
        // a tool call nobody answered, and every later request would be refused.
        if !pending.isEmpty, !turnIsOpening { commitPlaceholder("I stopped before finishing that.") }
        let safe = redactor.redact(text)
        openingDraft = text
        var notes = pendingNotes + coordinator.takeOutcomeNotes(for: id).map { redactor.redact($0) }
        pendingNotes = notes   // held until the turn commits, so a rolled-back turn loses none
        if let context, context.description != record.lastContext {
            notes.append(redactor.redact(record.lastContext == nil ? "Context: \(context.description)" : "Context changed: \(context.description)"))
            contextForTurn = context.description
        } else {
            contextForTurn = nil
        }
        var turn = [AIMessage.user(safe)]
        if !notes.isEmpty { turn.append(.system(notes.joined(separator: "\n"))) }
        pending = turn
        turnIsOpening = true
        toolCallsThisTurn = 0
        budgetExhausted = false
        turnProfile = investigate ? record.profile.investigating : record.profile
        draftToRestore = nil
        run()
    }

    /// Sends the same request again after a failure or a refusal.
    public func retry() {
        guard canRetry else { return }
        run()
    }

    /// Gives up on the turn: its text goes back to the composer ("Rephrase"), or, when tool results were already exchanged, the turn
    /// is closed with a short assistant line so the history stays valid.
    public func abandonTurn() {
        guard !isBusy, !pending.isEmpty else { return }
        if turnIsOpening { rollBack() } else { commitPlaceholder("I stopped before finishing that.") }
        state = .idle
    }

    public func stop() {
        task?.cancel()
    }

    @ObservationIgnored private var detached = false

    /// The conversation was deleted: stop work and never write it again (a queued save finishes first, so the hub can delete the file
    /// after ``flushStorage()`` without the file coming back).
    public func detach() {
        detached = true
        task?.cancel()
    }

    private func run() {
        state = .sending
        task = Task { [weak self] in await self?.runLoop() }
    }

    // MARK: The loop

    private func runLoop() async {
        while true {
            if let blocked = gateCheck() {
                state = .blocked(blocked)
                if !turnIsOpening { commitPlaceholder("I stopped here because the cost cap was reached.") } else { rollBack() }
                return
            }
            let choice = turnProfile ?? record.profile
            let response: AIResponse
            do {
                response = try await request(choice: choice)
            } catch AIError.cancelled {
                finishStopped()
                return
            } catch is CancellationError {
                finishStopped()
                return
            } catch {
                state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                return
            }
            account(response, choice: choice)
            if Task.isCancelled { finishStopped(); return }
            if response.isRefusal {
                let details = response.stopDetails
                state = .refused(category: details?["category"]?.stringValue,
                                 explanation: details?["explanation"]?.stringValue ?? "The model declined this request.")
                return
            }
            var message = response.message
            if message.content.isEmpty { message.content = [AIMessage.textBlock("(no answer)")] }
            commit(pending + [message])
            pending = []
            turnIsOpening = false
            appendItems(for: message)
            let uses = message.toolUses
            guard !uses.isEmpty else {
                state = response.stopReason == "max_tokens" ? .cutOff : .idle
                return
            }
            state = .runningTools(uses.count)
            let cutOff = response.stopReason == "max_tokens"
            let results = await runTools(uses, invalid: response.invalidToolInputs, truncated: cutOff, budget: Self.maxToolCalls - toolCallsThisTurn)
            toolCallsThisTurn += uses.count
            let content = zip(uses, results).map { use, out in AIMessage.toolResult(id: use.id, text: out.text, isError: out.isError) }
            pending = [AIMessage(role: .user, content: content)]
            for (use, out) in zip(uses, results) { recordResult(for: use, out) }
            if Task.isCancelled { finishStopped(); return }
            if toolCallsThisTurn >= Self.maxToolCalls {
                pending.append(.system("Tool budget reached; answer with what you have."))
                turnProfile = choice
                state = .sending
                // The last turn of the budget sends no tools.
                budgetExhausted = true
            } else {
                state = .sending
            }
        }
    }

    @ObservationIgnored private var budgetExhausted = false

    private func gateCheck() -> CostGate? {
        // The next request re-reads the whole prompt: at least the cached price of the last one.
        let nextInput = PriceTable.price(for: record.profile.model).cacheRead * Double(lastInputTokens) / 1_000_000
        let gate = CostGate.check(conversationSpent: record.spentDollars, conversationCap: record.capDollars, dailySpent: daily.today,
                                  dailyCap: dailyCap, nextInputEstimate: nextInput)
        return gate == .open ? nil : gate
    }

    @ObservationIgnored public var dailyCap = CostCaps.defaultDaily
    @ObservationIgnored private var lastInputTokens = 0

    private func request(choice: AIModelChoice) async throws -> AIResponse {
        let messages = record.messages + pending
        let built = AnthropicRequestBuilder.request(model: choice, messages: messages, tools: tools.definitions, toolsAllowed: !budgetExhausted)
        let prefixHash = AnthropicRequestBuilder.prefixHash(tools: tools.definitions)
        record.prefixes[prefixHash] = AnthropicRequestBuilder.prefix(tools: tools.definitions)
        record.sent.append(SentRequest(id: record.sent.count + 1, at: now(), model: choice.model, effort: choice.effort.rawValue,
                                       historyCount: record.messages.count, tail: pending, prefixHash: prefixHash, bodyHash: built.sha256,
                                       bytes: built.data.count, toolsAllowed: !budgetExhausted))
        resetLive()
        let (updates, continuation) = AsyncStream.makeStream(of: AIStreamUpdate.self)
        let consumer = Task { @MainActor [weak self] in
            for await update in updates { self?.apply(update) }
        }
        defer { flushTask?.cancel() }
        do {
            let response = try await client.send(built) { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            resetLive()
            return response
        } catch {
            continuation.finish()
            await consumer.value
            resetLive()
            throw error
        }
    }

    // MARK: Streaming to the view

    private func apply(_ update: AIStreamUpdate) {
        switch update {
        case .text(let text): rawText += text
        case .thinking(let text): rawThinking += text
        case .fallback: rawText = ""; rawThinking = ""
        case .toolUseStarted: break
        }
        if gate.shouldPublish(at: now()) { publish() } else { scheduleFlush() }
    }

    private func publish() {
        flushTask?.cancel()
        flushTask = nil
        liveText = rawText
        liveThinking = rawThinking
        publishCount += 1
    }

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(UpdateGate.minimumInterval))
            guard !Task.isCancelled, let self else { return }
            self.flushTask = nil
            if self.gate.shouldPublish(at: self.now()) { self.publish() }
        }
    }

    private func resetLive() {
        flushTask?.cancel()
        flushTask = nil
        rawText = ""
        rawThinking = ""
        liveText = ""
        liveThinking = ""
        gate.reset()
    }

    // MARK: Tools

    private func runTools(_ uses: [AIMessage.ToolUse], invalid: Set<String>, truncated: Bool, budget: Int) async -> [ToolOutput] {
        var results = [ToolOutput?](repeating: nil, count: uses.count)
        let definitions = Dictionary(tools.definitions.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var runnable: [Int] = []
        for (index, use) in uses.enumerated() {
            if truncated {
                results[index] = Self.failure("cut_off", "The response was cut off before this call was complete. Make a smaller call or answer without it.")
            } else if index >= budget {
                results[index] = Self.failure("budget_reached", "The tool budget for this turn is used up. Answer with what you have.")
            } else if invalid.contains(use.id) {
                results[index] = Self.failure("invalid_input", "The tool input was not valid JSON.")
            } else if let definition = definitions[use.name] {
                if let problem = ToolInputValidator.problem(for: use.input, schema: definition.inputSchema) {
                    results[index] = Self.failure("invalid_input", problem)
                } else { runnable.append(index) }
            } else {
                results[index] = Self.failure("unknown_tool", "No tool named \(use.name).")
            }
        }
        let reads = runnable.filter { ProposalTool(rawValue: uses[$0].name) == nil }
        let proposals = runnable.filter { ProposalTool(rawValue: uses[$0].name) != nil }
        let runner = tools
        var cursor = 0
        while cursor < reads.count, !Task.isCancelled {
            let batch = Array(reads[cursor..<min(cursor + Self.maxParallelTools, reads.count)])
            cursor += batch.count
            await withTaskGroup(of: (Int, ToolOutput).self) { group in
                for index in batch {
                    let use = uses[index]
                    group.addTask { (index, await runner.run(name: use.name, input: use.input)) }
                }
                for await (index, output) in group { results[index] = output }
            }
        }
        for index in proposals where !Task.isCancelled {
            results[index] = await runner.run(name: uses[index].name, input: uses[index].input)
        }
        return results.map { $0 ?? Self.failure("stopped", "Stopped by the user before this call ran.") }
    }

    private static func failure(_ code: String, _ message: String) -> ToolOutput {
        ToolOutput(json: ["error": .string(code), "message": .string(message)], isError: true)
    }

    // MARK: Accounting and the history

    private func account(_ response: AIResponse, choice: AIModelChoice) {
        let cost = PriceTable.cost(of: response.usage, defaultModel: choice.model)
        record.spentDollars += cost
        record.usage = record.usage + response.totalUsage
        lastInputTokens = response.finalUsage.totalInput
        daily.add(cost)
        // Two turns in a row with no cache read means something silently invalidates the prefix. A change of model or effort
        // restarts the cache on purpose, so those turns are exempt. Logged and counted, never a crash.
        let key = "\(choice.model)/\(choice.effort.rawValue)"
        if let last = lastCacheRead, lastRequestKey == key, last == 0, response.finalUsage.cacheReadTokens == 0, record.sent.count > 2 { cacheMissWarnings += 1 }
        lastCacheRead = response.finalUsage.cacheReadTokens
        lastRequestKey = key
    }

    private func commit(_ messages: [AIMessage]) {
        let firstCommit = turnIsOpening
        record.messages += messages
        if firstCommit {
            pendingNotes = []
            if let contextForTurn { record.lastContext = contextForTurn }
            if record.title == "New conversation", let first = messages.first, first.role == .user {
                let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? first.text
                record.title = String(line.prefix(60))
            }
            items.append(TranscriptItem(id: "u\(record.messages.count)", kind: .user(messages.first?.text ?? "")))
        }
        record.updatedAt = now()
        persist()
    }

    private func commitPlaceholder(_ text: String) {
        commit(pending + [.assistant(text)])
        pending = []
        turnIsOpening = false
        items.append(TranscriptItem(id: "n\(record.messages.count)", kind: .notice(text)))
    }

    private func rollBack(restoreDraft: Bool = true) {
        pending = []
        if restoreDraft { draftToRestore = openingDraft }
        turnProfile = nil
    }

    private func finishStopped() {
        if turnIsOpening { rollBack() } else { commitPlaceholder("(stopped)") }
        state = .idle
    }

    private func persist() {
        guard let store, !detached else { return }
        let snapshot = record
        let previous = saveChain
        saveChain = Task { [weak self] in
            await previous?.value
            do { try await store.save(snapshot) } catch { await MainActor.run { self?.storageProblem = error.localizedDescription } }
        }
    }

    /// Waits until everything queued has been written (tests, quitting).
    public func flushStorage() async { await saveChain?.value }

    // MARK: Transcript rows

    private func appendItems(for message: AIMessage) {
        guard message.role == .assistant else { return }
        for (offset, block) in message.content.enumerated() {
            let rowID = "a\(record.messages.count)-\(offset)"
            switch block["type"]?.stringValue {
            case "text": if let text = block["text"]?.stringValue, !text.isEmpty { items.append(TranscriptItem(id: rowID, kind: .assistant(text))) }
            case "thinking": if let text = block["thinking"]?.stringValue, !text.isEmpty { items.append(TranscriptItem(id: rowID, kind: .thinking(text))) }
            case "tool_use":
                guard let toolID = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                let input = block["input"] ?? [:]
                toolRowIndex[toolID] = items.count
                items.append(TranscriptItem(id: "t\(toolID)", kind: .tool(ToolRow(toolUseID: toolID, name: name, title: ToolSummary.title(name, input),
                                                                                  input: input.jsonString(pretty: true), resultBytes: nil, isError: false, finished: false))))
            default: break
            }
        }
    }

    private func recordResult(for use: AIMessage.ToolUse, _ output: ToolOutput) {
        if let cluster = output.permissionRequired { pendingPermission = cluster }
        guard let index = toolRowIndex[use.id], items.indices.contains(index), case .tool(var row) = items[index].kind else { return }
        row.resultBytes = output.text.utf8.count
        row.isError = output.isError
        row.finished = true
        items[index].kind = .tool(row)
        if let proposalID = output.json["proposal_id"]?.stringValue, !output.isError {
            items.insert(TranscriptItem(id: "p\(proposalID)", kind: .proposal(id: proposalID)), at: index + 1)
            toolRowIndex = toolRowIndex.mapValues { $0 > index ? $0 + 1 : $0 }
        }
    }

    /// Rows for a conversation loaded from disk. Results are matched to their calls; proposals made in an earlier run are shown as
    /// closed (a proposal waits for review only in the run that made it).
    private func rebuildItems() {
        items = []
        toolRowIndex = [:]
        var results: [String: (bytes: Int, isError: Bool)] = [:]
        for message in record.messages where message.role == .user {
            for block in message.content where block["type"]?.stringValue == "tool_result" {
                if let id = block["tool_use_id"]?.stringValue { results[id] = ((block["content"]?.stringValue ?? "").utf8.count, block["is_error"]?.boolValue ?? false) }
            }
        }
        for (index, message) in record.messages.enumerated() {
            switch message.role {
            case .user where !message.content.contains(where: { $0["type"]?.stringValue == "tool_result" }):
                items.append(TranscriptItem(id: "u\(index)", kind: .user(message.text)))
            case .assistant:
                for (offset, block) in message.content.enumerated() {
                    let rowID = "a\(index)-\(offset)"
                    switch block["type"]?.stringValue {
                    case "text": if let text = block["text"]?.stringValue, !text.isEmpty { items.append(TranscriptItem(id: rowID, kind: .assistant(text))) }
                    case "thinking": if let text = block["thinking"]?.stringValue, !text.isEmpty { items.append(TranscriptItem(id: rowID, kind: .thinking(text))) }
                    case "tool_use":
                        guard let toolID = block["id"]?.stringValue, let name = block["name"]?.stringValue else { continue }
                        let input = block["input"] ?? [:]
                        let result = results[toolID]
                        items.append(TranscriptItem(id: "t\(toolID)", kind: .tool(ToolRow(toolUseID: toolID, name: name, title: ToolSummary.title(name, input),
                                                                                          input: input.jsonString(pretty: true), resultBytes: result?.bytes,
                                                                                          isError: result?.isError ?? false, finished: result != nil))))
                    default: break
                    }
                }
            default: break
            }
        }
    }
}

/// One sentence for a tool call row, so the person sees what was read.
public enum ToolSummary {
    public static func title(_ name: String, _ input: JSONValue) -> String {
        let target = ["name", "pod", "release", "object_name", "kind", "query", "resource", "path", "controller"].compactMap { input[$0]?.stringValue }.first
        let verb = name.replacingOccurrences(of: "_", with: " ")
        let place = ["namespace", "cluster"].compactMap { input[$0]?.stringValue }.joined(separator: " · ")
        return [verb, target, place.isEmpty ? nil : "(\(place))"].compactMap { $0 }.joined(separator: " ")
    }
}
