#if os(macOS)
import CryptoKit
import Foundation
import WheelhouseKit

/// A digest of a cluster's credentials, so that replacing them ends the sessions that used the old ones. Never the credentials.
public enum CredentialDigest {
    /// Encoded with sorted keys (the same secrets always give the same digest). When the token comes from a file (`tokenFile`), the file's
    /// CONTENT is left out and its PATH is used: a rotating token file is the normal way to renew a token and must not end sessions.
    public static func make(_ secrets: ClusterSecrets, tokenFilePath: String? = nil) -> String? {
        var copy = secrets
        if tokenFilePath != nil { copy.token = nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var data = try? encoder.encode(copy) else { return nil }
        if let tokenFilePath { data.append(Data("\ntokenFile:\(tokenFilePath)".utf8)) }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
