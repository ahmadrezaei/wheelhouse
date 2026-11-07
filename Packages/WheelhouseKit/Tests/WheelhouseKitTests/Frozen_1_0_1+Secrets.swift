import Foundation

/// FROZEN COPY (continued) of the other synchronizable items exactly as shipped in 1.0.1 (iOS builds 1-5), copied from the
/// 1.0.1 sources in git history (c53174b). Do not edit and do not make it reference the real types.
///
/// Covers `app.wheelhouse.credentials` (`ClusterSecrets`, plain synthesized Codable) and `app.wheelhouse.prometheus`
/// (a plain UTF-8 string). With `Frozen_1_0_1` (the mirror and `ClusterConfig`) the rule covers every synchronizable item.
extension Frozen_1_0_1 {
    struct ClusterSecrets: Codable, Hashable, Sendable {
        var token: String?
        var clientCertificatePEM: String?
        var clientKeyPEM: String?
        var caPEM: String?
        init(token: String? = nil, clientCertificatePEM: String? = nil, clientKeyPEM: String? = nil, caPEM: String? = nil) {
            self.token = token
            self.clientCertificatePEM = clientCertificatePEM
            self.clientKeyPEM = clientKeyPEM
            self.caPEM = caPEM
        }
        var isEmpty: Bool { token == nil && clientCertificatePEM == nil && clientKeyPEM == nil && caPEM == nil }
    }

    /// 1.0.1 `KeychainCredentialStore.load`: a plain decode (an item it cannot decode throws and the cluster shows no credentials).
    static func readSecrets(_ data: Data) throws -> ClusterSecrets { try JSONDecoder().decode(ClusterSecrets.self, from: data) }

    /// 1.0.1 `PrometheusTokenStore.load`.
    static func readPrometheusToken(_ data: Data) -> String? { String(data: data, encoding: .utf8) }

    /// 1.0.1 `PrometheusTokenStore.save` encoding.
    static func encodePrometheusToken(_ token: String) -> Data { Data(token.trimmingCharacters(in: .whitespacesAndNewlines).utf8) }
}
