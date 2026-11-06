import Foundation
import Security
import CryptoKit
import Synchronization

public enum ClientIdentityError: Error, Sendable, Equatable {
    case invalidCertificate
    case invalidKey(String)
    case keychain(OSStatus)
    case identityNotFound
}

/// Builds a `SecIdentity` from PEM certificate + private key text.
///
/// iOS has no API to create an identity from loose PEM data, and generating a PKCS#12 blob would need a
/// hand-rolled encryptor. Instead the key (`SecKeyCreateWithData`, RSA PKCS#1 or EC X9.63) and the leaf
/// certificate are added to the app's keychain as `ThisDeviceOnly` items under a per-cluster label; the
/// keychain then pairs them (matching public-key hash) and `kSecClassIdentity` returns the identity.
///
/// The certificate's keychain primary key is issuer + serial, so the *certificate* is shared between clusters that
/// present the same one, while each cluster owns its private-key item (tag = label). Builds are serialised, the
/// identity is looked up by issuer + serial (never by label), and ``remove(label:)`` deletes the certificate only when
/// no other cluster still holds a key for it.
public enum ClientIdentityBuilder {
    public struct Result: @unchecked Sendable {
        public let identity: SecIdentity
        /// Leaf first, then any intermediates present in the PEM bundle.
        public let certificates: [SecCertificate]
    }

    public static func label(for clusterID: ClusterID) -> String { "app.wheelhouse.identity.\(clusterID)" }

    public static func build(certificatePEM: String, keyPEM: String, label: String) throws -> Result {
        let certBlocks = PEM.decode(certificatePEM).filter { $0.label == "CERTIFICATE" }
        let certs = certBlocks.compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) }
        guard let leaf = certs.first else { throw ClientIdentityError.invalidCertificate }
        guard let keyBlock = PEM.decode(keyPEM).first(where: { $0.label.hasSuffix("PRIVATE KEY") }) else {
            throw ClientIdentityError.invalidKey("No private key block found")
        }
        let parsed: ParsedPrivateKey
        do { parsed = try ParsedPrivateKey.parse(keyBlock) } catch {
            throw ClientIdentityError.invalidKey("\(error)")
        }
        var attrs: [CFString: Any] = [kSecAttrKeyClass: kSecAttrKeyClassPrivate]
        let keyData: Data
        switch parsed {
        case .rsa(let pkcs1):
            attrs[kSecAttrKeyType] = kSecAttrKeyTypeRSA
            keyData = pkcs1
        case .ec(let x963, let bits):
            attrs[kSecAttrKeyType] = kSecAttrKeyTypeECSECPrimeRandom
            attrs[kSecAttrKeySizeInBits] = bits
            keyData = x963
        }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &error) else {
            throw ClientIdentityError.invalidKey(error?.takeRetainedValue().localizedDescription ?? "Key import failed")
        }

        return try lock.withLock { _ in
            let tag = Data(label.utf8)
            let keyStatus = SecItemAdd([
                kSecClass: kSecClassKey, kSecValueRef: key, kSecAttrLabel: label, kSecAttrApplicationTag: tag,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
            guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else { throw ClientIdentityError.keychain(keyStatus) }
            pruneStaleKeys(tag: tag, keeping: key)

            let leafDER = SecCertificateCopyData(leaf) as Data
            let contentLabel = contentAddressedLabel(for: leafDER)
            let certStatus = SecItemAdd([
                kSecClass: kSecClassCertificate, kSecValueRef: leaf, kSecAttrLabel: label,
                kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ] as CFDictionary, nil)
            // -25299: another cluster (or an earlier build) already stored this exact certificate. That is fine.
            guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else { throw ClientIdentityError.keychain(certStatus) }

            var status = errSecItemNotFound
            var found: SecIdentity?
            if let query = certificateQuery(for: leaf) {
                var q = query
                q[kSecClass] = kSecClassIdentity
                q[kSecReturnRef] = true
                q[kSecMatchLimit] = kSecMatchLimitOne
                var result: CFTypeRef?
                status = SecItemCopyMatching(q as CFDictionary, &result)
                if status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() {
                    found = unsafeDowncast(result, to: SecIdentity.self)
                }
            }
            if found == nil {
                // Fallback: tag the shared certificate with a content-addressed label and look the identity up by that.
                if let query = certificateQuery(for: leaf) {
                    var q = query
                    q[kSecClass] = kSecClassCertificate
                    SecItemUpdate(q as CFDictionary, [kSecAttrLabel: contentLabel] as CFDictionary)
                }
                var result: CFTypeRef?
                status = SecItemCopyMatching([
                    kSecClass: kSecClassIdentity, kSecAttrLabel: contentLabel, kSecReturnRef: true, kSecMatchLimit: kSecMatchLimitOne,
                ] as CFDictionary, &result)
                if status == errSecSuccess, let result, CFGetTypeID(result) == SecIdentityGetTypeID() {
                    found = unsafeDowncast(result, to: SecIdentity.self)
                }
            }
            guard let identity = found else {
                throw status == errSecSuccess ? ClientIdentityError.identityNotFound : ClientIdentityError.keychain(status)
            }
            // The identity must wrap exactly the certificate we were given (not a same-serial impostor).
            var paired: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &paired) == errSecSuccess, let paired,
                  (SecCertificateCopyData(paired) as Data) == leafDER else { throw ClientIdentityError.identityNotFound }
            return Result(identity: identity, certificates: certs)
        }
    }

    /// Deletes this cluster's private key, and the certificate too once no other key item references the same public key.
    public static func remove(label: String) {
        lock.withLock { _ in
            let tag = Data(label.utf8)
            var result: CFTypeRef?
            let status = SecItemCopyMatching([
                kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
            ] as CFDictionary, &result)
            let hashes = ((status == errSecSuccess ? result as? [[String: Any]] : nil) ?? []).compactMap { $0[kSecAttrApplicationLabel as String] as? Data }
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag] as CFDictionary)
            for hash in Set(hashes) where !keyExists(publicKeyHash: hash) {
                SecItemDelete([kSecClass: kSecClassCertificate, kSecAttrPublicKeyHash: hash] as CFDictionary)
            }
        }
    }

    // MARK: Helpers

    private static let lock = Mutex(())

    private static func certificateQuery(for leaf: SecCertificate) -> [CFString: Any]? {
        guard let issuer = SecCertificateCopyNormalizedIssuerSequence(leaf) as Data?,
              let serial = SecCertificateCopySerialNumberData(leaf, nil) as Data? else { return nil }
        return [kSecAttrIssuer: issuer, kSecAttrSerialNumber: serial]
    }

    static func contentAddressedLabel(for der: Data) -> String {
        "app.wheelhouse.identity." + SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    private static func keyExists(publicKeyHash: Data) -> Bool {
        let status = SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecAttrApplicationLabel: publicKeyHash, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitOne,
        ] as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Removes keys stored under the same tag whose public key differs from the one just added (a rotated client certificate).
    private static func pruneStaleKeys(tag: Data, keeping key: SecKey) {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              let keepHash = attrs[kSecAttrApplicationLabel as String] as? Data else { return }
        var result: CFTypeRef?
        guard SecItemCopyMatching([
            kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecReturnAttributes: true, kSecMatchLimit: kSecMatchLimitAll,
        ] as CFDictionary, &result) == errSecSuccess, let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let hash = item[kSecAttrApplicationLabel as String] as? Data, hash != keepHash else { continue }
            SecItemDelete([kSecClass: kSecClassKey, kSecAttrApplicationTag: tag, kSecAttrApplicationLabel: hash] as CFDictionary)
        }
    }
}
