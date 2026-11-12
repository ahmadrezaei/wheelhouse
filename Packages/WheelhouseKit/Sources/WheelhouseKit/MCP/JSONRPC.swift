import Foundation

/// One JSON-RPC 2.0 message, as the MCP stdio framing carries it (one JSON object per message).
public enum JSONRPCMessage: Sendable, Equatable {
    case request(id: JSONValue, method: String, params: JSONValue)
    case notification(method: String, params: JSONValue)
    case response(id: JSONValue, result: JSONValue)
    case failure(id: JSONValue, code: Int, message: String)

    public enum ParseError: Error, Equatable { case notJSON, notAnObject, invalid }

    public static let parseErrorCode = -32700
    public static let invalidRequestCode = -32600
    public static let methodNotFoundCode = -32601
    public static let invalidParamsCode = -32602
    public static let notInitializedCode = -32002

    public static func parse(_ data: Data) throws -> JSONRPCMessage {
        guard !JSONDepth.exceeds(data) else { throw ParseError.notJSON }
        guard let value = try? JSONValue.parse(data) else { throw ParseError.notJSON }
        guard case .object(let object) = value else { throw ParseError.notAnObject }
        guard object["jsonrpc"]?.stringValue == "2.0" else { throw ParseError.invalid }
        let params = object["params"] ?? .null
        if let method = object["method"]?.stringValue {
            if let id = object["id"] {
                guard id.stringValue != nil || id.intValue != nil else { throw ParseError.invalid }
                return .request(id: id, method: method, params: params)
            }
            return .notification(method: method, params: params)
        }
        guard let id = object["id"] else { throw ParseError.invalid }
        if let result = object["result"] { return .response(id: id, result: result) }
        if let error = object["error"], let code = error["code"]?.intValue {
            return .failure(id: id, code: code, message: error["message"]?.stringValue ?? "")
        }
        throw ParseError.invalid
    }

    public var json: JSONValue {
        switch self {
        case .request(let id, let method, let params):
            var o: JSONValue = ["jsonrpc": "2.0", "id": id, "method": .string(method)]
            if !params.isNull { o["params"] = params }
            return o
        case .notification(let method, let params):
            var o: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
            if !params.isNull { o["params"] = params }
            return o
        case .response(let id, let result):
            return ["jsonrpc": "2.0", "id": id, "result": result]
        case .failure(let id, let code, let message):
            return ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
        }
    }

    public func encoded() -> Data { (try? json.data()) ?? Data() }
}

/// A cheap byte scan that refuses deeply nested JSON before the recursive decoder sees it (a connection thread has a small stack, and
/// the data comes from a peer nobody has approved yet).
public enum JSONDepth {
    public static let limit = 64

    public static func exceeds(_ data: Data, limit: Int = limit) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false } else if byte == 0x5C { escaped = true } else if byte == 0x22 { inString = false }
                continue
            }
            switch byte {
            case 0x22: inString = true
            case 0x5B, 0x7B:
                depth += 1
                if depth > limit { return true }
            case 0x5D, 0x7D: depth = max(0, depth - 1)
            default: break
            }
        }
        return false
    }
}
