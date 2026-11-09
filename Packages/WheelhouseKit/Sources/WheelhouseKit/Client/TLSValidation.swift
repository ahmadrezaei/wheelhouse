import Foundation
import Network
import Security

/// Subject alternative names and extended key usage of an X.509 certificate, read straight from the DER.
///
/// iOS has no public SAN accessor (`SecCertificateCopyValues` is macOS only), so the minimal ASN.1 walk lives here.
/// Used by ``TLSValidator`` when a server certificate is checked against a user-supplied CA without the SSL policy's
/// 825-day validity cap (kubeadm, minikube and RKE issue much longer-lived API server certificates).
struct CertificateNames: Equatable {
    var dnsNames: [String] = []
    var ipAddresses: [[UInt8]] = []
    var hasSAN = false
    /// EKU OIDs (raw content bytes); nil when the extension is absent.
    var extendedKeyUsage: [[UInt8]]?

    static let sanOID: [UInt8] = [0x55, 0x1D, 0x11]
    static let ekuOID: [UInt8] = [0x55, 0x1D, 0x25]
    static let serverAuthOID: [UInt8] = [0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01]
    static let anyEKUOID: [UInt8] = [0x55, 0x1D, 0x25, 0x00]

    enum ParseError: Error { case malformed }

    static func parse(der: Data) throws -> CertificateNames {
        do {
            var top = DERReader(der)
            let certificate = try top.next()
            guard certificate.tag == 0x30 else { throw ParseError.malformed }
            var certReader = DERReader(certificate.content)
            let tbs = try certReader.next()
            guard tbs.tag == 0x30 else { throw ParseError.malformed }
            var reader = DERReader(tbs.content)
            var first = try reader.next()
            if first.tag == 0xA0 { first = try reader.next() }          // optional [0] version; `first` is now the serial
            guard first.tag == 0x02 else { throw ParseError.malformed }
            for _ in 0..<5 { _ = try reader.next() }                    // sigAlg, issuer, validity, subject, SPKI
            var names = CertificateNames()
            while !reader.isAtEnd {
                let element = try reader.next()
                guard element.tag == 0xA3 else { continue }             // [1]/[2] unique ids are skipped
                var wrapper = DERReader(element.content)
                let extensions = try wrapper.next()
                var list = DERReader(extensions.content)
                while !list.isAtEnd {
                    let ext = try list.next()
                    var fields = DERReader(ext.content)
                    let oid = try fields.next()
                    guard oid.tag == 0x06 else { continue }
                    var value = try fields.next()
                    if value.tag == 0x01 { value = try fields.next() }  // optional `critical` BOOLEAN
                    guard value.tag == 0x04 else { continue }
                    if oid.content == sanOID {
                        names.hasSAN = true
                        var outer = DERReader(value.content)
                        var seq = DERReader(try outer.next().content)
                        while !seq.isAtEnd {
                            let name = try seq.next()
                            if name.tag == 0x82 { names.dnsNames.append(String(decoding: name.content, as: UTF8.self)) }
                            else if name.tag == 0x87 { names.ipAddresses.append(name.content) }
                        }
                    } else if oid.content == ekuOID {
                        var outer = DERReader(value.content)
                        var seq = DERReader(try outer.next().content)
                        var oids: [[UInt8]] = []
                        while !seq.isAtEnd { oids.append(try seq.next().content) }
                        names.extendedKeyUsage = oids
                    }
                }
            }
            return names
        } catch { throw ParseError.malformed }
    }

    /// True when the certificate may be used for TLS server authentication (no EKU, serverAuth or anyExtendedKeyUsage).
    var allowsServerAuth: Bool {
        guard let eku = extendedKeyUsage else { return true }
        return eku.contains(Self.serverAuthOID) || eku.contains(Self.anyEKUOID)
    }

    /// RFC 6125 style match against the SAN list. Never consults the subject CN; no SAN means no match.
    func matches(host rawHost: String) -> Bool {
        guard hasSAN else { return false }
        var host = rawHost.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let literal = Self.ipBytes(host) {
            return ipAddresses.contains(literal)
        }
        host = Self.normalized(host)
        guard !host.isEmpty else { return false }
        for san in dnsNames {
            let pattern = Self.normalized(san)
            if pattern == host { return true }
            if pattern.hasPrefix("*.") {
                let rest = pattern.dropFirst(2)
                // Whole left-most label only, covering exactly one label, at least two labels after the wildcard.
                guard !rest.contains("*"), rest.split(separator: ".").count >= 2 else { continue }
                guard let dot = host.firstIndex(of: "."), dot != host.startIndex else { continue }
                if host[host.index(after: dot)...] == rest { return true }
            }
        }
        return false
    }

    private static func normalized(_ name: String) -> String {
        var n = name.lowercased()
        if n.hasSuffix(".") { n.removeLast() }
        return n
    }

    static func ipBytes(_ text: String) -> [UInt8]? {
        let stripped = text.split(separator: "%", maxSplits: 1).first.map(String.init) ?? text
        if let v4 = IPv4Address(stripped) { return Array(v4.rawValue) }
        if let v6 = IPv6Address(stripped) { return Array(v6.rawValue) }
        return nil
    }
}

/// Server trust evaluation against a cluster's own CA bundle.
package enum TLSValidator {
    package struct Verdict: Equatable {
        package var trusted: Bool
        package var message: String
        /// True when the standard SSL policy rejected the leaf only for its validity period and the relaxed path was used.
        var usedValidityFallback = false
    }

    /// `errSecCertificateValidityPeriodTooLong` — the SSL policy caps leaf lifetimes (825 days).
    static let validityTooLong = -67901

    package static func evaluate(_ trust: SecTrust, host: String, anchors: [SecCertificate], verifyDate: Date? = nil) -> Verdict {
        if let verifyDate { SecTrustSetVerifyDate(trust, verifyDate as CFDate) }
        SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString))
        if anchors.isEmpty {
            var error: CFError?
            if SecTrustEvaluateWithError(trust, &error) { return Verdict(trusted: true, message: "") }
            return Verdict(trusted: false, message: describe(error))
        }
        SecTrustSetAnchorCertificates(trust, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) { return Verdict(trusted: true, message: "") }
        // Anything but "valid for too long" (host mismatch, expired, unknown root…) is a real failure.
        guard let error, CFErrorGetCode(error) == validityTooLong else {
            return Verdict(trusted: false, message: describe(error))
        }
        return relaxedEvaluate(trust, host: host, anchors: anchors, verifyDate: verifyDate)
    }

    /// Same checks as the SSL policy minus the lifetime cap: path to the user CA with signatures and dates, SAN match, EKU.
    private static func relaxedEvaluate(_ trust: SecTrust, host: String, anchors: [SecCertificate], verifyDate: Date?) -> Verdict {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else {
            return Verdict(trusted: false, message: "The server sent no certificate.")
        }
        var basic: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateBasicX509(), &basic) == errSecSuccess, let basic else {
            return Verdict(trusted: false, message: "The certificate chain could not be evaluated.")
        }
        if let verifyDate { SecTrustSetVerifyDate(basic, verifyDate as CFDate) }
        SecTrustSetAnchorCertificates(basic, anchors as CFArray)
        SecTrustSetAnchorCertificatesOnly(basic, true)
        var error: CFError?
        guard SecTrustEvaluateWithError(basic, &error) else {
            return Verdict(trusted: false, message: describe(error))
        }
        let names: CertificateNames
        do { names = try CertificateNames.parse(der: SecCertificateCopyData(leaf) as Data) } catch {
            return Verdict(trusted: false, message: "The server certificate could not be parsed.")
        }
        guard names.hasSAN else {
            return Verdict(trusted: false, message: "The server certificate has no subject alternative names (the common name is not used).")
        }
        guard names.matches(host: host) else {
            return Verdict(trusted: false, message: "The server certificate is not valid for \(host).")
        }
        guard names.allowsServerAuth else {
            return Verdict(trusted: false, message: "The server certificate is not allowed for server authentication.")
        }
        #if DEBUG
        NSLog("WHTLS server certificate for %@ is valid > 825 days; accepted via the user-CA relaxed path (path, dates, SAN and EKU verified)", host)
        #endif
        return Verdict(trusted: true, message: "", usedValidityFallback: true)
    }

    private static func describe(_ error: CFError?) -> String {
        guard let error else { return "" }
        return CFErrorCopyDescription(error) as String? ?? ""
    }
}
