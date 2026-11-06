import Foundation

/// Errors surfaced by every ``KubeClientProtocol`` implementation.
public enum KubeError: Error, Sendable, Equatable {
    /// DNS / TCP / timeout failure. `cause` is a human-readable reason.
    case unreachable(cause: String)
    /// Server certificate could not be validated. `summary` describes the leaf certificate when known.
    case tlsUntrusted(summary: String?)
    case unauthorized(message: String?)
    case forbidden(verb: String?, resource: String?, namespace: String?, message: String)
    case notFound(message: String?)
    case conflict(message: String?)
    case invalid(message: String, causes: [Status.Cause])
    /// Cluster is flagged read-only; the request was never sent.
    case readOnly
    /// 410 Gone: resourceVersion too old, relist required.
    case gone
    case server(Status)
    case decoding(String)
    /// Feature not available on this client (e.g. exec in demo mode).
    case unsupported(String)
    case cancelled

    /// Builds the right error from an HTTP status and (optional) decoded `Status` body.
    public static func from(httpStatus code: Int, status: Status?, fallback: String? = nil) -> KubeError {
        let message = status?.message ?? fallback ?? HTTPURLResponse.localizedString(forStatusCode: code)
        switch code {
        case 401:
            return .unauthorized(message: message)
        case 403:
            let d = status?.details
            let resource = [d?.kind, d?.group.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: ".")
            let parsed = parseForbidden(message)
            return .forbidden(verb: parsed.verb, resource: parsed.resource ?? (resource.isEmpty ? nil : resource),
                              namespace: parsed.namespace, message: message)
        case 404:
            return .notFound(message: message)
        case 409:
            return .conflict(message: message)
        case 410:
            return .gone
        case 422:
            return .invalid(message: message, causes: status?.details?.causes ?? [])
        default:
            var s = status ?? Status(status: "Failure", message: message, code: code)
            if s.code == nil { s.code = code }
            return .server(s)
        }
    }

    /// Parses `pods is forbidden: User "x" cannot list resource "pods" in API group "" in the namespace "kube-system"`.
    static func parseForbidden(_ message: String) -> (verb: String?, resource: String?, namespace: String?) {
        let verb = message.range(of: "cannot ").flatMap { r -> String? in
            message[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        return (verb, capture(of: "resource \"", in: message), capture(of: "namespace \"", in: message))
    }

    private static func capture(of key: String, in s: String) -> String? {
        guard let r = s.range(of: key) else { return nil }
        return s[r.upperBound...].split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// Short single-line description suitable for banners.
    public var summary: String {
        switch self {
        case .unreachable(let cause): "Unreachable: \(cause)"
        case .tlsUntrusted: "The server certificate is not trusted"
        case .unauthorized: "Credentials were rejected (401)"
        case .forbidden(let verb, let resource, let ns, _):
            "Forbidden: cannot \(verb ?? "access") \(resource ?? "resource")\(ns.map { " in \($0)" } ?? "")"
        case .notFound: "Not found"
        case .conflict: "The object was modified by someone else"
        case .invalid(let m, _): "Invalid: \(m)"
        case .readOnly: "This cluster is read-only"
        case .gone: "Watch expired; reloading"
        case .server(let s): s.message ?? "Server error"
        case .decoding(let m): "Unexpected response: \(m)"
        case .unsupported(let m): m
        case .cancelled: "Cancelled"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .unreachable, .gone: true
        case .server(let s): (s.code ?? 500) >= 500
        default: false
        }
    }
}

extension KubeError: LocalizedError {
    public var errorDescription: String? { summary }
}

public extension Status {
    /// Decodes a metav1.Status body and maps it to an error; falls back to a plain message when the body isn't a Status.
    static func decodeError(code: Int, body: Data) -> KubeError {
        let status = try? KubeJSON.decoder.decode(Status.self, from: body)
        let usable = status?.kind == "Status" ? status : nil
        let fallback = usable == nil ? String(data: body.prefix(300), encoding: .utf8) : nil
        return KubeError.from(httpStatus: code, status: usable, fallback: fallback)
    }
}
