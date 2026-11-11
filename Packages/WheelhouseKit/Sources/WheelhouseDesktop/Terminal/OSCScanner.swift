#if os(macOS)
import Foundation

/// One operating-system command the shell integration speaks (OSC 133 and OSC 633), cut out of the PTY output.
public struct OSCSequence: Equatable, Sendable {
    /// `133` or `633`.
    public var code: Int
    /// Everything after `code;`, up to the terminator.
    public var payload: String

    public init(code: Int, payload: String) {
        self.code = code
        self.payload = payload
    }
}

/// Finds OSC 133 and OSC 633 sequences in a byte stream that arrives in arbitrary chunks (ARCHITECTURE-MAC section 3.4). It behaves like a
/// VT parser where that matters: BEL or `ESC \` ends a sequence, CAN and SUB cancel it, and an `ESC` followed by anything else abandons
/// it, so a lone `ESC ]` printed by a program cannot swallow the next real mark. A sequence longer than ``maxLength`` is dropped.
///
/// The scanner is not the security boundary (the per-session nonce is): a desynchronised scanner can hide a real mark, never create a valid one.
public struct OSCScanner: Sendable {
    public static let maxLength = 16 * 1024
    private enum State { case ground, escape, osc, oscEscape }
    private var state = State.ground
    private var buffer: [UInt8] = []
    private var relevant = true

    public init() {}

    private static let esc: UInt8 = 0x1B, bel: UInt8 = 0x07, can: UInt8 = 0x18, sub: UInt8 = 0x1A, rightBracket: UInt8 = 0x5D, backslash: UInt8 = 0x5C

    public mutating func feed(_ data: Data) -> [OSCSequence] {
        var found: [OSCSequence] = []
        for byte in data {
            switch state {
            case .ground:
                if byte == Self.esc { state = .escape }
            case .escape:
                if byte == Self.rightBracket { begin() } else if byte != Self.esc { state = .ground }
            case .osc:
                switch byte {
                case Self.bel: finish(&found)
                case Self.esc: state = .oscEscape
                case Self.can, Self.sub: reset()
                default: append(byte)
                }
            case .oscEscape:
                if byte == Self.backslash { finish(&found) } else if byte == Self.rightBracket { begin() } else { reset() }
            }
        }
        return found
    }

    private mutating func begin() {
        state = .osc
        buffer.removeAll(keepingCapacity: true)
        relevant = true
    }

    private mutating func reset() {
        state = .ground
        buffer.removeAll(keepingCapacity: true)
    }

    private mutating func append(_ byte: UInt8) {
        guard relevant else { return }
        buffer.append(byte)
        // The first four bytes decide: only `133;` and `633;` are kept; everything else is skipped without being stored.
        if buffer.count == 4, !(buffer == Array("133;".utf8) || buffer == Array("633;".utf8)) {
            relevant = false
            buffer.removeAll(keepingCapacity: true)
        } else if buffer.count > Self.maxLength {
            relevant = false
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private mutating func finish(_ found: inout [OSCSequence]) {
        defer { reset() }
        guard relevant, buffer.count >= 4, let code = Int(String(decoding: buffer[0..<3], as: UTF8.self)) else { return }
        found.append(OSCSequence(code: code, payload: String(decoding: buffer[4...], as: UTF8.self)))
    }
}
#endif
