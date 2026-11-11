import Foundation
import Synchronization

/// Builds Messages API server-sent-event streams in the format the API sends, for replays: the unit tests and the performance
/// scenario run the real client and session over these, and never reach the network.
public enum SSEScript {
    public struct ToolCall: Sendable {
        public var id: String
        public var name: String
        public var input: JSONValue
        public init(id: String, name: String, input: JSONValue) {
            self.id = id
            self.name = name
            self.input = input
        }
    }

    /// One whole response: optional thinking, text in chunks, tool calls (streamed as partial JSON), usage and a stop reason.
    public static func response(id: String = "msg_replay", model: String = "claude-opus-5-5", thinking: String? = nil, text: [String] = [],
                                toolCalls: [ToolCall] = [], stopReason: String? = nil, input: Int = 1_200, cacheRead: Int = 0, cacheWrite: Int = 0,
                                output: Int = 80) -> [String] {
        var lines: [String] = []
        func event(_ name: String, _ json: JSONValue) {
            lines.append("event: \(name)")
            lines.append("data: \(CanonicalJSON.string(json))")
            lines.append("")
        }
        event("message_start", ["type": "message_start", "message": [
            "id": .string(id), "type": "message", "role": "assistant", "model": .string(model), "content": [],
            "stop_reason": .null,
            "usage": ["input_tokens": .int(input), "cache_creation_input_tokens": .int(cacheWrite), "cache_read_input_tokens": .int(cacheRead),
                      "output_tokens": 1],
        ]])
        var index = 0
        if let thinking {
            event("content_block_start", ["type": "content_block_start", "index": .int(index), "content_block": ["type": "thinking", "thinking": "", "signature": ""]])
            event("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": ["type": "thinking_delta", "thinking": .string(thinking)]])
            event("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": ["type": "signature_delta", "signature": "c2lnbmF0dXJl"]])
            event("content_block_stop", ["type": "content_block_stop", "index": .int(index)])
            index += 1
        }
        if !text.isEmpty {
            event("content_block_start", ["type": "content_block_start", "index": .int(index), "content_block": ["type": "text", "text": ""]])
            for chunk in text {
                event("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": ["type": "text_delta", "text": .string(chunk)]])
            }
            event("content_block_stop", ["type": "content_block_stop", "index": .int(index)])
            index += 1
        }
        for call in toolCalls {
            event("content_block_start", ["type": "content_block_start", "index": .int(index),
                                          "content_block": ["type": "tool_use", "id": .string(call.id), "name": .string(call.name), "input": [:]]])
            let json = CanonicalJSON.string(call.input)
            // Split mid-token, as eager input streaming does.
            let cut = json.index(json.startIndex, offsetBy: max(1, json.count / 2))
            for part in [String(json[..<cut]), String(json[cut...])] where !part.isEmpty {
                event("content_block_delta", ["type": "content_block_delta", "index": .int(index), "delta": ["type": "input_json_delta", "partial_json": .string(part)]])
            }
            event("content_block_stop", ["type": "content_block_stop", "index": .int(index)])
            index += 1
        }
        event("ping", ["type": "ping"])
        let reason = stopReason ?? (toolCalls.isEmpty ? "end_turn" : "tool_use")
        event("message_delta", ["type": "message_delta", "delta": ["stop_reason": .string(reason), "stop_sequence": .null],
                                "usage": ["output_tokens": .int(output)]])
        event("message_stop", ["type": "message_stop"])
        return lines
    }
}

/// A transport that answers from a script and records every request it was given.
public final class ReplayTransport: AITransport {
    public enum Reply: Sendable {
        case stream([String])
        case status(Int, headers: [String: String] = [:], body: String = "")
        case failure
        /// Lines that arrive one at a time with a pause between them (a slow stream).
        case paced([String], every: Duration)
    }

    private struct State {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }

    private let state: Mutex<State>
    private let fallback: (@Sendable (Int) -> Reply)?

    public init(_ replies: [Reply], then fallback: (@Sendable (Int) -> Reply)? = nil) {
        state = Mutex(State(replies: replies))
        self.fallback = fallback
    }

    public var requests: [URLRequest] { state.withLock { $0.requests } }
    public var bodies: [JSONValue] { requests.compactMap { $0.httpBody.flatMap { try? JSONValue.parse($0) } } }

    public func open(_ request: URLRequest) async throws -> AITransportResponse {
        let (reply, count): (Reply?, Int) = state.withLock {
            $0.requests.append(request)
            return ($0.replies.isEmpty ? nil : $0.replies.removeFirst(), $0.requests.count)
        }
        switch reply ?? fallback?(count) {
        case .stream(let lines):
            return AITransportResponse(status: 200, lines: AsyncThrowingStream { c in lines.forEach { c.yield($0) }; c.finish() })
        case .paced(let lines, let every):
            return AITransportResponse(status: 200, lines: AsyncThrowingStream { c in
                let task = Task {
                    for line in lines {
                        try? await Task.sleep(for: every)
                        if Task.isCancelled { break }
                        c.yield(line)
                    }
                    c.finish()
                }
                c.onTermination = { _ in task.cancel() }
            })
        case .status(let code, let headers, let body):
            return AITransportResponse(status: code, headers: headers, lines: AsyncThrowingStream { c in c.yield(body); c.finish() })
        case .failure, .none:
            throw URLError(.notConnectedToInternet)
        }
    }
}
