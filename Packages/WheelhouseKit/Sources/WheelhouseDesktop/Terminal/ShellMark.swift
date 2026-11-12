#if os(macOS)
import Foundation
import Security

/// What a shell-integration mark says.
public enum ShellMark: Equatable, Sendable {
    /// OSC 133;A: the prompt is about to be drawn.
    case promptStart
    /// OSC 133;C: the command starts running.
    case commandExecuted
    /// OSC 133;D: the command finished (exit status when given).
    case commandFinished(Int?)
    /// OSC 633;E: the command line, as the shell reported it. A hint, never an authority.
    case commandLine(String)
    /// OSC 633;P;KubeConfig=: the shell's `KUBECONFIG` (nil when it is unset).
    case kubeconfig(String?)
    /// OSC 633;P;Cwd=: the working directory.
    case workingDirectory(String)
}

/// How a mark's nonce compared to the session's.
public enum MarkAuthenticity: Equatable, Sendable {
    case verified
    /// No `wh=` parameter, or the wrong value: the mark is ignored and counted.
    case forged
}

public struct ParsedMark: Equatable, Sendable {
    public var authenticity: MarkAuthenticity
    /// nil for a forged mark, and for a verified one this code does not know.
    public var mark: ShellMark?
}

public enum ShellMarkParser {
    /// Parses one sequence. The last `;`-separated parameter must be `wh=<nonce>`; the command line escapes `;`, `\` and control
    /// characters, so a `;` inside it never splits a parameter.
    public static func parse(_ sequence: OSCSequence, nonce: String) -> ParsedMark {
        var parts = sequence.payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last, last.hasPrefix("wh="), constantTimeEqual(String(last.dropFirst(3)), nonce) else {
            return ParsedMark(authenticity: .forged, mark: nil)
        }
        parts.removeLast()
        return ParsedMark(authenticity: .verified, mark: mark(code: sequence.code, parts: parts))
    }

    private static func mark(code: Int, parts: [String]) -> ShellMark? {
        guard let kind = parts.first else { return nil }
        switch (code, kind) {
        case (133, "A"): return .promptStart
        case (133, "C"): return .commandExecuted
        case (133, "D"): return .commandFinished(parts.count > 1 ? Int(parts[1]) : nil)
        case (633, "E"): return .commandLine(unescape(parts.dropFirst().joined(separator: ";")))
        case (633, "P"):
            guard parts.count > 1 else { return nil }
            let pair = parts.dropFirst().joined(separator: ";")
            if pair == "KubeConfigUnset=1" { return .kubeconfig(nil) }
            if pair.hasPrefix("KubeConfig=") { return .kubeconfig(unescape(String(pair.dropFirst("KubeConfig=".count)))) }
            if pair.hasPrefix("Cwd=") { return .workingDirectory(unescape(String(pair.dropFirst("Cwd=".count)))) }
            return nil
        default: return nil
        }
    }

    /// Decodes `\\` and `\xNN`.
    public static func unescape(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var bytes: [UInt8] = []
        let source = Array(text.utf8)
        var index = 0
        while index < source.count {
            let byte = source[index]
            if byte == 0x5C, index + 1 < source.count {
                if source[index + 1] == 0x5C { bytes.append(0x5C); index += 2; continue }
                if source[index + 1] == 0x78, index + 3 < source.count,
                   let value = UInt8(String(decoding: source[(index + 2)...(index + 3)], as: UTF8.self), radix: 16) {
                    bytes.append(value)
                    index += 4
                    continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// Generates the per-session nonce: 128 random bits as hex.
public enum ShellNonce {
    public static func make() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // Never reached in practice; a weak nonce is worse than none, so fall back to the system generator.
            var generator = SystemRandomNumberGenerator()
            return (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &generator)) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
#endif
