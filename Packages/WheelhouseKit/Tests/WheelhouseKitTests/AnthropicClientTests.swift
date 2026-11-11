import Testing
import Foundation
import Synchronization
@testable import WheelhouseKit

private func sendOnce(_ lines: [String], model: AIModelChoice = .standard) async throws -> AIResponse {
    let client = replayClient(ReplayTransport([.stream(lines)]))
    return try await client.send(AnthropicRequestBuilder.request(model: model, messages: [.user("q")], tools: []), onUpdate: { _ in })
}

@Suite("Anthropic stream and client (replayed)")
struct AnthropicClientTests {
    // MARK: Stream

    @Test func aTextAndThinkingStreamBuildsTheAssistantMessage() async throws {
        let updates = Mutex<[AIStreamUpdate]>([])
        let client = replayClient(ReplayTransport([.stream(try AIFixtures.lines("answer-turn1"))]))
        let response = try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [.user("q")], tools: []), onUpdate: { update in updates.withLock { $0.append(update) } })
        #expect(response.message.text == "The container hit its memory limit.")
        #expect(response.stopReason == "end_turn")
        // Thinking is kept exactly as received, with its signature.
        let thinking = try #require(response.message.content.first)
        #expect(thinking["type"] == "thinking")
        #expect(thinking["thinking"] == "The pod was OOMKilled.")
        #expect(thinking["signature"] == "c2ln")
        #expect(updates.withLock { $0 } == [.thinking("The pod was OOMKilled."), .text("The container hit "), .text("its memory limit.")])
        // message_delta usage is cumulative: it replaces the start value.
        #expect(response.finalUsage == AIUsage(inputTokens: 1500, outputTokens: 42, cacheCreationTokens: 2400, cacheReadTokens: 0, model: "claude-opus-5-5"))
    }

    @Test func cacheReadTokensAreNonZeroFromTurnTwo() async throws {
        let transport = ReplayTransport([.stream(try AIFixtures.lines("answer-turn1")), .stream(try AIFixtures.lines("answer-turn2-cached"))])
        let client = replayClient(transport)
        let first = try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [.user("q")], tools: []), onUpdate: { _ in })
        let second = try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [.user("q"), first.message, .user("again")], tools: []), onUpdate: { _ in })
        #expect(first.finalUsage.cacheReadTokens == 0)
        #expect(second.finalUsage.cacheReadTokens > 0)
    }

    @Test func aRefusalSurfacesItsDetails() async throws {
        let response = try await sendOnce(try AIFixtures.lines("refusal"))
        #expect(response.isRefusal)
        #expect(response.stopDetails?["category"] == "cyber")
        #expect(response.stopDetails?["explanation"]?.stringValue?.contains("classifier") == true)
    }

    @Test func aMidStreamFallbackDropsTheDeclinedModelsThinkingAndToolCalls() async throws {
        let response = try await sendOnce(try AIFixtures.lines("fallback-mid-stream"))
        let types = response.message.content.compactMap { $0["type"]?.stringValue }
        #expect(types == ["fallback", "text"])     // thinking and tool_use before the fallback block are gone; the block stays in place
        #expect(response.message.toolUses.isEmpty)
        #expect(response.message.text == "Answer from the fallback model.")
        // Billed per attempt, at each model's own rate.
        #expect(response.usage.map(\.model) == ["claude-opus-5-5", "claude-opus-4-8"])
        let cost = PriceTable.cost(of: response.usage, defaultModel: "claude-opus-5-5")
        #expect(abs(cost - ((900 * 4 + 10 * 20) + (900 * 5 + 30 * 25)) / 1_000_000) < 1e-9)
    }

    @Test func toolInputsStreamAsPartialJsonAndAreParsedAtBlockStop() async throws {
        let lines = SSEScript.response(toolCalls: [.init(id: "toolu_1", name: "get_events", input: ["cluster": "dev", "limit": 5])])
        let response = try await sendOnce(lines)
        #expect(response.stopReason == "tool_use")
        #expect(response.message.toolUses == [.init(id: "toolu_1", name: "get_events", input: ["cluster": "dev", "limit": 5])])
        #expect(response.invalidToolInputs.isEmpty)
    }

    @Test func aTruncatedToolInputIsKeptEmptyAndFlagged() async throws {
        var lines = SSEScript.response(toolCalls: [.init(id: "toolu_2", name: "get_events", input: ["cluster": "dev"])])
        if let last = lines.lastIndex(where: { $0.contains("input_json_delta") }) { lines.remove(at: last) }   // lose the tail of the JSON
        let truncated = lines.map { $0.replacingOccurrences(of: "\"stop_reason\":\"tool_use\"", with: "\"stop_reason\":\"max_tokens\"") }
        let response = try await sendOnce(truncated)
        #expect(response.invalidToolInputs == ["toolu_2"])
        #expect(response.message.toolUses.first?.input == [:])
        #expect(response.stopReason == "max_tokens")
    }

    @Test func anErrorEventInsideTheStreamIsAnError() async throws {
        await #expect(throws: AIError.stream(type: "overloaded_error", message: "Overloaded")) { try await sendOnce(try AIFixtures.lines("error-mid-stream")) }
    }

    @Test func aStreamThatEndsWithoutMessageStopIsAnError() async throws {
        let lines = Array(SSEScript.response(text: ["partial"]).dropLast(3))
        await #expect(throws: AIError.self) { try await sendOnce(lines) }
    }

    // MARK: Client

    @Test func everyRequestCarriesTheKeyVersionAndBetaHeaders() async throws {
        let transport = ReplayTransport([.stream(SSEScript.response(text: ["hi"]))])
        _ = try await replayClient(transport).send(AnthropicRequestBuilder.request(model: .standard, messages: [.user("q")], tools: []), onUpdate: { _ in })
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == testKey)
        #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        // The key goes in the header only, never in the body.
        #expect(!String(decoding: request.httpBody ?? Data(), as: UTF8.self).contains(testKey))
    }

    @Test func noKeyMeansNoRequest() async {
        let transport = ReplayTransport([])
        let client = replayClient(transport, key: nil)
        await #expect(throws: AIError.noKey) { try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [], tools: []), onUpdate: { _ in }) }
        #expect(transport.requests.isEmpty)
    }

    @Test func rateLimitsAreRetriedWithTheRetryAfterHint() async throws {
        let waits = Mutex<[Duration]>([])
        let transport = ReplayTransport([.status(429, headers: ["retry-after": "7"]), .stream(SSEScript.response(text: ["ok"]))])
        let client = AnthropicClient(transport: transport, keyProvider: { testKey }, sleeper: { d in waits.withLock { $0.append(d) } })
        let response = try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [.user("q")], tools: []), onUpdate: { _ in })
        #expect(response.message.text == "ok")
        #expect(waits.withLock { $0 } == [.milliseconds(7_000)])
        #expect(transport.requests.count == 2)
    }

    @Test func serverErrorsBackOffOneThenTwoSecondsAndStopAfterTwoRetries() async {
        let waits = Mutex<[Duration]>([])
        let transport = ReplayTransport([.status(503), .status(529), .status(500)])
        let client = AnthropicClient(transport: transport, keyProvider: { testKey }, sleeper: { d in waits.withLock { $0.append(d) } })
        await #expect(throws: AIError.server(500)) { try await client.send(AnthropicRequestBuilder.request(model: .standard, messages: [], tools: []), onUpdate: { _ in }) }
        #expect(waits.withLock { $0 } == [.milliseconds(1_000), .milliseconds(2_000)])
        #expect(transport.requests.count == 3)
    }

    @Test func connectionErrorsAreRetriedThenReportedOffline() async {
        let transport = ReplayTransport([.failure, .failure, .failure])
        await #expect(throws: AIError.offline) { try await replayClient(transport).send(AnthropicRequestBuilder.request(model: .standard, messages: [], tools: []), onUpdate: { _ in }) }
        #expect(transport.requests.count == 3)
    }

    @Test func clientErrorsAreNotRetried() async {
        for (status, expected) in [(400, AIError.badRequest("bad field")), (401, .unauthorized), (403, .forbidden("nope"))] {
            let body = #"{"type":"error","error":{"type":"x","message":"\#(status == 400 ? "bad field" : "nope")"}}"#
            let transport = ReplayTransport([.status(status, body: body), .stream(SSEScript.response(text: ["never"]))])
            await #expect(throws: expected) { try await replayClient(transport).send(AnthropicRequestBuilder.request(model: .standard, messages: [], tools: []), onUpdate: { _ in }) }
            #expect(transport.requests.count == 1)
        }
    }

    @Test func aStreamThatFailsAfterItBeganIsNotRetried() async {
        let transport = ReplayTransport([.stream(Array(SSEScript.response(text: ["half"]).prefix(8))), .stream(SSEScript.response(text: ["again"]))])
        await #expect(throws: AIError.self) { try await replayClient(transport).send(AnthropicRequestBuilder.request(model: .standard, messages: [], tools: []), onUpdate: { _ in }) }
        #expect(transport.requests.count == 1)
    }

    @Test func theModelListValidatesTheKeyAndFillsTheMenu() async throws {
        let body = #"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"},{"id":"claude-sonnet-5-5"}],"has_more":false}"#
        let transport = ReplayTransport([.status(200, body: body)])
        let models = try await replayClient(transport).models()
        #expect(models == [AIModelInfo(id: "claude-opus-5-5", displayName: "Claude Opus 5.5"), AIModelInfo(id: "claude-sonnet-5-5", displayName: "claude-sonnet-5-5")])
        #expect(transport.requests.first?.httpMethod == "GET")
        #expect(transport.requests.first?.url?.path == "/v1/models")
        await #expect(throws: AIError.unauthorized) { try await replayClient(ReplayTransport([.status(401)])).models() }
    }

    @Test func eachErrorHasPlainWords() {
        let errors: [AIError] = [.noKey, .unauthorized, .forbidden(""), .badRequest("x"), .rateLimited(retryAfter: 3), .rateLimited(retryAfter: nil), .overloaded, .server(500), .offline, .stream(type: "x", message: "m"), .cancelled]
        for error in errors { #expect(error.errorDescription?.isEmpty == false) }
    }

    @Test func sseLinesOtherThanDataAreIgnored() {
        #expect(SSEParser.event(fromLine: "event: ping") == nil)
        #expect(SSEParser.event(fromLine: "") == nil)
        #expect(SSEParser.event(fromLine: ": comment") == nil)
        #expect(SSEParser.event(fromLine: "data: [DONE]") == nil)
        #expect(SSEParser.event(fromLine: "data: not json") == nil)
        #expect(SSEParser.event(fromLine: #"data: {"type":"ping"}"#)?["type"] == "ping")
        #expect(SSEParser.event(fromLine: #"data:{"type":"ping"}"#)?["type"] == "ping")
    }
}
