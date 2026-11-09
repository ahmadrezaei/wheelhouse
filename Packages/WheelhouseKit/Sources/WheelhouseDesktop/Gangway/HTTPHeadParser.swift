#if os(macOS)
import Foundation

/// A parsed HTTP/1.1 request head. Gangway never forwards the bytes it received: it writes a fresh head from these fields.
public struct HTTPRequestHead: Sendable, Equatable {
    public var method: String
    /// The request-target, origin-form (`/path?query`).
    public var target: String
    public var headers: [Header]

    public struct Header: Sendable, Equatable {
        public var name: String
        public var value: String
        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    public init(method: String, target: String, headers: [Header]) {
        self.method = method
        self.target = target
        self.headers = headers
    }

    public func values(_ name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }
    public func value(_ name: String) -> String? { values(name).first }

    /// The raw path (before `?`) and raw query (after it, nil without `?`).
    public var rawPath: String { target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target }
    public var rawQuery: String? {
        guard let i = target.firstIndex(of: "?") else { return nil }
        return String(target[target.index(after: i)...])
    }

    /// `Connection` tokens, lowercased.
    public var connectionTokens: [String] {
        values("Connection").flatMap { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() } }
    }
    /// An `Upgrade` header of any value, or a `Connection` token `upgrade`.
    public var isUpgrade: Bool { !values("Upgrade").isEmpty || connectionTokens.contains("upgrade") }
}

public enum HTTPFraming: Sendable, Equatable {
    case none
    case length(Int)
    case chunked
}

/// A malformed request. Every case is answered with 400 and the connection is closed.
public struct HTTPParseError: Error, Equatable, Sendable, CustomStringConvertible {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var description: String { reason }
}

/// Strict HTTP/1.1 request-head parser (ARCHITECTURE-MAC section 3.6, step 1). Stricter than the API server on purpose: anything
/// ambiguous is refused, so the head Gangway classifies is the head the API server would have seen.
public enum HTTPHeadParser {
    public static let maxHead = 64 * 1024
    public static let maxBodyLength = 1 << 40

    /// Returns nil when the head is not complete yet. `consumed` includes the blank line.
    public static func parse(_ buffer: Data) throws -> (head: HTTPRequestHead, consumed: Int)? {
        let terminator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: terminator) else {
            if buffer.count > maxHead { throw HTTPParseError("request head too large") }
            // A bare LF before the terminator can never become valid.
            if hasBareLF(buffer) { throw HTTPParseError("bare line feed in request head") }
            return nil
        }
        let consumed = end.upperBound - buffer.startIndex
        if consumed > maxHead { throw HTTPParseError("request head too large") }
        let headBytes = buffer[buffer.startIndex..<end.lowerBound]
        if hasBareLF(Data(headBytes)) { throw HTTPParseError("bare line feed in request head") }
        guard let text = String(data: headBytes, encoding: .utf8), text.utf8.allSatisfy({ $0 != 0 }) else {
            throw HTTPParseError("invalid bytes in request head")
        }
        var lines = text.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst()
        let (method, target) = try parseRequestLine(requestLine)
        var headers: [HTTPRequestHead.Header] = []
        for line in lines {
            guard let first = line.utf8.first else { throw HTTPParseError("empty header line") }
            if first == 0x20 || first == 0x09 { throw HTTPParseError("obsolete line folding") }
            guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError("header without a colon") }
            let name = String(line[line.startIndex..<colon])
            guard isToken(name) else { throw HTTPParseError("invalid header name") }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            guard value.utf8.allSatisfy({ $0 == 0x09 || ($0 >= 0x20 && $0 != 0x7F) }) else { throw HTTPParseError("control character in a header value") }
            headers.append(.init(name: name, value: value))
        }
        let head = HTTPRequestHead(method: method, target: target, headers: headers)
        try validate(head)
        return (head, consumed)
    }

    private static func hasBareLF(_ data: Data) -> Bool {
        var previous: UInt8 = 0
        for byte in data {
            if byte == 0x0A, previous != 0x0D { return true }
            previous = byte
        }
        return false
    }

    private static func parseRequestLine(_ line: String) throws -> (String, String) {
        let parts = line.components(separatedBy: " ")
        guard parts.count == 3 else { throw HTTPParseError("malformed request line") }
        let method = parts[0], target = parts[1]
        guard !method.isEmpty, method.utf8.allSatisfy({ $0 >= 0x41 && $0 <= 0x5A }) else { throw HTTPParseError("invalid method") }
        guard parts[2] == "HTTP/1.1" else { throw HTTPParseError("only HTTP/1.1 is supported") }
        guard target.hasPrefix("/") else { throw HTTPParseError("request-target is not origin-form") }
        guard target.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }), !target.contains("#") else {
            throw HTTPParseError("invalid bytes in the request-target")
        }
        return (method, target)
    }

    static func isToken(_ s: String) -> Bool {
        let allowed = Set("!#$%&'*+-.^_`|~".utf8)
        return !s.isEmpty && s.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || allowed.contains($0) }
    }

    private static let singletons = ["host", "authorization", "content-length", "transfer-encoding", "upgrade", "content-type", "expect"]

    private static func validate(_ head: HTTPRequestHead) throws {
        for name in singletons where head.values(name).count > 1 { throw HTTPParseError("duplicate \(name) header") }
        if head.values("Host").count != 1 { throw HTTPParseError("exactly one Host header is required") }
        for token in head.connectionTokens where !["keep-alive", "close", "upgrade"].contains(token) {
            throw HTTPParseError("unsupported Connection token")
        }
        _ = try framing(of: head)
    }

    /// The body framing. Both `Content-Length` and `Transfer-Encoding`, a non-numeric length, or any encoding but exactly `chunked` is
    /// an error.
    public static func framing(of head: HTTPRequestHead) throws -> HTTPFraming {
        let length = head.values("Content-Length"), encoding = head.values("Transfer-Encoding")
        if !length.isEmpty, !encoding.isEmpty { throw HTTPParseError("both Content-Length and Transfer-Encoding") }
        if let te = encoding.first {
            guard te.lowercased() == "chunked" else { throw HTTPParseError("unsupported Transfer-Encoding") }
            return .chunked
        }
        if let cl = length.first {
            guard !cl.isEmpty, cl.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), cl.count <= 13, let n = Int(cl), n <= maxBodyLength else {
                throw HTTPParseError("invalid Content-Length")
            }
            return n == 0 ? .none : .length(n)
        }
        return .none
    }
}

/// Decodes a chunked request body and yields it re-encoded: chunk extensions are dropped, trailers are refused.
public struct ChunkedBodyReencoder: Sendable {
    private enum State: Sendable {
        case size(line: [UInt8])
        case data(remaining: Int)
        case dataEnd(seen: Int)
        case lastLine(seen: Int)
        case finished
    }
    private var state: State = .size(line: [])
    public static let maxSizeLine = 64
    private let decode: Bool
    /// `decode: true` yields the plain body bytes; otherwise each chunk is written again (extensions dropped) for forwarding.
    public init(decode: Bool = false) { self.decode = decode }

    public var isFinished: Bool { if case .finished = state { true } else { false } }

    /// Feeds bytes. Returns the re-encoded bytes to forward and how many input bytes were used (fewer than `input.count` only
    /// when the body finished: the rest belongs to a pipelined request, which the caller refuses).
    public mutating func feed(_ input: Data) throws -> (output: Data, used: Int) {
        var out = Data()
        var i = input.startIndex
        while i < input.endIndex {
            switch state {
            case .finished:
                return (out, i - input.startIndex)
            case .size(var line):
                let byte = input[i]
                i += 1
                if byte == 0x0A {
                    guard line.last == 0x0D else { throw HTTPParseError("bare line feed in a chunk header") }
                    line.removeLast()
                    let hexPart = line.prefix { $0 != 0x3B }            // drop chunk extensions
                    guard !hexPart.isEmpty, hexPart.count <= 8,
                          hexPart.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x46) || ($0 >= 0x61 && $0 <= 0x66) }),
                          let size = Int(String(decoding: hexPart, as: UTF8.self), radix: 16) else { throw HTTPParseError("invalid chunk size") }
                    if size == 0 { state = .lastLine(seen: 0) } else {
                        if !decode { out.append(Data("\(String(size, radix: 16))\r\n".utf8)) }
                        state = .data(remaining: size)
                    }
                } else {
                    line.append(byte)
                    if line.count > Self.maxSizeLine { throw HTTPParseError("chunk header too long") }
                    state = .size(line: line)
                }
            case .data(let remaining):
                let n = min(remaining, input.endIndex - i)
                out.append(input[i..<(i + n)])
                i += n
                state = remaining - n == 0 ? .dataEnd(seen: 0) : .data(remaining: remaining - n)
            case .dataEnd(let seen):
                let expected: UInt8 = seen == 0 ? 0x0D : 0x0A
                guard input[i] == expected else { throw HTTPParseError("chunk not terminated by CRLF") }
                i += 1
                if seen == 1 {
                    if !decode { out.append(Data("\r\n".utf8)) }
                    state = .size(line: [])
                } else { state = .dataEnd(seen: 1) }
            case .lastLine(let seen):
                // After the zero chunk only an empty line is allowed (no trailers).
                let expected: UInt8 = seen == 0 ? 0x0D : 0x0A
                guard input[i] == expected else { throw HTTPParseError("trailers are not allowed") }
                i += 1
                if seen == 1 {
                    if !decode { out.append(Data("0\r\n\r\n".utf8)) }
                    state = .finished
                } else { state = .lastLine(seen: 1) }
            }
        }
        return (out, input.count)
    }
}
#endif
