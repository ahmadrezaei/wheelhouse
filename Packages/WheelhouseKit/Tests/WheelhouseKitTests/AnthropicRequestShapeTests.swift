import Testing
import Foundation
@testable import WheelhouseKit

@Suite("Anthropic request shape")
struct AnthropicRequestShapeTests {
    private let tools = ToolCatalog.definitions(for: .firstMate(conversation: "c"), includeProposals: true)

    @Test func theBodyHasExactlyTheDocumentedFields() throws {
        let request = AnthropicRequestBuilder.request(model: .standard, messages: [.user("hi")], tools: tools)
        let body = try #require(request.body.objectValue)
        #expect(Set(body.keys) == ["model", "max_tokens", "stream", "thinking", "output_config", "fallbacks", "system", "tools", "tool_choice", "cache_control", "messages"])
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["max_tokens"] == 32_000)
        #expect(body["stream"] == true)
        #expect(body["thinking"] == ["type": "adaptive", "display": "summarized"])
        #expect(body["output_config"] == ["effort": "medium"])
        #expect(body["fallbacks"] == "default")
        #expect(body["tool_choice"] == ["type": "auto"])
        #expect(body["cache_control"] == ["type": "ephemeral"])
        #expect(request.betaHeader == "server-side-fallback-2026-07-01")
        // Rejected by this API version: never sent.
        for rejected in ["temperature", "top_p", "top_k"] { #expect(body[rejected] == nil) }
        #expect(body["thinking"]?["type"] != "disabled")
    }

    @Test func theModelMenuMapsToModelAndEffort() {
        #expect(AIModelChoice.standard == AIModelChoice(model: "claude-opus-5-5", effort: .medium))
        #expect(AIModelChoice.quick == AIModelChoice(model: "claude-sonnet-5-5", effort: .low))
        #expect(AIModelChoice.standard.investigating.effort == .high)
        #expect(AIModelChoice.standard.investigating.model == "claude-opus-5-5")
        let quick = AnthropicRequestBuilder.request(model: .quick, messages: [.user("hi")], tools: tools)
        #expect(quick.body["model"] == "claude-sonnet-5-5")
        #expect(quick.body["output_config"] == ["effort": "low"])
        #expect(AnthropicRequestBuilder.request(model: .standard.investigating, messages: [.user("hi")], tools: tools).body["output_config"] == ["effort": "high"])
    }

    @Test func theSystemBlockCarriesTheOnlyExplicitBreakpoint() throws {
        let body = AnthropicRequestBuilder.request(model: .standard, messages: [.user("hi")], tools: tools).body
        let system = try #require(body["system"]?.arrayValue)
        #expect(system.count == 1)
        #expect(system[0]["cache_control"] == ["type": "ephemeral"])
        #expect(system[0]["text"]?.stringValue == FirstMatePrompt.system)
        // No timestamps, cluster names or per-conversation text in the frozen prompt.
        #expect(!FirstMatePrompt.system.contains("202"))
    }

    @Test func toolsAreSortedAndStreamEagerly() throws {
        let wire = try #require(AnthropicRequestBuilder.request(model: .standard, messages: [.user("hi")], tools: tools.reversed()).body["tools"]?.arrayValue)
        let names = wire.compactMap { $0["name"]?.stringValue }
        #expect(names == names.sorted())
        #expect(names.count == tools.count)
        #expect(wire.allSatisfy { $0["eager_input_streaming"] == true })
    }

    @Test func strictIsSentOnlyForCompatibleSchemasAndBoundsAreNotSent() throws {
        let wire = try #require(AnthropicRequestBuilder.request(model: .standard, messages: [.user("hi")], tools: tools).body["tools"]?.arrayValue)
        for tool in wire {
            let schema = try #require(tool["input_schema"])
            #expect(!CanonicalJSON.string(schema).contains("\"minimum\""))
            #expect(!CanonicalJSON.string(schema).contains("\"maximum\""))
            // Every tool that says strict has a schema strict mode accepts.
            if tool["strict"] == true { #expect(StrictSchema.isCompatible(schema), "\(tool["name"]?.stringValue ?? "")") }
        }
        let patch = try #require(wire.first { $0["name"] == "propose_patch" })
        #expect(patch["strict"] == nil)     // its patch body is an open object
        let logs = try #require(wire.first { $0["name"] == "get_logs" })
        #expect(logs["strict"] == true)
        // The catalog itself keeps its bounds, which the local validator enforces.
        #expect(CanonicalJSON.string(ToolCatalog.definition(.getLogs).inputSchema).contains("\"maximum\""))
    }

    @Test func requestBytesAreDeterministicAndGolden() {
        let tiny = ToolDefinition(name: "ping", description: "Ping.", inputSchema: ["type": "object", "properties": ["a": ["type": "string", "minimum": 1]], "required": ["a"], "additionalProperties": false], isProposal: false)
        let messages: [AIMessage] = [.user("hello"), .system("Context: pod/web"), .assistant("hi")]
        let first = AnthropicRequestBuilder.request(model: .standard, messages: messages, tools: [tiny])
        for _ in 0..<5 { #expect(AnthropicRequestBuilder.request(model: .standard, messages: messages, tools: [tiny]).data == first.data) }
        let text = String(decoding: first.data, as: UTF8.self)
        #expect(text.hasPrefix(#"{"cache_control":{"type":"ephemeral"},"fallbacks":"default","max_tokens":32000,"messages":[{"content":[{"text":"hello","type":"text"}],"role":"user"},{"content":"Context: pod/web","role":"system"},"#))
        #expect(text.contains(#""tools":[{"description":"Ping.","eager_input_streaming":true,"input_schema":{"additionalProperties":false,"properties":{"a":{"type":"string"}},"required":["a"],"type":"object"},"name":"ping","strict":true}]"#))
        #expect(text.contains(#""thinking":{"display":"summarized","type":"adaptive"},"tool_choice":{"type":"auto"},"tools":["#))
    }

    @Test func theLastTurnOfAnExhaustedBudgetSendsNoTools() {
        #expect(AnthropicRequestBuilder.request(model: .standard, messages: [.user("x")], tools: tools, toolsAllowed: false).body["tool_choice"] == ["type": "none"])
    }

    // MARK: Ordering

    @Test func aSystemNoteMustFollowAUserMessage() {
        #expect(MessageOrdering.violations([.user("a"), .system("n"), .assistant("b")]).isEmpty)
        #expect(MessageOrdering.violations([.user("a"), .system("n")]).isEmpty)
        #expect(!MessageOrdering.violations([.system("n"), .user("a")]).isEmpty)
        #expect(!MessageOrdering.violations([.user("a"), .assistant("b"), .system("n")]).isEmpty)
        #expect(!MessageOrdering.violations([.user("a"), .system("n"), .user("c")]).isEmpty)
    }

    @Test func noMessageSitsBetweenAnAssistantTurnAndTheNextUserMessage() {
        // [user, assistant, system, user] is the shape the rule forbids.
        let bad = MessageOrdering.violations([.user("a"), .assistant("b"), .system("n"), .user("c")])
        #expect(!bad.isEmpty)
        #expect(MessageOrdering.violations([.user("a"), .assistant("b"), .user("c"), .system("n")]).isEmpty)
    }

    @Test func toolResultsMustAnswerEveryToolCallInOneUserMessage() {
        let calls = AIMessage(role: .assistant, content: [["type": "tool_use", "id": "t1", "name": "x", "input": [:]], ["type": "tool_use", "id": "t2", "name": "y", "input": [:]]])
        let both = AIMessage(role: .user, content: [AIMessage.toolResult(id: "t1", text: "a", isError: false), AIMessage.toolResult(id: "t2", text: "b", isError: true)])
        let one = AIMessage(role: .user, content: [AIMessage.toolResult(id: "t1", text: "a", isError: false)])
        #expect(MessageOrdering.violations([.user("q"), calls, both, .system("note")]).isEmpty)
        #expect(!MessageOrdering.violations([.user("q"), calls, one]).isEmpty)
    }
}
