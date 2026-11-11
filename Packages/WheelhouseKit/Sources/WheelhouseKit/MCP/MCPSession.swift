import Foundation
import Synchronization

/// One tool as `tools/list` returns it.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var outputSchema: JSONValue?
    public init(name: String, description: String, inputSchema: JSONValue, outputSchema: JSONValue? = nil) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.outputSchema = outputSchema
    }
}

public struct MCPResource: Sendable, Equatable {
    public var uri: String
    public var name: String
    public var description: String
    public init(uri: String, name: String, description: String) {
        self.uri = uri
        self.name = name
        self.description = description
    }
}

/// What a tool call returns: the text a model reads, the same data as structured content, and the error flag.
public struct MCPToolResult: Sendable, Equatable {
    public var text: String
    public var structured: JSONValue?
    public var isError: Bool
    public init(text: String, structured: JSONValue? = nil, isError: Bool = false) {
        self.text = text
        self.structured = structured
        self.isError = isError
    }
}

/// What a handler may do while a call is running.
public struct MCPCallContext: Sendable {
    /// Sends `notifications/progress` when the client asked for progress (it does nothing otherwise). Long waits call it so a
    /// client's request timeout can reset.
    public var progress: @Sendable (String) -> Void
    public init(progress: @escaping @Sendable (String) -> Void = { _ in }) { self.progress = progress }
}

/// The application side of one MCP session: identity, policy and the tools themselves.
public protocol MCPHandler: Sendable {
    var instructions: String { get }
    /// Called once, after `initialize` has been answered. Approval of an unknown client happens here, in the background.
    func didInitialize(clientName: String?, clientVersion: String?) async
    func listTools() async -> [MCPTool]
    func callTool(name: String, arguments: JSONValue, context: MCPCallContext) async -> MCPToolResult
    func listResources() async -> [MCPResource]
    /// The JSON text of a resource, or nil when it does not exist for this client.
    func readResource(uri: String) async -> String?
}

/// The MCP protocol core for one connection (ARCHITECTURE-MAC section 10.1): JSON-RPC 2.0, `initialize`, `tools/*`,
/// `resources/*`, `ping`, cancellation and `notifications/tools/list_changed`. It knows nothing about sockets: bytes come in
/// through ``receive(_:)`` and go out through the `send` closure.
public final class MCPSession: Sendable {
    public static let supportedVersions = ["2025-11-25", "2025-06-18"]
    public static let serverName = "wheelhouse"

    private struct State {
        var initialized = false
        var closed = false
        var calls: [String: Task<Void, Never>] = [:]
        /// Calls that were started and not yet answered or cancelled. Only a call still in here may send its response.
        var active: Set<String> = []
        var progress = 0
    }

    private let handler: any MCPHandler
    private let limiter: BeaconLimiter
    private let send: @Sendable (Data) -> Void
    private let serverVersion: String
    private let state = Mutex(State())

    public init(handler: any MCPHandler, limiter: BeaconLimiter, serverVersion: String = "1.0", send: @escaping @Sendable (Data) -> Void) {
        self.handler = handler
        self.limiter = limiter
        self.serverVersion = serverVersion
        self.send = send
    }

    public var isClosed: Bool { state.withLock { $0.closed } }

    /// Cancels every running call. Nothing is sent afterwards.
    public func close() {
        let tasks = state.withLock { s -> [Task<Void, Never>] in
            s.closed = true
            s.active = []
            defer { s.calls = [:] }
            return Array(s.calls.values)
        }
        tasks.forEach { $0.cancel() }
    }

    /// Tells the client its tool list changed (a scope change, or approval).
    public func notifyToolsListChanged() {
        guard state.withLock({ $0.initialized && !$0.closed }) else { return }
        emit(.notification(method: "notifications/tools/list_changed", params: .null))
    }

    private func emit(_ message: JSONRPCMessage) {
        guard !isClosed else { return }
        send(message.encoded())
    }

    /// Handles one message. Returns at once: tool calls run as tasks so cancellation and other calls keep flowing.
    public func receive(_ data: Data) {
        let message: JSONRPCMessage
        do { message = try JSONRPCMessage.parse(data) } catch {
            emit(.failure(id: .null, code: JSONRPCMessage.parseErrorCode, message: "Invalid JSON-RPC message."))
            return
        }
        switch message {
        case .request(let id, let method, let params): handle(id: id, method: method, params: params)
        case .notification(let method, let params): handle(notification: method, params: params)
        case .response, .failure: break   // the server sends no requests
        }
    }

    private func handle(notification method: String, params: JSONValue) {
        switch method {
        case "notifications/cancelled":
            guard let key = params["requestId"].map(Self.key) else { return }
            let task = state.withLock { s -> Task<Void, Never>? in
                s.active.remove(key)
                defer { s.calls[key] = nil }
                return s.calls[key]
            }
            task?.cancel()
        default: break   // notifications/initialized and anything unknown
        }
    }

    private static func key(_ id: JSONValue) -> String { id.jsonString() }

    private func handle(id: JSONValue, method: String, params: JSONValue) {
        if method == "initialize" { return initialize(id: id, params: params) }
        if method == "ping" { return emit(.response(id: id, result: [:])) }
        guard state.withLock({ $0.initialized }) else {
            return emit(.failure(id: id, code: JSONRPCMessage.notInitializedCode, message: "Send initialize first."))
        }
        switch method {
        case "tools/list":
            Task { [handler] in
                let tools = await handler.listTools().map(Self.encode)
                self.emit(.response(id: id, result: ["tools": .array(tools)]))
            }
        case "tools/call": startCall(id: id, params: params)
        case "resources/list":
            Task { [handler] in
                let items = await handler.listResources().map { r -> JSONValue in
                    ["uri": .string(r.uri), "name": .string(r.name), "description": .string(r.description), "mimeType": "application/json"]
                }
                self.emit(.response(id: id, result: ["resources": .array(items)]))
            }
        case "resources/read":
            guard let uri = params["uri"]?.stringValue else { return emit(.failure(id: id, code: JSONRPCMessage.invalidParamsCode, message: "uri is required.")) }
            Task { [handler] in
                guard let text = await handler.readResource(uri: uri) else {
                    return self.emit(.failure(id: id, code: -32002, message: "Resource not found."))
                }
                self.emit(.response(id: id, result: ["contents": [["uri": .string(uri), "mimeType": "application/json", "text": .string(text)]]]))
            }
        default:
            emit(.failure(id: id, code: JSONRPCMessage.methodNotFoundCode, message: "Method not found: \(method)"))
        }
    }

    private func initialize(id: JSONValue, params: JSONValue) {
        let asked = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedVersions.contains(asked) ? asked : Self.supportedVersions[0]
        let first = state.withLock { s -> Bool in
            defer { s.initialized = true }
            return !s.initialized
        }
        let result: JSONValue = [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": true], "resources": [:]],
            "serverInfo": ["name": .string(Self.serverName), "version": .string(serverVersion)],
            "instructions": .string(handler.instructions),
        ]
        emit(.response(id: id, result: result))
        guard first else { return }
        let name = params.value(at: "clientInfo.name")?.stringValue
        let clientVersion = params.value(at: "clientInfo.version")?.stringValue
        Task { [handler] in await handler.didInitialize(clientName: name, clientVersion: clientVersion) }
    }

    private func startCall(id: JSONValue, params: JSONValue) {
        guard let name = params["name"]?.stringValue else {
            return emit(.failure(id: id, code: JSONRPCMessage.invalidParamsCode, message: "name is required."))
        }
        if let refusal = limiter.begin() {
            return emit(.response(id: id, result: Self.encode(MCPToolResult(
                text: "{\"error\":\"\(refusal.rawValue)\"}", structured: ["error": .string(refusal.rawValue)], isError: true))))
        }
        let key = Self.key(id)
        let progressToken = params.value(at: "_meta.progressToken")
        let send = self.send
        let context = MCPCallContext(progress: { [weak self] text in
            guard let progressToken, let self, !self.isClosed else { return }
            let n = self.state.withLock { s -> Int in
                s.progress += 1
                return s.progress
            }
            send(JSONRPCMessage.notification(method: "notifications/progress", params: [
                "progressToken": progressToken, "progress": .int(n), "message": .string(text),
            ]).encoded())
        })
        let arguments = params["arguments"] ?? [:]
        let accepted = state.withLock { s -> Bool in
            if s.closed { return false }
            s.active.insert(key)
            return true
        }
        guard accepted else { return limiter.finish() }
        let task = Task { [handler, limiter] in
            let result = await handler.callTool(name: name, arguments: arguments, context: context)
            limiter.finish()
            let answer = self.state.withLock { s -> Bool in
                s.calls[key] = nil
                return s.active.remove(key) != nil
            }
            // A cancelled call gets no response (the client asked for that).
            if answer { self.emit(.response(id: id, result: Self.encode(result))) }
        }
        let stillWanted = state.withLock { s -> Bool in
            guard s.active.contains(key) else { return false }
            s.calls[key] = task
            return true
        }
        if !stillWanted { task.cancel() }
    }

    static func encode(_ tool: MCPTool) -> JSONValue {
        var o: JSONValue = ["name": .string(tool.name), "description": .string(tool.description), "inputSchema": tool.inputSchema]
        if let output = tool.outputSchema { o["outputSchema"] = output }
        return o
    }

    static func encode(_ result: MCPToolResult) -> JSONValue {
        var o: JSONValue = ["content": [["type": "text", "text": .string(result.text)]], "isError": .bool(result.isError)]
        if let structured = result.structured { o["structuredContent"] = structured }
        return o
    }
}
