import Foundation
import Security
import Testing
@testable import WheelhouseKit

/// Client-identity / handshake mapping regressions (token clusters, diagnostic-only sign test, mid-stream drops).
@Suite struct ClientIdentityDiagnosticsTests {
    static let certPEM = """
-----BEGIN CERTIFICATE-----
MIIBITCByAIJAMMC1ZHGa4WWMAoGCCqGSM49BAMCMBkxFzAVBgNVBAMMDndoLXRl
c3QtY2xpZW50MB4XDTI2MTEwNjAwMTAyMloXDTM2MTEwMzAwMTAyMlowGTEXMBUG
A1UEAwwOd2gtdGVzdC1jbGllbnQwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAAQa
t6j+CTbvW4mZ4/nPRvQMxFXNKD8dLfi1KKN0tTOMcGgD037GKJviEfQzCKn+pirc
yhpBitDcigqjT8tSdRYpMAoGCCqGSM49BAMCA0gAMEUCIBhH880wbJmgl9qp1G27
IXH5go3+0DHZoYlCux+3N04IAiEAwwLKwBBcJJSL887PDZcj1nPO7pgAV170XTUW
mIRpv+8=
-----END CERTIFICATE-----
"""
    static let keyPEM = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIHwrsKm2AUBtkDPH+OLvmZZBVLzj8MHiTRhWLXMsP4B2oAoGCCqGSM49
AwEHoUQDQgAEGreo/gk271uJmeP5z0b0DMRVzSg/HS34tSijdLUzjHBoA9N+xiib
4hH0Mwip/qYq3MoaQYrQ3IoKo0/LUnUWKQ==
-----END EC PRIVATE KEY-----
"""

    private func sslLost(_ code: URLError.Code = .networkConnectionLost, ssl: Int = -9806) -> URLError {
        URLError(code, userInfo: [TLSDiagnostics.streamCodeKey: ssl, TLSDiagnostics.streamDomainKey: 3])
    }

    private func tokenClient() -> LiveKubeClient {
        LiveKubeClient(config: ClusterConfig(name: "t", server: URL(string: "https://203.0.113.9:6443")!, environment: .staging), secrets: ClusterSecrets(token: "t"))
    }

    @Test func tokenClusterIgnoresTheCertificateRequest() {
        let client = tokenClient()
        // kube-apiserver always sends a CertificateRequest; a token cluster declines it.
        let r = client.delegate.handleClientCertificate()
        #expect(r.0 == .performDefaultHandling)
        #expect(client.delegate.identityFailure == nil)
        #expect(client.delegate.clientCertificateMissing)
        let lost = client.mapTransportError(sslLost(.secureConnectionFailed, ssl: -9806))
        guard case .tlsHandshake(let reason, _) = lost else { Issue.record("expected tlsHandshake, got \(lost)"); return }
        #expect(reason == TLSDiagnostics.closedMessage)
        // The hint explains only an explicit "certificate required".
        let required = client.mapTransportError(URLError(.clientCertificateRequired))
        guard case .tlsHandshake(let r2, _) = required else { Issue.record("expected tlsHandshake"); return }
        #expect(r2.contains("none configured"))
        #expect(client.tlsTrace.noIdentityConfigured)
    }

    @Test func connectionLostAfterAResponseIsUnreachable() {
        let client = tokenClient()
        #expect(client.mapTransportError(sslLost(), responseReceived: true) == .unreachable(cause: "Connection lost"))
        #expect(client.mapTransportError(sslLost(.secureConnectionFailed), responseReceived: true) == .unreachable(cause: "Connection lost"))
        // Without a response it is still a handshake failure.
        if case .tlsHandshake = client.mapTransportError(sslLost()) {} else { Issue.record("expected tlsHandshake") }
    }

    @Test func closedDuringHandshakeIsTransient() {
        #expect(KubeError.tlsHandshake(reason: TLSDiagnostics.closedMessage, code: -1005).isTransient)
        #expect(KubeError.tlsHandshake(reason: "x", code: -9806).isTransient)
        #expect(!KubeError.tlsHandshake(reason: TLSDiagnostics.rejectedClientCertMessage, code: -9825).isTransient)
    }

    @Test func cannotSignStillPresentsTheIdentityAndAnUnauthorizedCarriesTheReason() throws {
        var built: ClientIdentityBuilder.Result
        do { built = try ClientIdentityBuilder.build(certificatePEM: Self.certPEM, keyPEM: Self.keyPEM, label: "app.wheelhouse.identity.unit-test") }
        catch ClientIdentityError.keychain(-34018) { return }   // no keychain entitlement in the package test host: covered on a real build
        catch { Issue.record("identity could not be built: \(error)"); return }
        defer { ClientIdentityBuilder.remove(label: "app.wheelhouse.identity.unit-test") }
        built.signTestRan = true
        built.signTestFailure = "boom (code -1)"
        let result = built
        let delegate = ClusterSessionDelegate(anchors: [], insecure: false, identityProvider: { .success(result) })
        let (disposition, credential) = delegate.handleClientCertificate()
        #expect(disposition == .useCredential)
        #expect(credential?.identity != nil)
        #expect(delegate.identityFailure == nil)           // diagnostic only: never takes precedence
        let note = try #require(delegate.identityNote)
        #expect(note.contains("boom"))
        let e = KubeError.unauthorized(message: KubeError.appendingIdentityNote(note, to: "Unauthorized"))
        #expect(e.summary.contains("boom"))
        #expect(e.identityNote == note)
        #expect(delegate.trace.identityPresented)
        #expect(delegate.trace.signTest == "boom (code -1)")
        #expect(delegate.trace.keyType == "EC")
        #expect(delegate.trace.clientLeafSHA256?.isEmpty == false)
    }

    @Test func signTestPassesForARealKey() throws {
        let built: ClientIdentityBuilder.Result
        do { built = try ClientIdentityBuilder.build(certificatePEM: Self.certPEM, keyPEM: Self.keyPEM, label: "app.wheelhouse.identity.unit-test-2") }
        catch ClientIdentityError.keychain(-34018) { return }
        defer { ClientIdentityBuilder.remove(label: "app.wheelhouse.identity.unit-test-2") }
        #expect(ClientIdentityBuilder.testSign(built.identity) == nil)
    }

    @Test func notAfterIsParsedFromDER() throws {
        let der = try #require(PEM.decode(Self.certPEM).first { $0.label == "CERTIFICATE" }?.der)
        let notAfter = try #require(ClientIdentityBuilder.notAfter(ofDER: der))
        #expect(notAfter > Date().addingTimeInterval(86_400 * 365 * 5))   // fixture is valid for ~10 years from generation
    }

    @Test func providerFailureStillTakesPrecedence() {
        let delegate = ClusterSessionDelegate(anchors: [], insecure: false, identityProvider: { .failure(.invalidKey("bad")) })
        #expect(delegate.handleClientCertificate().0 == .performDefaultHandling)
        let e = TLSDiagnostics.handshakeError(for: sslLost(.secureConnectionFailed), clientIdentityFailure: delegate.identityFailure)
        if case .tlsHandshake(let r, _)? = e { #expect(r.contains("not usable")) } else { Issue.record("expected tlsHandshake") }
    }

    @Test func reportListsTraceFieldsWithoutSecrets() {
        var t = TLSTrace()
        t.serverTrust = .passed; t.clientCertificateRequested = true; t.identityPresented = true; t.signTest = "passed"
        t.keyType = "EC"; t.keySizeBits = 256; t.clientLeafSHA256 = "AB:CD"; t.errorChain = ["NSURLErrorDomain:-1005", "kCFErrorDomainCFNetwork:-9806"]
        let report = ConnectionDiagnosticsReport.make(host: "h", port: 6443, authKind: "clientCertificate", error: .tlsHandshake(reason: "x", code: -9806), trace: t, osVersion: "27", appVersion: "1", build: "2")
        for needle in ["Server trust challenge: passed", "Client certificate challenge: received", "Client identity presented: yes", "Sign test: passed",
                       "Client leaf SHA-256: AB:CD", "Client key: EC 256-bit", "NSURLErrorDomain:-1005 > kCFErrorDomainCFNetwork:-9806"] {
            #expect(report.contains(needle), "missing \(needle)")
        }
    }
}
