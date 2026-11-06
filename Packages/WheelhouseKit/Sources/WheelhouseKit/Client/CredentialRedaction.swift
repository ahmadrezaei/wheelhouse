import Foundation

// Credential-bearing types must never reveal their contents through `print`, `dump`, `String(describing:)`,
// `po` or reflection-based loggers. Presence is shown; values are not.

extension ClusterSecrets: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "ClusterSecrets(token: \(Self.mark(token)), clientCertificate: \(Self.mark(clientCertificatePEM)), "
            + "clientKey: \(Self.mark(clientKeyPEM)), ca: \(Self.mark(caPEM)))"
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
    private static func mark(_ value: String?) -> String { value == nil ? "nil" : "<redacted>" }
}

extension KubeconfigAuth: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        switch self {
        case .token: "token(<redacted>)"
        case .clientCertificate: "clientCertificate(<redacted>)"
        case .basic(let username): "basic(username: \(username))"
        case .exec(let command, let args): "exec(command: \(command), args: \(args))"
        case .authProvider(let name): "authProvider(\(name))"
        case .missingFiles(let files): "missingFiles(\(files))"
        case .none: "none"
        }
    }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
}

extension ClusterDraft: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String { "ClusterDraft(id: \(id), name: \(name), server: \(serverText), auth: \(authKind.rawValue))" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
