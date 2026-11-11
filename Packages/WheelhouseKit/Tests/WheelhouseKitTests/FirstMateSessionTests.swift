import Testing
import Foundation
@testable import WheelhouseKit

@Suite("First Mate session (replayed)")
@MainActor
struct FirstMateSessionTests {
    private func text(_ answer: String, cacheRead: Int = 3_000) -> ReplayTransport.Reply {
        .stream(SSEScript.response(text: [answer], cacheRead: cacheRead))
    }

    private func calls(_ names: [String], round: Int = 0, input: JSONValue = ["cluster": "dev"]) -> ReplayTransport.Reply {
        .stream(SSEScript.response(toolCalls: names.enumerated().map { .init(id: "toolu_\(round)_\($0.offset)", name: $0.element, input: input) }))
    }

    private func orderingIsValid(_ transport: ReplayTransport) -> Bool {
        transport.bodies.allSatisfy { body in
            let messages = (body["messages"]?.arrayValue ?? []).compactMap { entry -> AIMessage? in
                guard let role = entry["role"]?.stringValue.flatMap(AIMessage.Role.init(rawValue:)) else { return nil }
                return AIMessage(role: role, content: entry["content"]?.arrayValue ?? [])
            }
            return MessageOrdering.violations(messages).isEmpty
        }
    }

    // MARK: Turns

    @Test func aPlainTurnStreamsCommitsAndCostsMoney() async {
        let transport = ReplayTransport([text("It is OOMKilled.")])
        let session = makeSession(transport)
        session.send("why is it crashing?")
        await settle(session)
        #expect(session.state == .idle)
        #expect(session.items.map(\.kind) == [.user("why is it crashing?"), .assistant("It is OOMKilled.")])
        #expect(session.spentDollars > 0)
        #expect(session.title == "why is it crashing?")
        #expect(session.snapshot.messages.map(\.role) == [.user, .assistant])
        #expect(session.liveText.isEmpty)
    }

    @Test func cacheReadsAreNonZeroFromTurnTwoAndNoWarningIsRaised() async {
        let transport = ReplayTransport([.stream(try! AIFixtures.lines("answer-turn1")), .stream(try! AIFixtures.lines("answer-turn2-cached"))])
        let session = makeSession(transport)
        session.send("one")
        await settle(session)
        #expect(session.usage.cacheReadTokens == 0)
        session.send("two")
        await settle(session)
        #expect(session.usage.cacheReadTokens == 3_900)
        #expect(session.cacheMissWarnings == 0)
        // History is append-only: the second request starts with exactly the first request's messages plus the answer.
        let bodies = transport.bodies
        #expect(bodies[1]["messages"]?.arrayValue?.prefix(1) == bodies[0]["messages"]?.arrayValue?.prefix(1))
        #expect(bodies[1]["messages"]?.arrayValue?.count == 3)
        #expect(orderingIsValid(transport))
    }

    @Test func twoTurnsInARowWithoutCacheReadsAreCounted() async {
        let transport = ReplayTransport([], then: { _ in .stream(SSEScript.response(text: ["a"], cacheRead: 0)) })
        let session = makeSession(transport)
        for n in 1...4 { session.send("q\(n)"); await settle(session) }
        #expect(session.cacheMissWarnings >= 1)
    }

    @Test func aChangeOfModelOrEffortIsExemptFromTheCacheCheck() async {
        let transport = ReplayTransport([], then: { _ in .stream(SSEScript.response(text: ["a"], cacheRead: 0)) })
        let session = makeSession(transport)
        for n in 1...5 { session.send("q\(n)", investigate: n.isMultiple(of: 2)); await settle(session) }
        #expect(session.cacheMissWarnings == 0)
    }

    @Test func investigateRaisesTheEffortOfThatSendOnly() async {
        let transport = ReplayTransport([text("a"), text("b")])
        let session = makeSession(transport)
        session.send("deep", investigate: true)
        await settle(session)
        session.send("normal")
        await settle(session)
        #expect(transport.bodies.map { $0["output_config"]?["effort"]?.stringValue } == ["high", "medium"])
    }

    // MARK: The tool loop

    @Test func toolResultsAllReturnInOneUserMessageInCallOrder() async {
        let tools = ScriptedTools(handler: { name, _ in ToolOutput(json: ["tool": .string(name)]) })
        let transport = ReplayTransport([calls(["get_events", "list_clusters", "rbac_can_i"].prefix(2).map { $0 }, input: ["cluster": "dev"]), text("done")])
        let session = makeSession(transport, tools: tools)
        session.send("look around")
        await settle(session)
        let second = transport.bodies[1]["messages"]?.arrayValue ?? []
        let results = second.last?["content"]?.arrayValue ?? []
        #expect(second.last?["role"] == "user")
        #expect(results.compactMap { $0["tool_use_id"]?.stringValue } == ["toolu_0_0", "toolu_0_1"])
        #expect(results.map { $0["type"]?.stringValue } == ["tool_result", "tool_result"])
        #expect(orderingIsValid(transport))
        let rows = session.items.compactMap { item -> ToolRow? in if case .tool(let row) = item.kind { row } else { nil } }
        #expect(rows.count == 2 && rows.allSatisfy(\.finished) && rows.allSatisfy { ($0.resultBytes ?? 0) > 0 })
    }

    @Test func anInvalidToolInputBecomesAnErrorResultAndTheToolDoesNotRun() async {
        let tools = ScriptedTools()
        let transport = ReplayTransport([
            .stream(SSEScript.response(toolCalls: [.init(id: "toolu_a", name: "get_logs", input: ["cluster": "dev"]), .init(id: "toolu_b", name: "nope", input: [:])])),
            text("sorry"),
        ])
        let session = makeSession(transport, tools: tools)
        session.send("logs")
        await settle(session)
        #expect(tools.callNames.isEmpty)
        let results = transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []
        #expect(results.map { $0["is_error"] } == [true, true])
        #expect(results[0]["content"]?.stringValue?.contains("invalid_input") == true)
        #expect(results[1]["content"]?.stringValue?.contains("unknown_tool") == true)
    }

    @Test func aMaxTokensStopWithToolCallsAnswersEachCallWithAnError() async {
        let cut = SSEScript.response(toolCalls: [.init(id: "toolu_x", name: "list_clusters", input: [:])], stopReason: "max_tokens")
        let tools = ScriptedTools()
        let transport = ReplayTransport([.stream(cut), text("ok")])
        let session = makeSession(transport, tools: tools)
        session.send("go")
        await settle(session)
        #expect(tools.callNames.isEmpty)
        #expect((transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue?.first?["content"]?.stringValue ?? "").contains("cut_off"))
    }

    @Test func aTurnIsLimitedToTwentyFiveToolCallsThenOneFinalTurnWithoutTools() async {
        let tools = ScriptedTools()
        var replies: [ReplayTransport.Reply] = (0..<5).map { calls(Array(repeating: "list_clusters", count: 5), round: $0, input: [:]) }
        replies.append(text("here is what I have"))
        let transport = ReplayTransport(replies)
        let session = makeSession(transport, tools: tools)
        session.send("everything")
        await settle(session)
        #expect(tools.callNames.count == 25)
        #expect(transport.requests.count == 6)
        let last = transport.bodies[5]
        #expect(last["tool_choice"] == ["type": "none"])
        let messages = last["messages"]?.arrayValue ?? []
        #expect(messages.last?["role"] == "system")
        #expect(messages.last?["content"]?.stringValue?.contains("Tool budget reached") == true)
        #expect(messages[messages.count - 2]["role"] == "user")      // the note follows the user message carrying the last tool results
        #expect(transport.bodies[4]["tool_choice"] == ["type": "auto"])
        #expect(orderingIsValid(transport))
    }

    @Test func toolsRunAtMostFourAtATimeAndProposalsRunOneByOneInOrder() async {
        actor Gauge { var running = 0; var peak = 0; var order: [String] = []
            func enter() { running += 1; peak = max(peak, running) }
            func leave() { running -= 1 }
            func note(_ s: String) { order.append(s) } }
        let gauge = Gauge()
        let tools = ScriptedTools(handler: { _, _ in ToolOutput(json: ["ok": true]) })
        // A runner that measures concurrency.
        struct Measuring: FirstMateToolRunning {
            let inner: ScriptedTools; let gauge: Gauge
            var definitions: [ToolDefinition] { inner.definitions }
            func run(name: String, input: JSONValue) async -> ToolOutput {
                await gauge.enter()
                try? await Task.sleep(for: .milliseconds(30))
                await gauge.note(name)
                await gauge.leave()
                return await inner.run(name: name, input: input)
            }
        }
        let uses = (0..<9).map { SSEScript.ToolCall(id: "toolu_\($0)", name: "list_clusters", input: [:]) }
        let transport = ReplayTransport([.stream(SSEScript.response(toolCalls: uses)), text("ok")])
        let session = makeSession(transport, tools: Measuring(inner: tools, gauge: gauge))
        session.send("many")
        await settle(session)
        #expect(await gauge.peak <= FirstMateSession.maxParallelTools)
        #expect(await gauge.peak > 1)
        let ids = (transport.bodies[1]["messages"]?.arrayValue?.last?["content"]?.arrayValue ?? []).compactMap { $0["tool_use_id"]?.stringValue }
        #expect(ids == uses.map(\.id))     // call order, not completion order
    }

    // MARK: Proposals and notes

    @Test func aProposalCardAppearsAndItsOutcomeIsANoteAfterTheNextUserMessage() async {
        let coordinator = ProposalCoordinator()
        let dev = testCluster("dev")
        let source = FakeToolboxSource([dev])
        let policy = ToolboxPolicy(caller: .firstMate(conversation: "c"))
        let runner = ToolboxRunner(toolbox: ClusterToolbox(source: source, policy: policy), proposals: ProposalTools(source: source, policy: policy, coordinator: coordinator))
        let proposal = SSEScript.ToolCall(id: "toolu_p", name: "propose_command", input: ["cluster": "dev", "command": "kubectl get pods", "reason": "look"])
        let transport = ReplayTransport([.stream(SSEScript.response(toolCalls: [proposal])), text("Review the card."), text("Thanks.")])
        let session = makeSession(transport, tools: runner, coordinator: coordinator)
        session.send("fix it")
        await settle(session)
        #expect(session.items.contains { $0.kind == .proposal(id: "p-1") })
        #expect(coordinator.proposals.count == 1 && coordinator.proposals[0].state == .pending)
        coordinator.markApplied("p-1")
        session.send("applied it")
        await settle(session)
        let messages = transport.bodies[2]["messages"]?.arrayValue ?? []
        let tail = messages.suffix(2)
        #expect(tail.map { $0["role"]?.stringValue } == ["user", "system"])
        #expect(tail.last?["content"]?.stringValue?.contains("Proposal p-1 was applied by the user") == true)
        #expect(orderingIsValid(transport))
        #expect(coordinator.takeOutcomeNotes(for: "c").isEmpty)
    }

    @Test func aSelectionNoteGoesOutOnceAndAgainOnlyWhenTheSelectionChanges() async {
        let transport = ReplayTransport([], then: { _ in .stream(SSEScript.response(text: ["a"], cacheRead: 100)) })
        let session = makeSession(transport)
        session.context = FirstMateContext(description: "pod/web-1 in apps on dev")
        session.send("one"); await settle(session)
        session.send("two"); await settle(session)
        session.context = FirstMateContext(description: "deployment/web in apps on dev")
        session.send("three"); await settle(session)
        func systems(_ n: Int) -> [String] { (transport.bodies[n]["messages"]?.arrayValue ?? []).filter { $0["role"] == "system" }.compactMap { $0["content"]?.stringValue } }
        #expect(systems(0) == ["Context: pod/web-1 in apps on dev"])
        #expect(systems(1) == ["Context: pod/web-1 in apps on dev"])        // history is append-only: the old note stays, no new one
        #expect(systems(2).count == 2 && systems(2)[1] == "Context changed: deployment/web in apps on dev")
        #expect(orderingIsValid(transport))
    }

    @Test func typedTextAndNotesAreRedactedBeforeTheyLeave() async {
        let transport = ReplayTransport([text("ok")])
        let session = makeSession(transport)
        let token = ["gh", "p_", String(repeating: "a", count: 36)].joined()
        session.queueNote("token \(token) leaked")
        session.send("my password=hunter2 and \(token)")
        await settle(session)
        let body = String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self)
        #expect(!body.contains(token))
        #expect(!body.contains("hunter2"))
        #expect(body.contains("redacted"))
    }

    // MARK: Failures keep the history valid

    @Test func aFailedTurnLeavesNoTraceAndRetryResendsTheSameRequest() async {
        let transport = ReplayTransport([.status(400, body: #"{"error":{"message":"bad"}}"#), text("fine")])
        let session = makeSession(transport)
        session.queueNote("a note that must survive")
        session.send("hello")
        await settle(session)
        #expect(session.state == .failed("bad"))
        #expect(session.snapshot.messages.isEmpty)
        #expect(session.pendingUserText == "hello")
        #expect(session.canRetry)
        session.retry()
        await settle(session)
        #expect(session.state == .idle)
        #expect(transport.bodies[0]["messages"] == transport.bodies[1]["messages"])
        #expect(transport.bodies[1]["messages"]?.arrayValue?.last?["role"] == "system")
        #expect(session.snapshot.messages.map(\.role) == [.user, .system, .assistant])
    }

    @Test func rephrasingAFailedTurnPutsTheTextBackAndKeepsTheNotes() async {
        let transport = ReplayTransport([.status(401), text("later")])
        let session = makeSession(transport)
        session.queueNote("keep me")
        session.send("first try")
        await settle(session)
        #expect(session.state == .failed("The API key was rejected. It may be wrong or revoked."))
        session.abandonTurn()
        #expect(session.draftToRestore == "first try")
        #expect(session.snapshot.messages.isEmpty)
        session.consumeDraftRestore()
        session.send("second try")
        await settle(session)
        let messages = transport.bodies[1]["messages"]?.arrayValue ?? []
        #expect(messages.last?["content"]?.stringValue == "keep me")
    }

    @Test func aRefusalIsShownPlainlyAndRetryAndRephraseWork() async {
        let transport = ReplayTransport([.stream(try! AIFixtures.lines("refusal")), text("a different answer")])
        let session = makeSession(transport)
        session.send("do something odd")
        await settle(session)
        #expect(session.state == .refused(category: "cyber", explanation: "The request was declined by a safety classifier."))
        #expect(session.snapshot.messages.isEmpty)       // nothing from the refused turn is in the history
        #expect(session.spentDollars > 0)                // but it was billed
        session.retry()
        await settle(session)
        #expect(session.state == .idle)
        #expect(session.items.last?.kind == .assistant("a different answer"))
        let again = ReplayTransport([.stream(try! AIFixtures.lines("refusal"))])
        let other = makeSession(again)
        other.send("x")
        await settle(other)
        other.abandonTurn()
        #expect(other.draftToRestore == "x")
        #expect(other.state == .idle)
    }

    @Test func aRefusalAfterToolResultsClosesTheTurnWithAPlaceholderWhenAbandoned() async {
        let tools = ScriptedTools()
        let transport = ReplayTransport([calls(["list_clusters"], input: [:]), .stream(try! AIFixtures.lines("refusal"))])
        let session = makeSession(transport, tools: tools)
        session.send("go")
        await settle(session)
        guard case .refused = session.state else { Issue.record("expected a refusal"); return }
        session.abandonTurn()
        #expect(session.snapshot.messages.map(\.role) == [.user, .assistant, .user, .assistant])
        #expect(MessageOrdering.violations(session.snapshot.messages).isEmpty)
    }

    @Test func aNewMessageAfterAMidTurnFailureKeepsTheHistoryValid() async {
        let transport = ReplayTransport([calls(["list_clusters"], input: [:]), .status(400, body: #"{"error":{"message":"bad"}}"#), text("fine")])
        let session = makeSession(transport)
        session.send("go")
        await settle(session)
        guard case .failed = session.state else { Issue.record("expected a failure"); return }
        session.send("x")        // typing on instead of Retry
        await settle(session)
        #expect(MessageOrdering.violations(session.snapshot.messages).isEmpty)
        #expect(orderingIsValid(transport))
    }

    @Test func aDeletedConversationIsNeverWrittenAgain() async throws {
        let dir = tempDirectory()
        let store = ConversationStore(directory: dir, secrets: InMemoryAISecrets())
        let transport = ReplayTransport([.paced(SSEScript.response(text: ["a", "b"]), every: .milliseconds(30))])
        let session = makeSession(transport, store: store)
        session.send("hello")
        try? await Task.sleep(for: .milliseconds(60))
        session.detach()
        await settle(session)
        await session.flushStorage()
        try await store.delete("c")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "c.whchat").path))
        session.send("again")
        await session.flushStorage()
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "c.whchat").path))
    }

    @Test func oneResponseWithMoreThanTheBudgetOfCallsRunsOnlyTheBudget() async {
        let tools = ScriptedTools()
        let thirty = (0..<30).map { SSEScript.ToolCall(id: "toolu_\($0)", name: "list_clusters", input: [:]) }
        let transport = ReplayTransport([.stream(SSEScript.response(toolCalls: thirty)), text("done")])
        let session = makeSession(transport, tools: tools)
        session.send("lots")
        await settle(session)
        #expect(tools.callNames.count == 25)
        let results = transport.bodies[1]["messages"]?.arrayValue?.dropLast().last?["content"]?.arrayValue ?? []
        #expect(results.count == 30)
        #expect(results.suffix(5).allSatisfy { $0["is_error"] == true && $0["content"]?.stringValue?.contains("budget_reached") == true })
    }

    @Test func stoppingAStreamRollsBackTheTurn() async {
        let slow = ReplayTransport([.paced(SSEScript.response(text: Array(repeating: "word ", count: 40)), every: .milliseconds(20))])
        let session = makeSession(slow)
        session.send("tell me a lot")
        try? await Task.sleep(for: .milliseconds(100))
        session.stop()
        await settle(session)
        #expect(session.state == .idle)
        #expect(session.draftToRestore == "tell me a lot")
        #expect(session.snapshot.messages.isEmpty)
    }

    @Test func stoppingDuringToolWorkClosesTheTurnWithErrorResultsAndAPlaceholder() async {
        let tools = ScriptedTools(handler: { _, _ in ToolOutput(json: ["ok": true]) })
        struct Slow: FirstMateToolRunning {
            let inner: ScriptedTools
            var definitions: [ToolDefinition] { inner.definitions }
            func run(name: String, input: JSONValue) async -> ToolOutput { try? await Task.sleep(for: .seconds(5)); return ToolOutput(json: ["late": true]) }
        }
        let transport = ReplayTransport([calls(["list_clusters"], input: [:])])
        let session = makeSession(transport, tools: Slow(inner: tools))
        session.send("go")
        for _ in 0..<1_000 { if case .runningTools = session.state { break }; try? await Task.sleep(for: .milliseconds(5)) }
        session.stop()
        await settle(session)
        #expect(session.state == .idle)
        #expect(MessageOrdering.violations(session.snapshot.messages).isEmpty)
        #expect(session.snapshot.messages.map(\.role) == [.user, .assistant, .user, .assistant])
    }

    // MARK: Streaming to the view

    @Test func streamedTextReachesTheViewAtMostFourTimesASecond() async {
        let chunks = (0..<300).map { "w\($0) " }
        let transport = ReplayTransport([.paced(SSEScript.response(text: chunks), every: .milliseconds(2))])
        let session = makeSession(transport)
        let start = Date()
        session.send("stream")
        await settle(session)
        let seconds = Date().timeIntervalSince(start)
        #expect(session.publishCount >= 1)
        #expect(Double(session.publishCount) <= seconds * 4 + 2)
        #expect(session.items.last?.kind == .assistant(chunks.joined()))
    }

    // MARK: Cost caps and permissions

    @Test func theConversationCapBlocksAndContinueRaisesIt() async {
        let transport = ReplayTransport([], then: { _ in .stream(SSEScript.response(text: ["a"], input: 200_000, output: 20_000)) })
        let session = makeSession(transport, cap: 0.25)
        session.send("one"); await settle(session)
        #expect(session.spentDollars > 0.25)
        session.send("two"); await settle(session)
        guard case .blocked(.conversationCapReached) = session.state else { Issue.record("expected the cap"); return }
        #expect(transport.requests.count == 1)
        #expect(session.draftToRestore == "two")      // the message is not lost
        session.raiseCap()
        #expect(session.capDollars == 2.25)
        #expect(session.state == .idle)
    }

    @Test func theDailyCapBlocksEveryConversation() async {
        let daily = DailySpendStore(url: nil)
        daily.add(10)
        let transport = ReplayTransport([text("never")])
        let session = FirstMateSession(id: "c", client: replayClient(transport), tools: ScriptedTools(), coordinator: ProposalCoordinator(), daily: daily)
        session.send("hi"); await settle(session)
        guard case .blocked(.dailyCapReached) = session.state else { Issue.record("expected the daily cap"); return }
        #expect(transport.requests.isEmpty)
    }

    @Test func aPermissionRequiredResultShowsTheAllowPromptAndAllowingNotesTheModel() async {
        let tools = ScriptedTools(handler: { _, _ in ToolOutput(json: ["error": "permission_required", "cluster": "prod"], isError: true, permissionRequired: "prod") })
        let transport = ReplayTransport([calls(["list_resources"], input: ["cluster": "prod", "kind": "pods"]), text("I need access."), text("reading now")])
        let session = makeSession(transport, tools: tools)
        session.send("what runs on prod?")
        await settle(session)
        #expect(session.pendingPermission == "prod")
        session.allow("prod")
        #expect(session.pendingPermission == nil)
        #expect(session.grants.isGranted("prod"))
        session.send("go ahead")
        await settle(session)
        let tail = (transport.bodies[2]["messages"]?.arrayValue ?? []).suffix(2)
        #expect(tail.map { $0["role"]?.stringValue } == ["user", "system"])
        #expect(tail.last?["content"]?.stringValue?.contains("allowed reading cluster prod") == true)
    }

    // MARK: What was sent, and storage

    @Test func whatWasSentIsRebuiltByteForByte() async {
        let transport = ReplayTransport([calls(["list_clusters"], input: [:]), text("done"), text("again")])
        let session = makeSession(transport)
        session.context = FirstMateContext(description: "cluster dev")
        session.send("one"); await settle(session)
        session.send("two"); await settle(session)
        let record = session.snapshot
        #expect(record.sent.count == transport.requests.count)
        for (index, sent) in record.sent.enumerated() {
            let rebuilt = record.reconstruct(sent)
            #expect(rebuilt?.matches == true, "request \(index + 1)")
            #expect(rebuilt?.body == transport.requests[index].httpBody, "request \(index + 1)")
        }
        #expect(record.prefixes.count == 1)      // the system prompt and tools are stored once
    }

    @Test func aRolledBackRequestIsStillRecordedAsSent() async {
        let transport = ReplayTransport([.status(400, body: #"{"error":{"message":"bad"}}"#)])
        let session = makeSession(transport)
        session.send("secret text")
        await settle(session)
        session.abandonTurn()
        let record = session.snapshot
        #expect(record.sent.count == 1)
        #expect(record.reconstruct(record.sent[0])?.body == transport.requests[0].httpBody)
        #expect(record.sent[0].tail.first?.text == "secret text")
    }

    @Test func aConversationIsSavedEncryptedAndReopened() async throws {
        let dir = tempDirectory()
        let secrets = InMemoryAISecrets()
        let store = ConversationStore(directory: dir, secrets: secrets)
        let transport = ReplayTransport([calls(["list_clusters"], input: [:]), text("The answer.")])
        let session = makeSession(transport, store: store)
        session.send("question")
        await settle(session)
        await session.flushStorage()
        let loaded = try await ConversationStore(directory: dir, secrets: secrets).load("c")
        #expect(loaded.messages == session.snapshot.messages)
        let reopened = FirstMateSession(id: "c", record: loaded, client: replayClient(ReplayTransport([])), tools: ScriptedTools(),
                                        coordinator: ProposalCoordinator(), daily: DailySpendStore(url: nil))
        #expect(reopened.items.map(\.kind).count == session.items.count)
        #expect(reopened.items.contains { if case .tool(let row) = $0.kind { row.finished } else { false } })
        #expect(reopened.spentDollars == session.spentDollars)
    }

    @Test func switchingTheModelKeepsHistoryAndIsRememberedPerConversation() async {
        let transport = ReplayTransport([text("a"), text("b")])
        let session = makeSession(transport)
        session.send("one"); await settle(session)
        session.setProfile(.quick)
        session.send("two"); await settle(session)
        #expect(transport.bodies.map { $0["model"]?.stringValue } == ["claude-opus-5-5", "claude-sonnet-5-5"])
        #expect(session.profile == .quick)
    }
}
