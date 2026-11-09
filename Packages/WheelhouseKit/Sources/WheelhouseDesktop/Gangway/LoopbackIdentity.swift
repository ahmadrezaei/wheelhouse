#if os(macOS)
import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum LoopbackIdentityError: Error, Equatable, LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .failed(let why): "Gangway could not create its loopback identity: \(why)"
        }
    }
}

/// The TLS identity of the loopback listener: a P-256 key made for this launch and held in memory only (never in a keychain, never on
/// disk), and a self-signed certificate for `127.0.0.1` and `localhost`. The certificate's DER goes into each session kubeconfig as
/// `certificate-authority-data`, so a tool trusts exactly this launch's listener and nothing else.
///
/// A `SecIdentity` cannot be formed from an in-memory key through public API except by importing a PKCS#12 with
/// `kSecImportToMemoryOnly`, so the key and certificate are packed into a throwaway PKCS#12 (legacy PBE, random password) and imported at
/// once. Keychain access is not involved, so this also works in an unsigned test process (the data-protection keychain answers -34018
/// there) and shows no prompt.
public final class LoopbackIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let certificateDER: Data

    private init(identity: SecIdentity, certificateDER: Data) {
        self.identity = identity
        self.certificateDER = certificateDER
    }

    public static func make(now: Date = Date()) throws -> LoopbackIdentity {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits: 256, kSecAttrIsPermanent: false]
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error), let publicKey = SecKeyCopyPublicKey(privateKey),
              let privateBytes = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?,
              let publicBytes = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw LoopbackIdentityError.failed("key: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let tbs = X509.tbsCertificate(publicKeyX963: publicBytes, now: now)
        guard let signature = SecKeyCreateSignature(privateKey, .ecdsaSignatureMessageX962SHA256, tbs as CFData, &error) as Data? else {
            throw LoopbackIdentityError.failed("sign: \(error?.takeRetainedValue().localizedDescription ?? "unknown")")
        }
        let der = DER.sequence([tbs, DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])]), DER.bitString(signature)])
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else { throw LoopbackIdentityError.failed("certificate does not parse") }

        var passwordBytes = [UInt8](repeating: 0, count: 18)
        guard SecRandomCopyBytes(kSecRandomDefault, passwordBytes.count, &passwordBytes) == errSecSuccess else { throw LoopbackIdentityError.failed("no random bytes") }
        let password = Data(passwordBytes).base64EncodedString()
        let pkcs12 = try PKCS12.build(privateKeyX963: privateBytes, publicKeyX963: publicBytes, certificateDER: der, password: password)
        var items: CFArray?
        let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
        let status = SecPKCS12Import(pkcs12 as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first, let imported = first[kSecImportItemIdentity as String],
              CFGetTypeID(imported as CFTypeRef) == SecIdentityGetTypeID() else {
            throw LoopbackIdentityError.failed("import \(status)")
        }
        return LoopbackIdentity(identity: imported as! SecIdentity, certificateDER: der)   // the type was checked above
    }
}

/// The minimum of a PKCS#12 (RFC 7292) that `SecPKCS12Import` accepts: one shrouded key bag (pbeWithSHAAnd3-KeyTripleDES-CBC), one
/// certificate bag, and an HMAC-SHA1 MAC, both keyed from the password with the PKCS#12 key derivation.
enum PKCS12 {
    static let iterations = 2048

    static func build(privateKeyX963: Data, publicKeyX963: Data, certificateDER: Data, password: String) throws -> Data {
        // SecKey's EC private key is `04 | X | Y | K`.
        let scalar = Data(privateKeyX963.suffix(32))
        let ecPrivateKey = DER.sequence([DER.integer([1]), DER.octetString(scalar), DER.tlv(0xA1, DER.bitString(publicKeyX963))])
        let algorithm = DER.sequence([DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])])
        let pkcs8 = DER.sequence([DER.integer([0]), algorithm, DER.octetString(ecPrivateKey)])

        let keyID = DER.octetString(Data("wh-gangway".utf8))
        let attributes = DER.set([DER.sequence([DER.oid([1, 2, 840, 113549, 1, 9, 21]), DER.set([keyID])])])
        var salt = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else { throw LoopbackIdentityError.failed("no random bytes") }
        let encrypted = try tripleDES(pkcs8, password: password, salt: Data(salt))
        let shrouded = DER.sequence([DER.sequence([DER.oid([1, 2, 840, 113549, 1, 12, 1, 3]), DER.sequence([DER.octetString(Data(salt)), DER.integer(integerBytes(iterations))])]),
                                     DER.octetString(encrypted)])
        let keyBag = DER.sequence([DER.oid([1, 2, 840, 113549, 1, 12, 10, 1, 2]), DER.tlv(0xA0, shrouded), attributes])
        let certificate = DER.sequence([DER.oid([1, 2, 840, 113549, 1, 9, 22, 1]), DER.tlv(0xA0, DER.octetString(certificateDER))])
        let certBag = DER.sequence([DER.oid([1, 2, 840, 113549, 1, 12, 10, 1, 3]), DER.tlv(0xA0, certificate), attributes])
        let safeContents = DER.sequence([keyBag, certBag])
        let data = DER.oid([1, 2, 840, 113549, 1, 7, 1])
        let authenticatedSafe = DER.sequence([DER.sequence([data, DER.tlv(0xA0, DER.octetString(safeContents))])])

        var macSalt = [UInt8](repeating: 0, count: 8)
        guard SecRandomCopyBytes(kSecRandomDefault, macSalt.count, &macSalt) == errSecSuccess else { throw LoopbackIdentityError.failed("no random bytes") }
        let macKey = kdf(id: 3, password: password, salt: Data(macSalt), length: 20)
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: authenticatedSafe, using: SymmetricKey(data: macKey)))
        let macData = DER.sequence([DER.sequence([DER.sequence([DER.oid([1, 3, 14, 3, 2, 26]), Data([0x05, 0x00])]), DER.octetString(mac)]),
                                    DER.octetString(Data(macSalt)), DER.integer(integerBytes(iterations))])
        return DER.sequence([DER.integer([3]), DER.sequence([data, DER.tlv(0xA0, DER.octetString(authenticatedSafe))]), macData])
    }

    private static func integerBytes(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = value
        repeat { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 } while v > 0
        return bytes
    }

    /// The PKCS#12 key derivation (RFC 7292 appendix B) with SHA-1.
    static func kdf(id: UInt8, password: String, salt: Data, length: Int) -> Data {
        let v = 64, u = 20
        var pw = Data()
        for unit in password.utf16 { pw.append(UInt8(unit >> 8)); pw.append(UInt8(unit & 0xFF)) }
        pw.append(contentsOf: [0, 0])
        func stretch(_ d: Data) -> [UInt8] {
            let target = ((d.count + v - 1) / v) * v
            var out = [UInt8]()
            while out.count < target { out += d }
            return Array(out.prefix(target))
        }
        var block = stretch(salt) + stretch(pw)
        var out = Data()
        for _ in 0..<((length + u - 1) / u) {
            var a = Data(repeating: id, count: v) + Data(block)
            for _ in 0..<iterations { a = Data(Insecure.SHA1.hash(data: a)) }
            out += a
            var b = [UInt8]()
            while b.count < v { b += a }
            b = Array(b.prefix(v))
            var j = 0
            while j < block.count {
                var carry = 1
                for k in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(block[j + k]) + Int(b[k]) + carry
                    block[j + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
                j += v
            }
        }
        return out.prefix(length)
    }

    private static func tripleDES(_ plain: Data, password: String, salt: Data) throws -> Data {
        let key = kdf(id: 1, password: password, salt: salt, length: 24)
        let iv = kdf(id: 2, password: password, salt: salt, length: 8)
        var out = [UInt8](repeating: 0, count: plain.count + 16)
        var moved = 0
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { i in plain.withUnsafeBytes { p in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithm3DES), CCOptions(kCCOptionPKCS7Padding), k.baseAddress, 24, i.baseAddress,
                    p.baseAddress, plain.count, &out, out.count, &moved)
        } } }
        guard status == kCCSuccess else { throw LoopbackIdentityError.failed("3DES \(status)") }
        return Data(out.prefix(moved))
    }
}

enum DER {
    static func length(_ n: Int) -> Data {
        if n < 128 { return Data([UInt8(n)]) }
        var bytes: [UInt8] = []
        var v = n
        while v > 0 { bytes.insert(UInt8(v & 0xFF), at: 0); v >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
    static func tlv(_ tag: UInt8, _ content: Data) -> Data { Data([tag]) + length(content.count) + content }
    static func sequence(_ items: [Data]) -> Data { tlv(0x30, items.reduce(Data(), +)) }
    static func set(_ items: [Data]) -> Data { tlv(0x31, items.reduce(Data(), +)) }
    static func integer(_ bytes: [UInt8]) -> Data {
        var b = bytes
        while b.count > 1, b[0] == 0, b[1] & 0x80 == 0 { b.removeFirst() }
        if b[0] & 0x80 != 0 { b.insert(0, at: 0) }
        return tlv(0x02, Data(b))
    }
    static func oid(_ arcs: [UInt]) -> Data {
        var out: [UInt8] = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk: [UInt8] = [UInt8(arc & 0x7F)]
            var v = arc >> 7
            while v > 0 { chunk.insert(UInt8(v & 0x7F) | 0x80, at: 0); v >>= 7 }
            out += chunk
        }
        return tlv(0x06, Data(out))
    }
    static func utf8(_ s: String) -> Data { tlv(0x0C, Data(s.utf8)) }
    /// A BIT STRING with no unused bits.
    static func bitString(_ data: Data) -> Data { tlv(0x03, Data([0]) + data) }
    static func octetString(_ data: Data) -> Data { tlv(0x04, data) }
    static func boolean(_ v: Bool) -> Data { tlv(0x01, Data([v ? 0xFF : 0x00])) }
    static func utcTime(_ date: Date) -> Data {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyMMddHHmmss'Z'"
        return tlv(0x17, Data(f.string(from: date).utf8))
    }
}

enum X509 {
    /// TBSCertificate: self-signed, ECDSA P-256 with SHA-256, valid from a day ago to a week from now (a launch is shorter), SAN
    /// `IP:127.0.0.1` and `DNS:localhost`, key usage digitalSignature, extended key usage serverAuth, basic constraints CA:false.
    static func tbsCertificate(publicKeyX963: Data, now: Date) -> Data {
        var serial = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        let sigAlg = DER.sequence([DER.oid([1, 2, 840, 10045, 4, 3, 2])])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid([2, 5, 4, 3]), DER.utf8("Wheelhouse Gangway loopback")])])])
        let validity = DER.sequence([DER.utcTime(now.addingTimeInterval(-86_400)), DER.utcTime(now.addingTimeInterval(7 * 86_400))])
        let spki = DER.sequence([DER.sequence([DER.oid([1, 2, 840, 10045, 2, 1]), DER.oid([1, 2, 840, 10045, 3, 1, 7])]), DER.bitString(publicKeyX963)])
        let san = DER.sequence([DER.tlv(0x82, Data("localhost".utf8)), DER.tlv(0x87, Data([127, 0, 0, 1]))])
        func ext(_ oid: [UInt], critical: Bool = false, _ value: Data) -> Data {
            DER.sequence([DER.oid(oid)] + (critical ? [DER.boolean(true)] : []) + [DER.octetString(value)])
        }
        let keyUsage = DER.tlv(0x03, Data([0x07, 0x80]))                    // digitalSignature, seven unused bits
        let extensions = DER.sequence([
            ext([2, 5, 29, 17], san),
            ext([2, 5, 29, 15], critical: true, keyUsage),
            ext([2, 5, 29, 37], DER.sequence([DER.oid([1, 3, 6, 1, 5, 5, 7, 3, 1])])),
            ext([2, 5, 29, 19], critical: true, DER.sequence([])),
        ])
        return DER.sequence([DER.tlv(0xA0, DER.integer([2])), DER.integer(serial), sigAlg, name, validity, name, spki, DER.tlv(0xA3, extensions)])
    }
}
#endif
