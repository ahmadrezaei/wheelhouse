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
    /// A mark longer than ``maxLength``: swallowed without being kept.
    private var overflowed = false

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
                    case Self.can, Self.sub: emit(byte, &out); abandon()
                    default: emit(byte, &out); append(byte, &out)
                    }
                case .oscEscape:
                    if byte == Self.backslash { emit(byte, &out); finish(&found, &out) }
                    else if byte == Self.rightBracket {
                        // A new sequence starts. The ESC that began it is the last byte emitted; take it back out of whichever buffer holds it.
                        // A mark that was cut short is dropped, never passed on: the terminal would act on it when the ESC ends it.
                        if passthrough { out.removeLast() } else { held = [] }
                        held = [Self.esc, byte]
                        begin()
                    } else if passthrough {
                        out.append(byte)
                        abandon()
                    } else {
                        // The mark body is dropped; the ESC and the byte after it are ordinary output again.
                        out.append(Self.esc)
                        out.append(byte)
                        abandon()
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
        overflowed = false
    }

    /// The sequence was cut short. Bytes of one that was ours are dropped, never passed on.
    private mutating func abandon() {
        held = []
        buffer.removeAll(keepingCapacity: true)
        passthrough = false
        overflowed = false
        state = .ground
    }

    private mutating func append(_ byte: UInt8, _ out: inout Data) {
        guard relevant, !overflowed else { return }
        buffer.append(byte)
        // Each of the first four bytes must continue `133;` or `633;`; the first that does not makes the sequence somebody else's, and its
        // bytes go straight through. A sequence that is ours is held and, one way or another, never reaches the terminal.
        if buffer.count <= 4, !(Array("133;".utf8).starts(with: buffer) || Array("633;".utf8).starts(with: buffer)) {
            makeIrrelevant(&out)
        } else if buffer.count > Self.maxLength {
            // Too long to keep: swallowed up to its terminator.
            overflowed = true
            buffer.removeAll(keepingCapacity: true)
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
            overflowed = false
            state = .ground
        }
        if relevant, !overflowed, buffer.count >= 4, let code = Int(String(decoding: buffer[0..<3], as: UTF8.self)) {
            found.append(OSCSequence(code: code, payload: String(decoding: buffer[4...], as: UTF8.self)))
            return      // a mark: its bytes are dropped
        }
        // A short sequence that is not a mark (`ESC ] 1 BEL`, OSC 1) goes on; `ESC ] 1 3 3 BEL` is the mark's own code and is dropped.
        if !overflowed, buffer.count < 4, buffer != Array("133".utf8), buffer != Array("633".utf8) { flushHeld(&out) }
    }
}
#endif
