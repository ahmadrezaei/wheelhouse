#if os(macOS)
import Foundation
import WheelhouseKit

/// A request Gangway refuses before any policy: HTTP status and a reason that kubectl can print.
public struct GangwayRejection: Error, Equatable, Sendable {
    public var status: Int
    public var reason: String
    public init(status: Int, reason: String) {
        self.status = status
        self.reason = reason
    }
}

/// The parsed shape of an API path, following `RequestInfoFactory.NewRequestInfo` of the API server.
public struct APIPathShape: Equatable, Sendable {
    public var isResourcePath = false
    public var group = ""
    public var version = ""
    public var namespace: String?
    public var resource = ""
    public var name: String?
    public var subresource: String?
    /// `proxy` or `watch` from the legacy `/api/v1/proxy/...` and `/api/v1/watch/...` forms.
    public var legacyVerb: String?
    /// Every segment, percent-escapes untouched.
    public var segments: [String] = []
    /// Index in `segments` of the `proxy` subresource or legacy verb, when there is one.
    public var proxyIndex: Int?
}

/// Pure request classification (ARCHITECTURE-MAC section 3.6, step 3). Table-tested in `GangwayClassifierTests`.
public enum RequestClassifier {
    public static let maxDeleteBody = 64 * 1024

    static let reviewPaths: Set<String> = [
        "/apis/authorization.k8s.io/v1/selfsubjectaccessreviews",
        "/apis/authorization.k8s.io/v1/selfsubjectrulesreviews",
        "/apis/authentication.k8s.io/v1/selfsubjectreviews",
        "/apis/authentication.k8s.io/v1/tokenreviews",
    ]

    // MARK: Canonical path

    private static let plainSegment: Set<UInt8> = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:~@-".utf8)

    /// The segments of a canonical raw path, or a 400. Works on the raw path, before any decoding.
    public static func canonicalSegments(of rawPath: String) throws -> [String] {
        func bad(_ why: String) -> GangwayRejection { GangwayRejection(status: 400, reason: "Wheelhouse: refused a non-canonical request path (\(why))") }
        guard rawPath.hasPrefix("/") else { throw bad("not absolute") }
        if rawPath.contains("\\") { throw bad("backslash") }
        if rawPath.contains("//") { throw bad("empty segment") }
        let lower = rawPath.lowercased()
        for forbidden in ["%2f", "%5c", "%2e", "%00"] where lower.contains(forbidden) { throw bad("encoded \(forbidden)") }
        var segments = rawPath.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if segments.last == "" { segments.removeLast() }       // one trailing slash is allowed
        // Escapes are allowed only after the segment the API server's own rules identify as the `proxy` subresource (or legacy verb). A
        // Service or namespace that is merely NAMED proxy does not relax anything: `services/proxy/%70roxy` is refused.
        let strictThrough = shape(of: segments).proxyIndex ?? (segments.count - 1)
        for (index, segment) in segments.enumerated() {
            if segment == "." || segment == ".." { throw bad("dot segment") }
            if index <= strictThrough {
                guard !segment.isEmpty, segment.utf8.allSatisfy({ plainSegment.contains($0) }) else { throw bad("unexpected character") }
            } else if segment.isEmpty {
                throw bad("empty segment")
            }
        }
        return segments
    }

    // MARK: Path shape (port of RequestInfoFactory)

    public static func shape(of segments: [String]) -> APIPathShape {
        var out = APIPathShape(segments: segments)
        guard segments.count >= 3, segments[0] == "api" || segments[0] == "apis" else { return out }
        var offset = 1
        if segments[0] == "apis" {
            out.group = segments[1]
            offset = 2
        }
        guard offset < segments.count else { return out }
        out.version = segments[offset]
        offset += 1
        out.isResourcePath = true
        if offset + 1 < segments.count, segments[offset] == "proxy" || segments[offset] == "watch" {
            out.legacyVerb = segments[offset]
            if segments[offset] == "proxy" { out.proxyIndex = offset }
            offset += 1
        }
        guard offset < segments.count else { return out }
        if segments[offset] == "namespaces", offset + 1 < segments.count {
            out.namespace = segments[offset + 1]
            if offset + 2 < segments.count, !["status", "finalize"].contains(segments[offset + 2]) { offset += 2 }
        }
        out.resource = segments[offset]
        if offset + 1 < segments.count { out.name = segments[offset + 1] }
        if offset + 2 < segments.count {
            out.subresource = segments[offset + 2]
            if segments[offset + 2] == "proxy" { out.proxyIndex = offset + 2 }
        }
        return out
    }

    // MARK: Query (Go's url.ParseQuery)

    /// Splits on `&` only; `;` anywhere, or an invalid percent escape, is an error; `+` decodes to a space. Keys are unescaped.
    public static func parseQuery(_ raw: String?) throws -> [(key: String, value: String)] {
        guard let raw, !raw.isEmpty else { return [] }
        if raw.contains(";") { throw GangwayRejection(status: 400, reason: "Wheelhouse: invalid query string (semicolon)") }
        var pairs: [(String, String)] = []
        for part in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try unescapeQuery(String(kv[0]))
            let value = kv.count > 1 ? try unescapeQuery(String(kv[1])) : ""
            pairs.append((key, value))
        }
        return pairs
    }

    static func unescapeQuery(_ s: String) throws -> String {
        var bytes: [UInt8] = []
        let input = Array(s.utf8)
        var i = 0
        while i < input.count {
            switch input[i] {
            case 0x25:
                guard i + 2 < input.count,
                      let h = hexValue(input[i + 1]), let l = hexValue(input[i + 2]) else {
                    throw GangwayRejection(status: 400, reason: "Wheelhouse: invalid percent escape in the query string")
                }
                bytes.append(UInt8(h << 4 | l))
                i += 3
            case 0x2B:
                bytes.append(0x20)
                i += 1
            default:
                bytes.append(input[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30...0x39: Int(b) - 0x30
        case 0x41...0x46: Int(b) - 0x41 + 10
        case 0x61...0x66: Int(b) - 0x61 + 10
        default: nil
        }
    }

    // MARK: Classification

    /// The stages `classify` runs, exposed so the connection knows whether a DELETE or eviction body must be buffered first.
    public struct Analysis: Sendable {
        public var shape: APIPathShape
        public var query: [(key: String, value: String)]
        public var canonicalPath: String
        public var method: String
        public var impersonation: [ImpersonationHeader]
        /// A preliminary class that does not depend on a body, or nil when the body decides dry-run versus mutation.
        public var fixed: GangwayClass?
        public var needsBody: Bool { fixed == nil }
        public var isEviction: Bool
    }

    public static func analyze(method: String, rawPath: String, rawQuery: String?, headers: [HTTPRequestHead.Header]) throws -> Analysis {
        let segments = try canonicalSegments(of: rawPath)
        let query = try parseQuery(rawQuery)
        let shape = shape(of: segments)
        let impersonation = headers.filter { $0.name.lowercased().hasPrefix("impersonate-") }.map { ImpersonationHeader(name: $0.name, value: $0.value) }
        let canonical = "/" + segments.joined(separator: "/")
        var analysis = Analysis(shape: shape, query: query, canonicalPath: canonical, method: method, impersonation: impersonation, fixed: nil, isEviction: false)

        // 1. stream
        let upgrade = headers.contains { $0.name.lowercased() == "upgrade" }
            || headers.contains { $0.name.lowercased() == "connection" && $0.value.lowercased().split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "upgrade" } }
        let sub = shape.subresource
        if upgrade || sub == "exec" || sub == "attach" || sub == "portforward" {
            let interactive = isTrue(query, "tty") && isTrue(query, "stdin")
            let kind: GangwayStreamKind
            switch sub {
            case "exec": kind = .exec(interactive: interactive)
            case "attach": kind = .attach(interactive: interactive)
            case "portforward": kind = .portForward
            default: kind = .otherUpgrade
            }
            analysis.fixed = .stream(kind)
            return analysis
        }
        // 2. proxy
        if sub == "proxy" || shape.legacyVerb == "proxy" {
            analysis.fixed = .proxy(method: method)
            return analysis
        }
        // 3. by method
        switch method {
        case "GET", "HEAD", "OPTIONS":
            analysis.fixed = .read
        case "POST" where reviewPaths.contains(canonical):
            analysis.fixed = .review
        case "POST" where sub == "eviction" && shape.resource == "pods":
            analysis.isEviction = true
        case "POST", "PUT", "PATCH":
            let values = query.filter { $0.key == "dryRun" }
            analysis.fixed = values.count == 1 && values[0].value == "All" ? .dryRun : .mutation
        case "DELETE":
            break
        default:
            analysis.fixed = .mutation
        }
        return analysis
    }

    private static func isTrue(_ query: [(key: String, value: String)], _ key: String) -> Bool {
        let values = query.filter { $0.key == key }
        return values.count == 1 && values[0].value == "true"
    }

    /// The whole classification. `body` is only consulted for DELETE (single or collection) and pod eviction.
    public static func classify(method: String, rawPath: String, rawQuery: String?, headers: [HTTPRequestHead.Header], body: Data?) throws -> GangwayRequestClass {
        let analysis = try analyze(method: method, rawPath: rawPath, rawQuery: rawQuery, headers: headers)
        return finish(analysis, headers: headers, body: body)
    }

    public static func finish(_ analysis: Analysis, headers: [HTTPRequestHead.Header], body: Data?) -> GangwayRequestClass {
        if let fixed = analysis.fixed { return GangwayRequestClass(kind: fixed, impersonation: analysis.impersonation) }
        let isDryRun = bodyIsDryRun(body, headers: headers, eviction: analysis.isEviction)
        return GangwayRequestClass(kind: isDryRun ? .dryRun : .mutation, impersonation: analysis.impersonation)
    }

    /// True only for a JSON body whose `DeleteOptions` (for an eviction, its `deleteOptions`) says `dryRun: ["All"]`, with Go's duplicate-key
    /// and case rules applied so that no other reading of the same bytes could be a real delete.
    static func bodyIsDryRun(_ body: Data?, headers: [HTTPRequestHead.Header], eviction: Bool) -> Bool {
        guard let body, !body.isEmpty, body.count <= maxDeleteBody else { return false }
        if headers.contains(where: { $0.name.lowercased() == "content-encoding" }) { return false }
        guard let type = headers.first(where: { $0.name.lowercased() == "content-type" })?.value else { return false }
        let media = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard media == "application/json" else { return false }
        guard case .object(var members)? = StrictJSON.parse(body) else { return false }
        if eviction {
            let matches = members.filter { $0.key == "deleteOptions" }
            guard matches.count == 1, members.allSatisfy({ $0.key.lowercased() != "deleteoptions" || $0.key == "deleteOptions" }),
                  case .object(let inner) = matches[0].value else { return false }
            members = inner
        }
        guard members.filter({ $0.key.lowercased() == "dryrun" }).count == 1,
              let entry = members.first(where: { $0.key == "dryRun" }),
              case .array(let items) = entry.value, items.count == 1, case .string("All") = items[0] else { return false }
        // Any duplicate key at this level means the last one could win.
        let keys = members.map(\.key)
        return Set(keys).count == keys.count
    }
}

/// A small strict JSON reader that keeps object members in order, duplicates included.
enum StrictJSON {
    indirect enum Value {
        case object([(key: String, value: Value)])
        case array([Value])
        case string(String)
        case other
    }

    static func parse(_ data: Data) -> Value? {
        var parser = Parser(bytes: Array(data))
        parser.skipWhitespace()
        guard let value = parser.value(depth: 0) else { return nil }
        parser.skipWhitespace()
        return parser.index == parser.bytes.count ? value : nil
    }

    private struct Parser {
        var bytes: [UInt8]
        var index = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWhitespace() {
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
        }

        mutating func value(depth: Int) -> Value? {
            guard depth < 64, index < bytes.count else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "{"):
                index += 1
                var members: [(key: String, value: Value)] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                while true {
                    skipWhitespace()
                    guard let key = string() else { return nil }
                    skipWhitespace()
                    guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return nil }
                    index += 1
                    skipWhitespace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    members.append((key, v))
                    skipWhitespace()
                    guard index < bytes.count else { return nil }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                    return nil
                }
            case UInt8(ascii: "["):
                index += 1
                var items: [Value] = []
                skipWhitespace()
                if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    guard let v = value(depth: depth + 1) else { return nil }
                    items.append(v)
                    skipWhitespace()
                    guard index < bytes.count else { return nil }
                    if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
                    if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(items) }
                    return nil
                }
            case UInt8(ascii: "\""):
                return string().map(Value.string)
            default:
                // number, true, false, null: skip the literal characters
                let start = index
                while index < bytes.count, ![0x2C, 0x5D, 0x7D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
                return index > start ? .other : nil
            }
        }

        /// A JSON string with its escapes decoded (`\uXXXX` included).
        mutating func string() -> String? {
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { return nil }
            index += 1
            var out: [UInt8] = []
            var pendingHigh: UInt32?
            func appendScalar(_ v: UInt32, into out: inout [UInt8]) {
                if let s = Unicode.Scalar(v) { out.append(contentsOf: Array(String(Character(s)).utf8)) } else { out.append(contentsOf: [0xEF, 0xBF, 0xBD]) }
            }
            while index < bytes.count {
                let b = bytes[index]
                index += 1
                if b == UInt8(ascii: "\"") {
                    if pendingHigh != nil { out.append(contentsOf: [0xEF, 0xBF, 0xBD]) }
                    return String(decoding: out, as: UTF8.self)
                }
                if b < 0x20 { return nil }
                guard b == UInt8(ascii: "\\") else {
                    if pendingHigh != nil { out.append(contentsOf: [0xEF, 0xBF, 0xBD]); pendingHigh = nil }
                    out.append(b)
                    continue
                }
                guard index < bytes.count else { return nil }
                let e = bytes[index]
                index += 1
                switch e {
                case UInt8(ascii: "u"):
                    guard index + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16) else { return nil }
                    index += 4
                    if let high = pendingHigh {
                        pendingHigh = nil
                        if (0xDC00...0xDFFF).contains(v) { appendScalar(0x10000 + ((high - 0xD800) << 10) + (v - 0xDC00), into: &out); continue }
                        out.append(contentsOf: [0xEF, 0xBF, 0xBD])
                    }
                    if (0xD800...0xDBFF).contains(v) { pendingHigh = v } else { appendScalar(v, into: &out) }
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(e)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                default: return nil
                }
            }
            return nil
        }
    }
}
#endif
