import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct TLSDiagnosticsTests {
    private func urlError(_ code: URLError.Code, stream: Int? = nil, domain: Int = 3, underlying: Int? = nil) -> URLError {
        var info: [String: Any] = [:]
        if let stream { info[TLSDiagnostics.streamCodeKey] = stream; info[TLSDiagnostics.streamDomainKey] = domain }
        if let underlying { info[NSUnderlyingErrorKey] = NSError(domain: "NSOSStatusErrorDomain", code: underlying) }
        return URLError(code, userInfo: info)
    }

    private func reason(_ e: KubeError?) -> (String, Int?)? {
        if case .tlsHandshake(let r, let c)? = e { return (r, c) }
        return nil
    }

    @Test(arguments: [-9806, -9805])
    func closedCodes(_ code: Int) {
        let e = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: code))
        #expect(reason(e)?.0.contains("closed during the TLS handshake") == true)
        #expect(e?.summary.hasSuffix("(code \(code))") == true)
    }

    @Test(arguments: [-9825, -9829, -9826, -9832, -9831])
    func rejectedClientCert(_ code: Int) {
        let e = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: code))
        #expect(reason(e)?.0 == "The server rejected the client certificate.")
        #expect(reason(e)?.1 == code)
    }

    @Test func badCertFormatIsLocalNotAServerRejection() {
        let e = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9808))
        #expect(reason(e)?.0.contains("invalid format") == true)
        #expect(reason(e)?.0 != "The server rejected the client certificate.")
    }

    @Test func newlyMappedCodes() {
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9834)))?.0.contains("does not match") == true)
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9863)))?.0.contains("requires a client certificate") == true)
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9865)))?.0.contains("SNI") == true)
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9809)))?.0.contains("cryptographic") == true)
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9858)))?.0 == "TLS version/cipher negotiation failed.")
    }

    @Test func nonSSLDomainIsNotTreatedAsSSL() {
        // A POSIX-domain number that happens to be in the SecureTransport range must not be mapped as an SSL code.
        let e = urlError(.secureConnectionFailed, stream: -9806, domain: 1)
        #expect(TLSDiagnostics.extract(from: e).sslCode == nil)
        let m = reason(TLSDiagnostics.handshakeError(for: e))
        #expect(m?.0.contains("stream domain 1") == true)
        // A nested error in an unrelated domain is ignored too.
        let nested = URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSPOSIXErrorDomain", code: -9806)])
        #expect(TLSDiagnostics.extract(from: nested).sslCode == nil)
        #expect(TLSDiagnostics.errorChain(from: nested) == ["NSURLErrorDomain:-1200", "NSPOSIXErrorDomain:-9806"])
    }

    @Test func clientCertificateRejectedURLCode() {
        let e = TLSDiagnostics.handshakeError(for: URLError(.clientCertificateRejected))
        #expect(reason(e)?.0 == "The server rejected the client certificate.")
        #expect(e?.summary.contains("(code -1205)") == true)
    }

    @Test(arguments: [-9824, -9836])
    func negotiation(_ code: Int) {
        let e = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: code))
        #expect(reason(e)?.0 == "TLS version/cipher negotiation failed.")
    }

    @Test func fatalAlertAndUnknown() {
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9802)))?.0.contains("fatal alert") == true)
        let unknown = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed))
        #expect(reason(unknown)?.1 == -1200)
        #expect(unknown?.summary.contains("(code -1200)") == true)
    }

    @Test func underlyingChainIsWalked() {
        let inner = NSError(domain: "kCFErrorDomainCFNetwork", code: 0, userInfo: [TLSDiagnostics.streamCodeKey: -9806, TLSDiagnostics.streamDomainKey: 3])
        let outer = URLError(.secureConnectionFailed, userInfo: [NSUnderlyingErrorKey: inner])
        #expect(TLSDiagnostics.extract(from: outer).sslCode == -9806)
        #expect(reason(TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, underlying: -9825)))?.1 == -9825)
    }

    @Test func networkLostDuringHandshake() {
        let lost = URLError(.networkConnectionLost)
        #expect(TLSDiagnostics.handshakeError(for: lost) == nil)
        #expect(reason(TLSDiagnostics.handshakeError(for: lost, neverConnected: true))?.0.contains("A firewall") == true)
    }

    @Test func identityFailureWins() {
        let e = TLSDiagnostics.handshakeError(for: urlError(.secureConnectionFailed, stream: -9806), clientIdentityFailure: "Client key cannot sign: boom")
        #expect(reason(e)?.0 == "Client key cannot sign: boom")
    }

    @Test func notTLS() {
        #expect(TLSDiagnostics.handshakeError(for: URLError(.timedOut)) == nil)
        #expect(TLSDiagnostics.handshakeError(for: URLError(.cancelled)) == nil)
    }

    @Test func reportRedactsSecrets() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\nabc\n-----END RSA PRIVATE KEY-----"
        let jwt = "eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiJ4In0.c2ln"
        let err = KubeError.unreachable(cause: "boom \(pem) Bearer \(jwt) \(String(repeating: "A", count: 120))")
        let report = ConnectionDiagnosticsReport.make(host: "10.0.0.1", port: 6443, authKind: "clientCertificate", error: err, osVersion: "27.1", appVersion: "1.0", build: "42")
        #expect(report.contains("Host: 10.0.0.1"))
        #expect(report.contains("Port: 6443"))
        #expect(report.contains("Auth: clientCertificate"))
        #expect(report.contains("iOS: 27.1"))
        #expect(report.contains("App: 1.0 (42)"))
        #expect(!report.contains("BEGIN"))
        #expect(!report.contains("MIIEow"))
        #expect(!report.contains(jwt))
        #expect(!report.contains("AAAAAAAAAA"))
    }

    @Test func reportIncludesCodes() {
        let report = ConnectionDiagnosticsReport.make(host: "h", port: nil, authKind: "token", error: .tlsHandshake(reason: "x", code: -9806), osVersion: "27", appVersion: "1", build: "1")
        #expect(report.contains("Code: -9806"))
        #expect(report.contains("(code -9806)"))
    }
}
