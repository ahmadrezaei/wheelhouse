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
    /// Raw bytes of the sequence being read, kept until it is known whether it is ours (and so removed) or not (and so passed on).
    private var held: [UInt8] = []
    private var relevant = true
    /// True once a sequence is known not to be ours: its bytes go straight through.
    private var passthrough = false

    public init() {}

    private static let esc: UInt8 = 0x1B, bel: UInt8 = 0x07, can: UInt8 = 0x18, sub: UInt8 = 0x1A, rightBracket: UInt8 = 0x5D, backslash: UInt8 = 0x5C

    /// The marks found in `data`.
    public mutating func feed(_ data: Data) -> [OSCSequence] { process(data).sequences }

    /// Finds the marks and removes them from the stream: the terminal emulator never sees an OSC 133 or 633 (it acts on 133 itself, for
    /// example click-to-move-cursor, and a hostile program must not be able to drive that). Everything else passes through unchanged. A
    /// partial sequence at the end of a chunk is held back until the next chunk decides what it is.
    public mutating func process(_ data: Data) -> (sequences: [OSCSequence], output: Data) {
        var found: [OSCSequence] = []
        var out = Data()
        out.reserveCapacity(data.count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            while index < bytes.count {
                if state == .ground {
                    // Fast path: copy everything up to the next ESC in one go.
                    let rest = bytes.count - index
                    if let at = memchr(bytes.baseAddress! + index, Int32(Self.esc), rest) {
                        let end = bytes.baseAddress!.distance(to: at.assumingMemoryBound(to: UInt8.self))
                        out.append(bytes.baseAddress! + index, count: end - index)
                        index = end + 1
                        state = .escape
                        held = [Self.esc]
                    } else {
                        out.append(bytes.baseAddress! + index, count: rest)
                        index = bytes.count
                    }
                    continue
                }
                let byte = bytes[index]
                index += 1
                switch state {
                case .ground: break
                case .escape:
                    if byte == Self.rightBracket { held.append(byte); begin() }
                    else if byte == Self.esc { out.append(contentsOf: held); held = [Self.esc] }
                    else { out.append(contentsOf: held); out.append(byte); held = []; state = .ground }
                case .osc:
                    switch byte {
                    case Self.bel: emit(byte, &out); finish(&found, &out)
                    case Self.esc: emit(byte, &out); state = .oscEscape
                    case Self.can, Self.sub: emit(byte, &out); abandon(&out)
                    default: emit(byte, &out); append(byte, &out)
                    }
                case .oscEscape:
                    if byte == Self.backslash { emit(byte, &out); finish(&found, &out) }
                    else if byte == Self.rightBracket {
                        // The ESC that began a new sequence is the last byte emitted; take it back out of whichever buffer holds it.
                        if passthrough { out.removeLast() } else { held.removeLast() }
                        flushHeld(&out)
                        held = [Self.esc, byte]
                        begin()
                    } else {
                        emit(byte, &out)
                        abandon(&out)
                    }
                }
            }
        }
        return (found, out)
    }

    private mutating func emit(_ byte: UInt8, _ out: inout Data) {
        if passthrough { out.append(byte) } else { held.append(byte) }
    }

    private mutating func flushHeld(_ out: inout Data) {
        out.append(contentsOf: held)
        held = []
    }

    private mutating func begin() {
        state = .osc
        buffer.removeAll(keepingCapacity: true)
        relevant = true
        passthrough = false
    }

    /// The sequence was cut short: its bytes were not ours, so they go on to the terminal.
    private mutating func abandon(_ out: inout Data) {
        flushHeld(&out)
        buffer.removeAll(keepingCapacity: true)
        passthrough = false
        state = .ground
    }

    private mutating func append(_ byte: UInt8, _ out: inout Data) {
        guard relevant else { return }
        buffer.append(byte)
        // The first four bytes decide: only `133;` and `633;` are kept; anything else is passed on without being stored.
        if buffer.count == 4, !(buffer == Array("133;".utf8) || buffer == Array("633;".utf8)) {
            makeIrrelevant(&out)
        } else if buffer.count > Self.maxLength {
            makeIrrelevant(&out)
        }
    }

    private mutating func makeIrrelevant(_ out: inout Data) {
        relevant = false
        buffer.removeAll(keepingCapacity: true)
        passthrough = true
        flushHeld(&out)
    }

    private mutating func finish(_ found: inout [OSCSequence], _ out: inout Data) {
        defer {
            buffer.removeAll(keepingCapacity: true)
            held = []
            passthrough = false
            state = .ground
        }
        if relevant, buffer.count >= 4, let code = Int(String(decoding: buffer[0..<3], as: UTF8.self)) {
            found.append(OSCSequence(code: code, payload: String(decoding: buffer[4...], as: UTF8.self)))
            return      // a mark: its bytes are dropped
        }
        flushHeld(&out)
    }
}
#endif
