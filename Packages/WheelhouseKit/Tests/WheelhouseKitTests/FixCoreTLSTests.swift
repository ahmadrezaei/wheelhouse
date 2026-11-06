import Foundation
import Security
import Testing
@testable import WheelhouseKit

private func cert(_ pem: String) -> SecCertificate {
    let der = PEM.decode(pem).first { $0.label == "CERTIFICATE" }!.der
    return SecCertificateCreateWithData(nil, der as CFData)!
}

private func trust(_ leafPEM: String, host: String) -> SecTrust {
    var t: SecTrust?
    precondition(SecTrustCreateWithCertificates(cert(leafPEM), SecPolicyCreateSSL(true, host as CFString), &t) == errSecSuccess)
    return t!
}

private func names(_ pem: String) throws -> CertificateNames {
    try CertificateNames.parse(der: PEM.decode(pem).first { $0.label == "CERTIFICATE" }!.der)
}

@Suite("TLS SAN / EKU matcher")
struct TLSNameMatcherTests {
    @Test func parsesSANsAndEKU() throws {
        let n = try names(TLSFixtures.long)
        #expect(n.hasSAN)
        #expect(n.dnsNames == ["localhost", "*.cluster.example"])
        #expect(n.ipAddresses == [[127, 0, 0, 1]])
        #expect(n.allowsServerAuth)
    }

    @Test func matchesIPLiteralOnlyAgainstIPSANs() throws {
        let n = try names(TLSFixtures.long)
        #expect(n.matches(host: "127.0.0.1"))
        #expect(!n.matches(host: "127.0.0.2"))
        // An IP literal never matches a dNSName, and a hostname never matches an IP entry.
        let v6 = try names(TLSFixtures.v6)
        #expect(v6.matches(host: "::1"))
        #expect(v6.matches(host: "[::1]"))
        #expect(!v6.matches(host: "127.0.0.1"))
    }

    @Test func matchesDNSNamesCaseInsensitivelyWithTrailingDot() throws {
        let n = try names(TLSFixtures.long)
        #expect(n.matches(host: "localhost"))
        #expect(n.matches(host: "LocalHost."))
        #expect(!n.matches(host: "local"))
        #expect(!n.matches(host: "localhost.evil.test"))
    }

    @Test func wildcardCoversExactlyOneLeftmostLabel() throws {
        let n = try names(TLSFixtures.long)
        #expect(n.matches(host: "api.cluster.example"))
        #expect(!n.matches(host: "a.b.cluster.example"))
        #expect(!n.matches(host: "cluster.example"))
        #expect(!n.matches(host: ".cluster.example"))
        var tld = CertificateNames(dnsNames: ["*.com"], hasSAN: true)
        #expect(!tld.matches(host: "example.com"))
        tld.dnsNames = ["f*.example.com", "*.*.example.com"]
        #expect(!tld.matches(host: "foo.example.com"))
        #expect(!tld.matches(host: "a.b.example.com"))
    }

    @Test func neverFallsBackToCommonName() throws {
        let n = try names(TLSFixtures.cnonly)       // CN=localhost, no SAN extension
        #expect(!n.hasSAN)
        #expect(!n.matches(host: "localhost"))
        #expect(!n.matches(host: "127.0.0.1"))
    }

    @Test func extendedKeyUsageMustAllowServerAuth() throws {
        #expect(try names(TLSFixtures.clientonly).allowsServerAuth == false)
        #expect(try names(TLSFixtures.cnonly).allowsServerAuth)
        #expect(CertificateNames(extendedKeyUsage: nil).allowsServerAuth)
        #expect(CertificateNames(extendedKeyUsage: [CertificateNames.anyEKUOID]).allowsServerAuth)
        #expect(!CertificateNames(extendedKeyUsage: [[0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x02]]).allowsServerAuth)
    }

    @Test func garbageDERIsRejected() {
        #expect(throws: (any Error).self) { try CertificateNames.parse(der: Data([0x30, 0x03, 0x01, 0x02])) }
    }
}

@Suite("TLS validator against a user CA")
struct TLSValidatorTests {
    let caA = [cert(TLSFixtures.caA)]

    @Test func shortLivedLeafUsesTheStrictPolicy() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.short, host: "short.test"), host: "short.test", anchors: caA)
        #expect(v.trusted)
        #expect(!v.usedValidityFallback)
    }

    @Test func threeYearLeafIsAcceptedViaTheRelaxedPath() {
        let byIP = TLSValidator.evaluate(trust(TLSFixtures.long, host: "127.0.0.1"), host: "127.0.0.1", anchors: caA)
        #expect(byIP.trusted)
        #expect(byIP.usedValidityFallback)
        let byName = TLSValidator.evaluate(trust(TLSFixtures.long, host: "localhost"), host: "localhost", anchors: caA)
        #expect(byName.trusted)
        let wildcard = TLSValidator.evaluate(trust(TLSFixtures.long, host: "api.cluster.example"), host: "api.cluster.example", anchors: caA)
        #expect(wildcard.trusted)
    }

    @Test func hostMismatchIsRejected() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.long, host: "other.test"), host: "other.test", anchors: caA)
        #expect(!v.trusted)
        let ipMismatch = TLSValidator.evaluate(trust(TLSFixtures.long, host: "10.1.2.3"), host: "10.1.2.3", anchors: caA)
        #expect(!ipMismatch.trusted)
    }

    @Test func commonNameOnlyIsRejected() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.cnonly, host: "localhost"), host: "localhost", anchors: caA)
        #expect(!v.trusted)
    }

    @Test func wrongCAIsRejected() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.wrongca, host: "127.0.0.1"), host: "127.0.0.1", anchors: caA)
        #expect(!v.trusted)
    }

    @Test func expiredLeafIsRejected() {
        let future = Date().addingTimeInterval(4 * 365 * 86_400)
        let v = TLSValidator.evaluate(trust(TLSFixtures.long, host: "127.0.0.1"), host: "127.0.0.1", anchors: caA, verifyDate: future)
        #expect(!v.trusted)
        let notYet = Date().addingTimeInterval(-2 * 86_400 * 365)
        #expect(!TLSValidator.evaluate(trust(TLSFixtures.long, host: "127.0.0.1"), host: "127.0.0.1", anchors: caA, verifyDate: notYet).trusted)
    }

    @Test func clientOnlyEKUIsRejected() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.clientonly, host: "127.0.0.1"), host: "127.0.0.1", anchors: caA)
        #expect(!v.trusted)
    }

    @Test func withoutAnchorsSystemTrustRejectsPrivateCA() {
        let v = TLSValidator.evaluate(trust(TLSFixtures.short, host: "short.test"), host: "short.test", anchors: [])
        #expect(!v.trusted)
    }

    @Test func delegateClearsStaleFailureOnSuccess() {
        let delegate = ClusterSessionDelegate(anchors: caA, insecure: false)
        let url = URL(string: "https://127.0.0.1:6443/version")!
        let bad = delegate.handleServerTrust(trust(TLSFixtures.wrongca, host: "127.0.0.1"), host: "127.0.0.1", url: url)
        #expect(bad.0 == .cancelAuthenticationChallenge)
        #expect(delegate.lastFailure != nil)
        #expect(delegate.failure(for: url) != nil)
        #expect(delegate.failure(for: URL(string: "https://127.0.0.1:6443/other")) == nil)
        let good = delegate.handleServerTrust(trust(TLSFixtures.long, host: "127.0.0.1"), host: "127.0.0.1", url: url)
        #expect(good.0 == .useCredential)
        #expect(delegate.lastFailure == nil)
        #expect(delegate.failure(for: url) == nil)
    }

    @Test func tlsServerNameOverridesTheURLHost() {
        let delegate = ClusterSessionDelegate(anchors: caA, insecure: false, serverName: "api.cluster.example")
        let ok = delegate.handleServerTrust(trust(TLSFixtures.long, host: "10.9.9.9"), host: "10.9.9.9")
        #expect(ok.0 == .useCredential)
    }

    @Test func productionNeverSkipsVerification() {
        let prod = ClusterConfig(name: "p", server: URL(string: "https://x.test")!, environment: .production, skipTLSVerify: true)
        #expect(!prod.allowsInsecureTLS)
    }
}
