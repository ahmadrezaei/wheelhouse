import Foundation

/// Which model a conversation talks to and how hard it thinks (ARCHITECTURE-MAC section 9.1, owner decision 13).
///
/// The default is Opus 5.5 at effort medium. **Quick** is Sonnet 5.5 at effort low. The UI never calls it "Fast": that word belongs
/// to the API's fast mode, which Wheelhouse does not use. **Investigate** raises the effort of one send to high.
public struct AIModelChoice: Codable, Hashable, Sendable {
    public enum Effort: String, Codable, Sendable { case low, medium, high }

    public var model: String
    public var effort: Effort

    public init(model: String, effort: Effort) {
        self.model = model
        self.effort = effort
    }

    public static let standard = AIModelChoice(model: "claude-opus-5-5", effort: .medium)
    public static let quick = AIModelChoice(model: "claude-sonnet-5-5", effort: .low)

    /// The same model with effort high (one send, ⌥↩).
    public var investigating: AIModelChoice { AIModelChoice(model: model, effort: .high) }

    public var isQuick: Bool { model == Self.quick.model }
    public var label: String { isQuick ? "Quick" : "Opus 5.5" }
}

/// One message of the conversation. Content blocks are kept as the raw JSON the API sent or expects, so nothing a newer API adds
/// (a fallback block, a signature, a field this build does not know) is lost when the history is stored and sent back
/// unchanged. Thinking blocks must be returned exactly as received; editing them would invalidate the cache and the thinking.
public struct AIMessage: Codable, Hashable, Sendable {
    public enum Role: String, Codable, Sendable { case user, assistant, system }

    public var role: Role
    public var content: [JSONValue]

    public init(role: Role, content: [JSONValue]) {
        self.role = role
        self.content = content
    }

    public static func user(_ text: String) -> AIMessage { AIMessage(role: .user, content: [textBlock(text)]) }
    public static func system(_ text: String) -> AIMessage { AIMessage(role: .system, content: [textBlock(text)]) }
    public static func assistant(_ text: String) -> AIMessage { AIMessage(role: .assistant, content: [textBlock(text)]) }

    public static func textBlock(_ text: String) -> JSONValue { ["type": "text", "text": .string(text)] }

    public static func toolResult(id: String, text: String, isError: Bool) -> JSONValue {
        var block: JSONValue = ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text)]
        if isError { block["is_error"] = true }
        return block
    }

    /// The message as the request carries it. A mid-conversation system message has a plain string as its content.
    public var wire: JSONValue {
        switch role {
        case .system: ["role": "system", "content": .string(text)]
        case .user, .assistant: ["role": .string(role.rawValue), "content": .array(content)]
        }
    }

    /// The text blocks, joined.
    public var text: String {
        content.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined(separator: "\n")
    }

    public struct ToolUse: Sendable, Hashable {
        public var id: String
        public var name: String
        public var input: JSONValue
    }

    public var toolUses: [ToolUse] {
        content.compactMap { block in
            guard block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
            return ToolUse(id: id, name: name, input: block["input"] ?? [:])
        }
    }
}

/// Token counts of one response. `message_delta` usage is cumulative for the response, so a later value replaces an earlier one.
public struct AIUsage: Codable, Hashable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheCreationTokens = 0
    public var cacheReadTokens = 0
    /// The model that served this part, when the API says (a server-side fallback bills at the fallback model's rates).
    public var model: String?

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheCreationTokens: Int = 0, cacheReadTokens: Int = 0, model: String? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.model = model
    }

    public init(json: JSONValue, model: String? = nil) {
        inputTokens = json["input_tokens"]?.intValue ?? 0
        outputTokens = json["output_tokens"]?.intValue ?? 0
        cacheCreationTokens = json["cache_creation_input_tokens"]?.intValue ?? 0
        cacheReadTokens = json["cache_read_input_tokens"]?.intValue ?? 0
        self.model = json["model"]?.stringValue ?? model
    }

    /// Fields present in `json` replace the stored ones (usage in `message_delta` is cumulative).
    mutating func merge(_ json: JSONValue) {
        if let v = json["input_tokens"]?.intValue { inputTokens = v }
        if let v = json["output_tokens"]?.intValue { outputTokens = v }
        if let v = json["cache_creation_input_tokens"]?.intValue { cacheCreationTokens = v }
        if let v = json["cache_read_input_tokens"]?.intValue { cacheReadTokens = v }
    }

    public var totalInput: Int { inputTokens + cacheCreationTokens + cacheReadTokens }

    public static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(inputTokens: lhs.inputTokens + rhs.inputTokens, outputTokens: lhs.outputTokens + rhs.outputTokens,
                cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens, cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
                model: lhs.model ?? rhs.model)
    }
}

/// What a finished stream produced.
public struct AIResponse: Sendable {
    public var id: String?
    public var model: String?
    public var message: AIMessage
    public var stopReason: String?
    /// `stop_details` of a refusal (category and explanation), shown plainly.
    public var stopDetails: JSONValue?
    /// Usage to bill: one entry per attempt when the API reports `usage.iterations` (a server-side fallback), else a single entry.
    public var usage: [AIUsage]
    /// Ids of `tool_use` blocks whose streamed input was not valid JSON (the block is kept with an empty input).
    public var invalidToolInputs: Set<String>

    public var isRefusal: Bool { stopReason == "refusal" }
    public var totalUsage: AIUsage { usage.reduce(AIUsage(), +) }
    /// The usage of the last attempt, which is what the prompt cache check looks at.
    public var finalUsage: AIUsage { usage.last ?? AIUsage() }
}

/// A piece of a stream, for the view.
public enum AIStreamUpdate: Sendable, Equatable {
    case text(String)
    case thinking(String)
    case toolUseStarted(id: String, name: String)
    /// The API switched to a fallback model mid-stream; what was shown so far is dropped from the answer.
    case fallback
    /// Usage so far (cumulative). The session keeps the latest, so a stream that is stopped or fails is still charged.
    case usage(AIUsage)
}

/// Sorted-key, unescaped-slash JSON: the same value always encodes to the same bytes, which the prompt cache and "What was sent"
/// depend on (Swift dictionaries enumerate in a different order in every process).
public enum CanonicalJSON {
    public static func data(_ value: JSONValue) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)) ?? Data("null".utf8)
    }

    public static func string(_ value: JSONValue) -> String { String(decoding: data(value), as: UTF8.self) }
}
