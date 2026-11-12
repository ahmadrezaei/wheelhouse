import Foundation

/// Turns the lines of a Messages API server-sent-event stream into events.
///
/// Every `data:` line of this API carries a JSON object with a `type`, so the parser reads the data lines only: `event:` names,
/// comments and the blank separators carry nothing the data does not say.
public enum SSEParser {
    /// The JSON of a `data:` line, or nil for any other line (and for `[DONE]`).
    public static func event(fromLine line: String) -> JSONValue? {
        guard line.hasPrefix("data:") else { return nil }
        var payload = line.dropFirst(5)
        if payload.first == " " { payload = payload.dropFirst() }
        guard payload != "[DONE]", let data = payload.data(using: .utf8) else { return nil }
        return try? JSONValue.parse(data)
    }
}

/// Builds the assistant message of one response from its events (ARCHITECTURE-MAC section 9.1):
/// `message_start`, `content_block_start/delta/stop` (`text_delta`, `thinking_delta`, `input_json_delta`, `signature_delta`),
/// `message_delta` (`stop_reason`, cumulative usage), `message_stop`, `ping` and `error`.
///
/// Blocks are kept as the raw JSON the API sent. With a server-side fallback the stream may carry a `fallback` block: thinking
/// and tool calls from before the last one belong to the model that declined and are dropped (a tool call from before it is never
/// run); the `fallback` block itself stays where it is, so the history is sent back as received.
public struct StreamAccumulator: Sendable {
    private var blocks: [Int: JSONValue] = [:]
    private var partialInput: [Int: String] = [:]
    private var invalid: Set<String> = []
    private var id: String?
    private var model: String?
    private var start = AIUsage()
    private var delta = AIUsage()
    private var iterations: [AIUsage] = []
    private var stopReason: String?
    private var stopDetails: JSONValue?
    public private(set) var isFinished = false

    public init() {}

    /// Feeds one event and returns what the view should show.
    public mutating func consume(_ event: JSONValue) throws -> [AIStreamUpdate] {
        switch event["type"]?.stringValue {
        case "message_start":
            let message = event["message"] ?? [:]
            id = message["id"]?.stringValue
            model = message["model"]?.stringValue
            start = AIUsage(json: message["usage"] ?? [:], model: model)
            delta = start
            return [.usage(start)]
        case "content_block_start":
            guard let index = event["index"]?.intValue, let block = event["content_block"] else { return [] }
            blocks[index] = block
            switch block["type"]?.stringValue {
            case "tool_use":
                guard let toolID = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return [] }
                partialInput[index] = ""
                return [.toolUseStarted(id: toolID, name: name)]
            case "fallback": return [.fallback]
            case "text":
                // A block may start with text already in it.
                if let text = block["text"]?.stringValue, !text.isEmpty { return [.text(text)] }
                return []
            default: return []
            }
        case "content_block_delta":
            guard let index = event["index"]?.intValue, let change = event["delta"], var block = blocks[index] else { return [] }
            switch change["type"]?.stringValue {
            case "text_delta":
                let text = change["text"]?.stringValue ?? ""
                block["text"] = .string((block["text"]?.stringValue ?? "") + text)
                blocks[index] = block
                return [.text(text)]
            case "thinking_delta":
                let text = change["thinking"]?.stringValue ?? ""
                block["thinking"] = .string((block["thinking"]?.stringValue ?? "") + text)
                blocks[index] = block
                return [.thinking(text)]
            case "signature_delta":
                block["signature"] = .string((block["signature"]?.stringValue ?? "") + (change["signature"]?.stringValue ?? ""))
                blocks[index] = block
                return []
            case "input_json_delta":
                partialInput[index, default: ""] += change["partial_json"]?.stringValue ?? ""
                return []
            default: return []
            }
        case "content_block_stop":
            guard let index = event["index"]?.intValue, var block = blocks[index], block["type"]?.stringValue == "tool_use" else { return [] }
            let text = partialInput[index] ?? ""
            partialInput[index] = nil
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                block["input"] = block["input"] ?? [:]
            } else if let data = text.data(using: .utf8), let parsed = try? JSONValue.parse(data), parsed.objectValue != nil {
                block["input"] = parsed
            } else {
                // Eager input streaming means the server no longer validates: a truncated or malformed input is kept as {} and
                // answered with an error result instead of being run.
                block["input"] = [:]
                if let toolID = block["id"]?.stringValue { invalid.insert(toolID) }
            }
            blocks[index] = block
            return []
        case "message_delta":
            let change = event["delta"] ?? [:]
            if let reason = change["stop_reason"]?.stringValue { stopReason = reason }
            if let details = change["stop_details"], !details.isNull { stopDetails = details }
            if let usage = event["usage"] {
                delta.merge(usage)
                if let list = usage["iterations"]?.arrayValue {
                    iterations = list.map { AIUsage(json: $0, model: model) }
                }
                return [.usage(delta)]
            }
            return []
        case "message_stop":
            isFinished = true
            return []
        case "error":
            let error = event["error"] ?? [:]
            throw AIError.stream(type: error["type"]?.stringValue ?? "error", message: error["message"]?.stringValue ?? "The stream failed.")
        default:
            return []   // ping and event types a newer API adds
        }
    }

    /// The response so far. Call it after `message_stop`; after a failure it is the partial text for the view.
    public func response() -> AIResponse {
        var ordered = blocks.sorted { $0.key < $1.key }.map(\.value)
        if let last = ordered.lastIndex(where: { $0["type"]?.stringValue == "fallback" }) {
            let dropped: Set<String> = ["thinking", "redacted_thinking", "tool_use"]
            ordered = ordered.enumerated().filter { $0.offset >= last || !dropped.contains($0.element["type"]?.stringValue ?? "") }.map(\.element)
        }
        let kept = Set(ordered.compactMap { $0["id"]?.stringValue })
        return AIResponse(id: id, model: model, message: AIMessage(role: .assistant, content: ordered), stopReason: stopReason,
                          stopDetails: stopDetails, usage: iterations.isEmpty ? [delta] : iterations, invalidToolInputs: invalid.intersection(kept))
    }

    /// Only the text blocks, for a stream that was stopped or failed midway.
    public func partialText() -> String {
        blocks.sorted { $0.key < $1.key }.map(\.value).filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
    }
}
