#if os(macOS)
import Foundation
import Security
import Testing
@testable import WheelhouseDesktop

@Suite("Loopback TLS identity")
struct LoopbackIdentityTests {
    @Test("an in-memory identity can be made in an unsigned process; its certificate names the loopback and only the loopback")
    func makes() throws {
        let made = try LoopbackIdentity.make()
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(made.identity, &key) == errSecSuccess)
        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(made.identity, &cert) == errSecSuccess)
        let certificate = try #require(cert)
        #expect(SecCertificateCopyData(certificate) as Data == made.certificateDER)
        func evaluate(_ host: String) -> Bool {
            var trust: SecTrust?
            SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust)
            SecTrustSetAnchorCertificates(trust!, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust!, true)
            return SecTrustEvaluateWithError(trust!, nil)
        }
        #expect(evaluate("127.0.0.1"))
        #expect(evaluate("localhost"))
        #expect(!evaluate("example.com"))
        // Two launches never share a key.
        #expect(try LoopbackIdentity.make().certificateDER != made.certificateDER)
    }

    @Test("the certificate is valid for 800 days (inside the 825-day cap of the SSL policy): a launch can run for months, and Go checks validity even for a pinned self-signed root")
    func validityWindow() throws {
        let now = Date()
        let made = try LoopbackIdentity.make(now: now)
        let certificate = try #require(SecCertificateCreateWithData(nil, made.certificateDER as CFData))
        let notBefore = try #require(SecCertificateCopyNotValidBeforeDate(certificate)) as Date
        let notAfter = try #require(SecCertificateCopyNotValidAfterDate(certificate)) as Date
        #expect(abs(notBefore.timeIntervalSince(now) + 86_400) < 2)
        #expect(abs(notAfter.timeIntervalSince(now) - 800 * 86_400) < 2)
        // Still trusted 790 days into the launch, and not trusted after the window.
        func trusted(at date: Date) -> Bool {
            var trust: SecTrust?
            SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, "127.0.0.1" as CFString), &trust)
            SecTrustSetAnchorCertificates(trust!, [certificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust!, true)
            SecTrustSetVerifyDate(trust!, date as CFDate)
            return SecTrustEvaluateWithError(trust!, nil)
        }
        #expect(trusted(at: now.addingTimeInterval(790 * 86_400)))
        #expect(!trusted(at: now.addingTimeInterval(810 * 86_400)))
    }

    @Test("the key signs, and nothing was left in a keychain")
    func signs() throws {
        let made = try LoopbackIdentity.make()
        var key: SecKey?
        SecIdentityCopyPrivateKey(made.identity, &key)
        var error: Unmanaged<CFError>?
        let signature = SecKeyCreateSignature(try #require(key), .ecdsaSignatureMessageX962SHA256, Data("x".utf8) as CFData, &error)
        #expect(signature != nil)
        let query: [CFString: Any] = [kSecClass: kSecClassKey, kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitAll,
                                      kSecAttrLabel: "wh-gangway"]
        var found: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &found) != errSecSuccess)
    }
}
#endif
