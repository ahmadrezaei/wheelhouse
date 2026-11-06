import Foundation

public enum TermColor: Hashable, Sendable {
    case `default`
    case indexed(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

public struct TermAttributes: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let bold = TermAttributes(rawValue: 1)
    public static let dim = TermAttributes(rawValue: 2)
    public static let italic = TermAttributes(rawValue: 4)
    public static let underline = TermAttributes(rawValue: 8)
    public static let inverse = TermAttributes(rawValue: 16)
    public static let strike = TermAttributes(rawValue: 32)
}

public struct TermStyle: Hashable, Sendable {
    public var fg: TermColor = .default
    public var bg: TermColor = .default
    public var attrs: TermAttributes = []
    public init() {}
}

public struct TermCell: Hashable, Sendable {
    public var char: Character = " "
    public var style = TermStyle()
    /// True for the right half of a double-width character (not drawn).
    public var isContinuation = false
    public init() {}
    public init(char: Character, style: TermStyle) { self.char = char; self.style = style }
    public var isBlank: Bool { char == " " && style == TermStyle() }
}

/// A compact VT100/xterm-subset terminal emulator: a character grid plus an escape-sequence parser.
///
/// Supported: C0 controls, cursor movement (CSI A B C D E F G H f d), erase (J K X), insert/delete lines and characters
/// (L M @ P), scrolling (S T, DECSTBM regions, IND/RI/NEL), SGR (16 / 256 / truecolour, bold, dim, italic, underline,
/// inverse), save/restore cursor, alternate screen (47, 1047, 1049), auto-wrap, cursor visibility, application cursor
/// keys, bracketed paste *mode tracking*, OSC titles, DSR/DA replies. Unknown sequences are ignored.
public final class TerminalEmulator {
    public private(set) var cols: Int
    public private(set) var rows: Int
    public private(set) var grid: [[TermCell]]
    public private(set) var scrollback: [[TermCell]] = []
    public var scrollbackLimit = 2000
    public private(set) var cursorX = 0
    public private(set) var cursorY = 0
    public private(set) var cursorVisible = true
    public private(set) var applicationCursorKeys = false
    public private(set) var bracketedPaste = false
    public private(set) var usingAlternateScreen = false
    public private(set) var title = ""
    /// Incremented after every `feed`/`resize` that changed the screen.
    public private(set) var revision = 0
    /// Replies the terminal must send back to the remote side (cursor position reports, device attributes).
    public var onResponse: (([UInt8]) -> Void)?

    // State
    private var style = TermStyle()
    private var pendingWrap = false
    private var autoWrap = true
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor = (x: 0, y: 0, style: TermStyle(), wrap: false)
    private var mainSaved: (grid: [[TermCell]], x: Int, y: Int, style: TermStyle)?
    private var tabStops: Set<Int> = []

    // Parser
    private enum Mode { case ground, escape, escapeIntermediate, csi, osc, oscEscape, ignoreString, ignoreStringEscape }
    private var mode = Mode.ground
    private var params: [Int] = []
    private var currentParam: Int?
    private var privatePrefix: UInt8?
    private var intermediates: [UInt8] = []
    private var oscBuffer: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Need = 0

    public init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        self.grid = Array(repeating: Array(repeating: TermCell(), count: max(1, cols)), count: max(1, rows))
        self.scrollBottom = max(1, rows) - 1
        resetTabStops()
    }

    // MARK: Public API

    public func feed(_ data: Data) { feed(Array(data)) }

    public func feed(_ bytes: [UInt8]) {
        for b in bytes { process(b) }
        revision &+= 1
    }

    public func feed(_ string: String) { feed(Array(string.utf8)) }

    public func reset() {
        style = TermStyle(); mode = .ground; params = []; currentParam = nil
        usingAlternateScreen = false; mainSaved = nil
        grid = blankGrid(cols: cols, rows: rows)
        scrollback.removeAll()
        cursorX = 0; cursorY = 0; pendingWrap = false; autoWrap = true; cursorVisible = true
        applicationCursorKeys = false; bracketedPaste = false
        scrollTop = 0; scrollBottom = rows - 1
        resetTabStops()
        revision &+= 1
    }

    public func resize(cols newCols: Int, rows newRows: Int) {
        let c = max(1, newCols), r = max(1, newRows)
        guard c != cols || r != rows else { return }
        var g = grid
        // Shrinking vertically: keep the cursor line visible by pushing top lines into scrollback.
        if r < rows, cursorY >= r {
            let shift = cursorY - r + 1
            if !usingAlternateScreen { for i in 0..<shift { pushScrollback(g[i]) } }
            g.removeFirst(shift)
            cursorY -= shift
        }
        while g.count > r { g.removeLast() }
        while g.count < r { g.append(blankRow(c)) }
        for i in g.indices {
            if g[i].count > c { g[i].removeLast(g[i].count - c) }
            else if g[i].count < c { g[i].append(contentsOf: Array(repeating: TermCell(), count: c - g[i].count)) }
        }
        grid = g
        cols = c; rows = r
        cursorX = min(cursorX, c - 1); cursorY = min(cursorY, r - 1)
        pendingWrap = false
        scrollTop = 0; scrollBottom = r - 1
        resetTabStops()
        revision &+= 1
    }

    /// Number of addressable lines: scrollback plus the screen.
    public var totalLines: Int { scrollback.count + rows }

    /// Line by absolute index (0 = oldest scrollback line).
    public func line(at index: Int) -> [TermCell] {
        if index < scrollback.count { return scrollback[index] }
        let r = index - scrollback.count
        return r < grid.count ? grid[r] : blankRow(cols)
    }

    /// Plain text of a line with trailing spaces trimmed.
    public func text(ofLine index: Int) -> String {
        var s = ""
        for cell in line(at: index) where !cell.isContinuation { s.append(cell.char) }
        while s.last == " " { s.removeLast() }
        return s
    }

    /// Text of the visible screen.
    public func screenText() -> String {
        (0..<rows).map { text(ofLine: scrollback.count + $0) }.joined(separator: "\n")
    }

    /// Scrollback and screen as text, trailing blank lines removed.
    public func allText() -> String {
        var lines = (0..<totalLines).map { text(ofLine: $0) }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Grid helpers

    private func blankCell() -> TermCell {
        var c = TermCell()
        c.style.bg = style.bg
        return c
    }
    private func blankRow(_ width: Int) -> [TermCell] { Array(repeating: blankCell(), count: width) }
    private func blankGrid(cols: Int, rows: Int) -> [[TermCell]] { Array(repeating: Array(repeating: TermCell(), count: cols), count: rows) }
    private func resetTabStops() { tabStops = Set(stride(from: 8, to: cols, by: 8)) }

    private func pushScrollback(_ row: [TermCell]) {
        scrollback.append(row)
        if scrollback.count > scrollbackLimit { scrollback.removeFirst(scrollback.count - scrollbackLimit) }
    }

    private func scrollUp(_ n: Int = 1) {
        let count = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<count {
            let removed = grid.remove(at: scrollTop)
            if scrollTop == 0 && !usingAlternateScreen { pushScrollback(removed) }
            grid.insert(blankRow(cols), at: scrollBottom)
        }
    }

    private func scrollDown(_ n: Int = 1) {
        let count = min(n, scrollBottom - scrollTop + 1)
        for _ in 0..<count {
            grid.remove(at: scrollBottom)
            grid.insert(blankRow(cols), at: scrollTop)
        }
    }

    private func index() {
        if cursorY == scrollBottom { scrollUp() } else if cursorY < rows - 1 { cursorY += 1 }
    }

    private func reverseIndex() {
        if cursorY == scrollTop { scrollDown() } else if cursorY > 0 { cursorY -= 1 }
    }

    // MARK: Printing

    private static func isWide(_ v: UInt32) -> Bool {
        (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v) || (0xAC00...0xD7A3).contains(v) ||
        (0xF900...0xFAFF).contains(v) || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v) ||
        (0xFFE0...0xFFE6).contains(v) || (0x1F300...0x1F64F).contains(v) || (0x1F900...0x1F9FF).contains(v) ||
        (0x20000...0x3FFFD).contains(v)
    }

    private func print(_ scalar: Unicode.Scalar) {
        let cat = scalar.properties.generalCategory
        if cat == .nonspacingMark || cat == .enclosingMark || scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) {
            // Combine with the previous cell.
            let px = pendingWrap ? cursorX : cursorX - 1
            if px >= 0 {
                var base = grid[cursorY][px]
                base.char = Character(String(base.char) + String(scalar))
                grid[cursorY][px] = base
            }
            return
        }
        let wide = Self.isWide(scalar.value)
        let width = wide ? 2 : 1
        if pendingWrap {
            if autoWrap { cursorX = 0; index() }
            pendingWrap = false
        }
        if cursorX + width > cols {
            if autoWrap { cursorX = 0; index() } else { cursorX = cols - width }
        }
        grid[cursorY][cursorX] = TermCell(char: Character(scalar), style: style)
        if wide, cursorX + 1 < cols {
            var cont = TermCell(char: " ", style: style)
            cont.isContinuation = true
            grid[cursorY][cursorX + 1] = cont
        }
        cursorX += width
        if cursorX >= cols { cursorX = cols - 1; pendingWrap = true }
    }

    // MARK: Parser

    private func process(_ b: UInt8) {
        switch mode {
        case .ground: ground(b)
        case .escape: escape(b)
        case .escapeIntermediate:
            // Charset designations (ESC ( B etc.): consume the final byte.
            intermediates.removeAll(); mode = .ground
        case .csi: csi(b)
        case .osc:
            if b == 0x07 { finishOSC() }
            else if b == 0x1B { mode = .oscEscape }
            else if oscBuffer.count < 2048 { oscBuffer.append(b) }
        case .oscEscape:
            finishOSC()
            if b != UInt8(ascii: "\\") { escape(b) }
        case .ignoreString:
            if b == 0x07 { mode = .ground } else if b == 0x1B { mode = .ignoreStringEscape }
        case .ignoreStringEscape:
            mode = .ground
            if b != UInt8(ascii: "\\") { escape(b) }
        }
    }

    private func ground(_ b: UInt8) {
        if utf8Need > 0 {
            if b & 0xC0 == 0x80 {
                utf8.append(b); utf8Need -= 1
                if utf8Need == 0 {
                    if let s = String(bytes: utf8, encoding: .utf8)?.unicodeScalars.first { print(s) }
                    utf8.removeAll()
                }
                return
            }
            utf8.removeAll(); utf8Need = 0 // malformed: fall through and treat as new byte
        }
        switch b {
        case 0x00, 0x7F: break
        case 0x07: break // BEL
        case 0x08: // BS
            if cursorX > 0 { cursorX -= 1 }
            pendingWrap = false
        case 0x09: // HT
            var x = cursorX + 1
            while x < cols - 1 && !tabStops.contains(x) { x += 1 }
            cursorX = min(x, cols - 1)
            pendingWrap = false
        case 0x0A, 0x0B, 0x0C: // LF VT FF
            index(); pendingWrap = false
        case 0x0D: // CR
            cursorX = 0; pendingWrap = false
        case 0x0E, 0x0F: break // SO SI
        case 0x1B:
            mode = .escape
        case 0x20...0x7E:
            print(Unicode.Scalar(b))
        case 0xC2...0xDF: utf8 = [b]; utf8Need = 1
        case 0xE0...0xEF: utf8 = [b]; utf8Need = 2
        case 0xF0...0xF4: utf8 = [b]; utf8Need = 3
        default: break
        }
    }

    private func escape(_ b: UInt8) {
        mode = .ground
        switch b {
        case UInt8(ascii: "["):
            mode = .csi; params = []; currentParam = nil; privatePrefix = nil; intermediates = []
        case UInt8(ascii: "]"):
            mode = .osc; oscBuffer = []
        case UInt8(ascii: "P"), UInt8(ascii: "X"), UInt8(ascii: "^"), UInt8(ascii: "_"):
            mode = .ignoreString
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"), UInt8(ascii: "#"), UInt8(ascii: " "), UInt8(ascii: "%"):
            mode = .escapeIntermediate
        case UInt8(ascii: "7"): savedCursor = (cursorX, cursorY, style, pendingWrap)
        case UInt8(ascii: "8"): cursorX = savedCursor.x; cursorY = savedCursor.y; style = savedCursor.style; pendingWrap = savedCursor.wrap
        case UInt8(ascii: "D"): index()
        case UInt8(ascii: "E"): cursorX = 0; index()
        case UInt8(ascii: "M"): reverseIndex()
        case UInt8(ascii: "H"): tabStops.insert(cursorX)
        case UInt8(ascii: "c"): reset()
        case UInt8(ascii: "="), UInt8(ascii: ">"): break
        case 0x1B: mode = .escape
        default: break
        }
    }

    private func csi(_ b: UInt8) {
        switch b {
        case 0x30...0x39: // digit
            currentParam = min((currentParam ?? 0) * 10 + Int(b - 0x30), 65535)
        case UInt8(ascii: ";"), UInt8(ascii: ":"):
            params.append(currentParam ?? -1); currentParam = nil
        case 0x3C...0x3F: // < = > ?
            privatePrefix = b
        case 0x20...0x2F:
            intermediates.append(b)
        case 0x40...0x7E:
            if currentParam != nil || !params.isEmpty { params.append(currentParam ?? -1) }
            currentParam = nil
            dispatchCSI(final: b)
            mode = .ground
        case 0x1B: mode = .escape
        case 0x18, 0x1A: mode = .ground
        case 0x0A, 0x0D, 0x08, 0x09: // C0 controls act immediately inside sequences
            ground(b)
        default: break
        }
    }

    private func finishOSC() {
        mode = .ground
        let text = String(decoding: oscBuffer, as: UTF8.self)
        if let semi = text.firstIndex(of: ";"), let code = Int(text[..<semi]), code == 0 || code == 2 {
            title = String(text[text.index(after: semi)...])
        }
    }

    private func param(_ i: Int, default d: Int) -> Int {
        guard i < params.count, params[i] > 0 else { return d }
        return params[i]
    }

    private func dispatchCSI(final: UInt8) {
        if privatePrefix == UInt8(ascii: "?") || privatePrefix == UInt8(ascii: ">") || privatePrefix == UInt8(ascii: "=") {
            switch final {
            case UInt8(ascii: "h"), UInt8(ascii: "l"):
                if privatePrefix == UInt8(ascii: "?") { setPrivateModes(on: final == UInt8(ascii: "h")) }
            case UInt8(ascii: "c"):
                if privatePrefix == UInt8(ascii: ">") { onResponse?(Array("\u{1B}[>0;276;0c".utf8)) }
            default: break
            }
            return
        }
        if final != UInt8(ascii: "m") { pendingWrap = false }
        switch final {
        case UInt8(ascii: "A"): cursorY = max(scrollTop <= cursorY ? scrollTop : 0, cursorY - param(0, default: 1))
        case UInt8(ascii: "B"): cursorY = min(cursorY <= scrollBottom ? scrollBottom : rows - 1, cursorY + param(0, default: 1))
        case UInt8(ascii: "C"), UInt8(ascii: "a"): cursorX = min(cols - 1, cursorX + param(0, default: 1))
        case UInt8(ascii: "D"): cursorX = max(0, cursorX - param(0, default: 1))
        case UInt8(ascii: "E"): cursorY = min(rows - 1, cursorY + param(0, default: 1)); cursorX = 0
        case UInt8(ascii: "F"): cursorY = max(0, cursorY - param(0, default: 1)); cursorX = 0
        case UInt8(ascii: "G"), UInt8(ascii: "`"): cursorX = min(cols - 1, param(0, default: 1) - 1)
        case UInt8(ascii: "H"), UInt8(ascii: "f"):
            cursorY = min(rows - 1, param(0, default: 1) - 1)
            cursorX = min(cols - 1, param(1, default: 1) - 1)
        case UInt8(ascii: "d"): cursorY = min(rows - 1, param(0, default: 1) - 1)
        case UInt8(ascii: "J"): eraseDisplay(params.first ?? 0)
        case UInt8(ascii: "K"): eraseLine(params.first ?? 0)
        case UInt8(ascii: "L"): // IL
            if cursorY >= scrollTop && cursorY <= scrollBottom {
                for _ in 0..<min(param(0, default: 1), scrollBottom - cursorY + 1) {
                    grid.remove(at: scrollBottom); grid.insert(blankRow(cols), at: cursorY)
                }
                cursorX = 0
            }
        case UInt8(ascii: "M"): // DL
            if cursorY >= scrollTop && cursorY <= scrollBottom {
                for _ in 0..<min(param(0, default: 1), scrollBottom - cursorY + 1) {
                    grid.remove(at: cursorY); grid.insert(blankRow(cols), at: scrollBottom)
                }
                cursorX = 0
            }
        case UInt8(ascii: "@"): // ICH
            let n = min(param(0, default: 1), cols - cursorX)
            grid[cursorY].insert(contentsOf: Array(repeating: blankCell(), count: n), at: cursorX)
            grid[cursorY].removeLast(grid[cursorY].count - cols)
        case UInt8(ascii: "P"): // DCH
            let n = min(param(0, default: 1), cols - cursorX)
            grid[cursorY].removeSubrange(cursorX..<(cursorX + n))
            grid[cursorY].append(contentsOf: Array(repeating: blankCell(), count: n))
        case UInt8(ascii: "X"): // ECH
            let n = min(param(0, default: 1), cols - cursorX)
            for x in cursorX..<(cursorX + n) { grid[cursorY][x] = blankCell() }
        case UInt8(ascii: "S"): scrollUp(param(0, default: 1))
        case UInt8(ascii: "T"): scrollDown(param(0, default: 1))
        case UInt8(ascii: "r"):
            let top = param(0, default: 1) - 1
            let bottom = min(rows, param(1, default: rows)) - 1
            if top < bottom { scrollTop = top; scrollBottom = bottom } else { scrollTop = 0; scrollBottom = rows - 1 }
            cursorX = 0; cursorY = 0
        case UInt8(ascii: "m"): sgr()
        case UInt8(ascii: "s"): savedCursor = (cursorX, cursorY, style, pendingWrap)
        case UInt8(ascii: "u"): cursorX = savedCursor.x; cursorY = savedCursor.y
        case UInt8(ascii: "g"):
            if params.first == 3 { tabStops.removeAll() } else { tabStops.remove(cursorX) }
        case UInt8(ascii: "n"):
            if params.first == 6 { onResponse?(Array("\u{1B}[\(cursorY + 1);\(cursorX + 1)R".utf8)) }
            else if params.first == 5 { onResponse?(Array("\u{1B}[0n".utf8)) }
        case UInt8(ascii: "c"):
            if (params.first ?? 0) == 0 { onResponse?(Array("\u{1B}[?1;2c".utf8)) }
        default: break
        }
    }

    private func setPrivateModes(on: Bool) {
        for p in params {
            switch p {
            case 1: applicationCursorKeys = on
            case 7: autoWrap = on
            case 25: cursorVisible = on
            case 2004: bracketedPaste = on
            case 47, 1047, 1049:
                if on { enterAlternateScreen(save: p == 1049) } else { leaveAlternateScreen(restore: p == 1049) }
            default: break
            }
        }
    }

    private func enterAlternateScreen(save: Bool) {
        guard !usingAlternateScreen else { return }
        mainSaved = (grid, cursorX, cursorY, style)
        grid = blankGrid(cols: cols, rows: rows)
        usingAlternateScreen = true
        scrollTop = 0; scrollBottom = rows - 1
        if save { cursorX = 0; cursorY = 0 }
    }

    private func leaveAlternateScreen(restore: Bool) {
        guard usingAlternateScreen, let saved = mainSaved else { return }
        grid = saved.grid
        // Size may have changed while on the alternate screen.
        while grid.count > rows { grid.removeLast() }
        while grid.count < rows { grid.append(blankRow(cols)) }
        for i in grid.indices {
            if grid[i].count > cols { grid[i].removeLast(grid[i].count - cols) }
            else if grid[i].count < cols { grid[i].append(contentsOf: Array(repeating: TermCell(), count: cols - grid[i].count)) }
        }
        if restore { cursorX = min(saved.x, cols - 1); cursorY = min(saved.y, rows - 1); style = saved.style }
        usingAlternateScreen = false
        mainSaved = nil
        scrollTop = 0; scrollBottom = rows - 1
    }

    private func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseLine(0)
            if cursorY + 1 < rows { for y in (cursorY + 1)..<rows { grid[y] = blankRow(cols) } }
        case 1:
            for y in 0..<cursorY { grid[y] = blankRow(cols) }
            eraseLine(1)
        case 2:
            for y in 0..<rows { grid[y] = blankRow(cols) }
        case 3:
            scrollback.removeAll()
            for y in 0..<rows { grid[y] = blankRow(cols) }
        default: break
        }
    }

    private func eraseLine(_ mode: Int) {
        switch mode {
        case 0: for x in cursorX..<cols { grid[cursorY][x] = blankCell() }
        case 1: for x in 0...min(cursorX, cols - 1) { grid[cursorY][x] = blankCell() }
        case 2: grid[cursorY] = blankRow(cols)
        default: break
        }
    }

    private func sgr() {
        let list = params.isEmpty ? [0] : params
        var i = 0
        while i < list.count {
            let p = list[i] < 0 ? 0 : list[i]
            switch p {
            case 0: style = TermStyle()
            case 1: style.attrs.insert(.bold)
            case 2: style.attrs.insert(.dim)
            case 3: style.attrs.insert(.italic)
            case 4: style.attrs.insert(.underline)
            case 7: style.attrs.insert(.inverse)
            case 9: style.attrs.insert(.strike)
            case 22: style.attrs.subtract([.bold, .dim])
            case 23: style.attrs.remove(.italic)
            case 24: style.attrs.remove(.underline)
            case 27: style.attrs.remove(.inverse)
            case 29: style.attrs.remove(.strike)
            case 30...37: style.fg = .indexed(UInt8(p - 30))
            case 38, 48:
                let isFG = p == 38
                if i + 1 < list.count, list[i + 1] == 5, i + 2 < list.count {
                    let c = TermColor.indexed(UInt8(clamping: max(0, list[i + 2])))
                    if isFG { style.fg = c } else { style.bg = c }
                    i += 2
                } else if i + 1 < list.count, list[i + 1] == 2, i + 4 < list.count {
                    let c = TermColor.rgb(UInt8(clamping: max(0, list[i + 2])), UInt8(clamping: max(0, list[i + 3])), UInt8(clamping: max(0, list[i + 4])))
                    if isFG { style.fg = c } else { style.bg = c }
                    i += 4
                }
            case 39: style.fg = .default
            case 40...47: style.bg = .indexed(UInt8(p - 40))
            case 49: style.bg = .default
            case 90...97: style.fg = .indexed(UInt8(p - 90 + 8))
            case 100...107: style.bg = .indexed(UInt8(p - 100 + 8))
            default: break
            }
            i += 1
        }
    }
}
