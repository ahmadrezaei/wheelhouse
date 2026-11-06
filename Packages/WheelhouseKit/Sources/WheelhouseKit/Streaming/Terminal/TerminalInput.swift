import Foundation

public struct TerminalModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let shift = TerminalModifiers(rawValue: 1)
    public static let alt = TerminalModifiers(rawValue: 2)
    public static let control = TerminalModifiers(rawValue: 4)

    /// xterm modifier parameter (1 + bitmask).
    var xtermParameter: Int { 1 + rawValue }
}

public enum TerminalKey: Hashable, Sendable {
    case up, down, left, right
    case home, end, pageUp, pageDown, insert, delete
    case escape, tab, backTab, enter, backspace
    case function(Int)
}

/// Turns keys and control characters into the bytes a remote terminal expects. Independent of any renderer.
public enum TerminalKeyEncoder {
    public static func bytes(for key: TerminalKey, modifiers: TerminalModifiers = [], applicationCursor: Bool = false) -> [UInt8] {
        let esc: UInt8 = 0x1B
        func csi(_ final: Character, _ number: Int? = nil) -> [UInt8] {
            var out: [UInt8] = [esc, UInt8(ascii: "[")]
            if !modifiers.isEmpty { out += Array("\(number ?? 1);\(modifiers.xtermParameter)".utf8) } else if let number { out += Array("\(number)".utf8) }
            out.append(final.asciiValue ?? 0x7E)
            return out
        }
        func arrow(_ final: Character) -> [UInt8] {
            if applicationCursor && modifiers.isEmpty { return [esc, UInt8(ascii: "O"), final.asciiValue ?? 0] }
            return csi(final)
        }
        switch key {
        case .up: return arrow("A")
        case .down: return arrow("B")
        case .right: return arrow("C")
        case .left: return arrow("D")
        case .home: return applicationCursor && modifiers.isEmpty ? [esc, UInt8(ascii: "O"), UInt8(ascii: "H")] : csi("H")
        case .end: return applicationCursor && modifiers.isEmpty ? [esc, UInt8(ascii: "O"), UInt8(ascii: "F")] : csi("F")
        case .pageUp: return csi("~", 5)
        case .pageDown: return csi("~", 6)
        case .insert: return csi("~", 2)
        case .delete: return csi("~", 3)
        case .escape: return [esc]
        case .tab: return [0x09]
        case .backTab: return [esc, UInt8(ascii: "["), UInt8(ascii: "Z")]
        case .enter: return [0x0D]
        case .backspace: return [0x7F]
        case .function(let n):
            switch n {
            case 1...4: // SS3 P..S
                if modifiers.isEmpty { return [esc, UInt8(ascii: "O"), UInt8(ascii: "P") + UInt8(n - 1)] }
                return Array("\u{1B}[1;\(modifiers.xtermParameter)\(["P", "Q", "R", "S"][n - 1])".utf8)
            case 5...12:
                let codes = [5: 15, 6: 17, 7: 18, 8: 19, 9: 20, 10: 21, 11: 23, 12: 24]
                return csi("~", codes[n])
            default: return []
            }
        }
    }

    /// Control-key mapping for a typed character (`Ctrl+C` → 0x03). Nil when the character has no control form.
    public static func control(_ ch: Character) -> UInt8? {
        guard let a = ch.asciiValue else { return nil }
        switch a {
        case UInt8(ascii: "a")...UInt8(ascii: "z"): return a - UInt8(ascii: "a") + 1
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): return a - UInt8(ascii: "A") + 1
        case UInt8(ascii: "@"), UInt8(ascii: " "): return 0
        case UInt8(ascii: "["): return 0x1B
        case UInt8(ascii: "\\"): return 0x1C
        case UInt8(ascii: "]"): return 0x1D
        case UInt8(ascii: "^"): return 0x1E
        case UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "/"): return 0x1F
        case UInt8(ascii: "?"): return 0x7F
        default: return nil
        }
    }

    /// Text typed with optional sticky/hardware modifiers: Ctrl maps to control codes, Alt prefixes ESC.
    public static func bytes(forText text: String, modifiers: TerminalModifiers) -> [UInt8] {
        var out: [UInt8] = []
        for ch in text {
            var chunk: [UInt8]
            if modifiers.contains(.control), let c = control(ch) { chunk = [c] } else { chunk = Array(String(ch).utf8) }
            if modifiers.contains(.alt) { chunk.insert(0x1B, at: 0) }
            out += chunk
        }
        return out
    }

    /// Wraps pasted text in bracketed-paste markers when the remote application enabled them.
    public static func paste(_ text: String, bracketed: Bool) -> [UInt8] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        let body = Array(normalized.utf8)
        return bracketed ? Array("\u{1B}[200~".utf8) + body + Array("\u{1B}[201~".utf8) : body
    }
}
