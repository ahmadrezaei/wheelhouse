import Foundation

public struct PEMBlock: Sendable, Hashable {
    public var label: String
    public var der: Data
}

public enum PEM {
    /// Extracts every `-----BEGIN X-----` block from a PEM bundle.
    public static func decode(_ text: String) -> [PEMBlock] {
        var blocks: [PEMBlock] = []
        var label: String?
        var body = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("-----BEGIN "), line.hasSuffix("-----") {
                label = String(line.dropFirst(11).dropLast(5))
                body = ""
            } else if line.hasPrefix("-----END ") {
                if let label, let der = Data(base64Encoded: body) { blocks.append(PEMBlock(label: label, der: der)) }
                label = nil
            } else if label != nil {
                body += line
            }
        }
        return blocks
    }

    public static func encode(label: String, der: Data) -> String {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(b64)\n-----END \(label)-----\n"
    }
}

/// Minimal DER (ASN.1) reader sufficient for unwrapping private key containers.
struct DERReader {
    struct Element { var tag: UInt8; var content: [UInt8] }
    enum DERError: Error { case truncated, unsupported }

    private let bytes: [UInt8]
    private var index = 0

    init(_ data: some Sequence<UInt8>) { bytes = Array(data) }
    var isAtEnd: Bool { index >= bytes.count }

    mutating func next() throws -> Element {
        guard index + 2 <= bytes.count else { throw DERError.truncated }
        let tag = bytes[index]; index += 1
        var length = Int(bytes[index]); index += 1
        if length & 0x80 != 0 {
            let n = length & 0x7F
            guard n > 0, n <= 4, index + n <= bytes.count else { throw DERError.unsupported }
            length = 0
            for _ in 0..<n { length = (length << 8) | Int(bytes[index]); index += 1 }
        }
        guard index + length <= bytes.count else { throw DERError.truncated }
        let content = Array(bytes[index..<index + length])
        index += length
        return Element(tag: tag, content: content)
    }
}

/// Normalised private key material ready for `SecKeyCreateWithData`.
enum ParsedPrivateKey: Equatable {
    case rsa(pkcs1: Data)
    /// X9.63 private key: `04 || X || Y || K`, with the curve size in bits.
    case ec(x963: Data, bits: Int)

    enum ParseError: Error, Equatable { case unsupported(String), malformed }

    static let rsaOID: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    static let ecOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]

    static func parse(_ block: PEMBlock) throws -> ParsedPrivateKey {
        switch block.label {
        case "RSA PRIVATE KEY": return .rsa(pkcs1: block.der)
        case "EC PRIVATE KEY": return try parseSEC1(block.der)
        case "PRIVATE KEY": return try parsePKCS8(block.der)
        case "ENCRYPTED PRIVATE KEY": throw ParseError.unsupported("Encrypted private keys are not supported")
        default: throw ParseError.unsupported("Unsupported key type \(block.label)")
        }
    }

    private static func parsePKCS8(_ der: Data) throws -> ParsedPrivateKey {
        do {
            var top = DERReader(der)
            var seq = DERReader(try top.next().content)
            _ = try seq.next() // version
            var algId = DERReader(try seq.next().content)
            let oid = try algId.next().content
            let key = try seq.next().content
            if oid == rsaOID { return .rsa(pkcs1: Data(key)) }
            if oid == ecOID { return try parseSEC1(Data(key)) }
            throw ParseError.unsupported("Unsupported key algorithm (only RSA and EC keys are supported)")
        } catch let e as ParseError { throw e } catch { throw ParseError.malformed }
    }

    private static func parseSEC1(_ der: Data) throws -> ParsedPrivateKey {
        do {
            var top = DERReader(der)
            var seq = DERReader(try top.next().content)
            _ = try seq.next() // version
            let scalar = try seq.next().content
            var publicPoint: [UInt8]?
            while !seq.isAtEnd {
                let e = try seq.next()
                if e.tag == 0xA1 {
                    var inner = DERReader(e.content)
                    let bitString = try inner.next().content
                    publicPoint = Array(bitString.dropFirst()) // drop "unused bits" byte
                }
            }
            guard let point = publicPoint, point.first == 0x04 else { throw ParseError.unsupported("EC key without embedded public point") }
            let bits = scalar.count == 66 ? 521 : scalar.count * 8
            return .ec(x963: Data(point + scalar), bits: bits)
        } catch let e as ParseError { throw e } catch { throw ParseError.malformed }
    }
}
