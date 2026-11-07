import SwiftUI

public enum CodeLanguage: Sendable { case plain, yaml, json }

/// Maps source text to a styled string. Supply your own for logs, diffs or other languages.
public typealias SyntaxHighlighter = @Sendable (String) -> AttributedString

public enum CodeHighlighters {
    public static func highlighter(for language: CodeLanguage) -> SyntaxHighlighter? {
        switch language {
        case .plain: nil
        case .yaml: yaml
        case .json: json
        }
    }

    /// Line-based YAML highlighting: keys, strings, numbers, booleans/null, comments.
    public static let yaml: SyntaxHighlighter = { text in
        var out = AttributedString()
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += highlightYAMLLine(String(line))
        }
        return out
    }

    public static let json: SyntaxHighlighter = { text in
        var out = AttributedString()
        var token = ""
        var inString = false
        func flush() {
            guard !token.isEmpty else { return }
            var a = AttributedString(token)
            let t = token.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"") { a.foregroundColor = .green }
            else if ["true", "false", "null"].contains(t) { a.foregroundColor = .orange }
            else if Double(t) != nil { a.foregroundColor = .purple }
            out += a
            token = ""
        }
        var escaped = false
        for ch in text {
            if inString {
                token.append(ch)
                if escaped { escaped = false } else if ch == "\\" { escaped = true } else if ch == "\"" { inString = false; flush() }
            } else if ch == "\"" { flush(); token.append(ch); inString = true }
            else if "{}[],:\n ".contains(ch) { flush(); out += AttributedString(String(ch)) }
            else { token.append(ch) }
        }
        flush()
        return out
    }

    private static func scalar(_ s: String) -> AttributedString {
        var a = AttributedString(s)
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("\"") || t.hasPrefix("'") { a.foregroundColor = .green }
        else if ["true", "false", "null", "~", "True", "False"].contains(t) { a.foregroundColor = .orange }
        else if Double(t) != nil { a.foregroundColor = .purple }
        return a
    }

    private static func highlightYAMLLine(_ line: String) -> AttributedString {
        let trimmed = line.drop { $0 == " " }
        if trimmed.hasPrefix("#") { var a = AttributedString(line); a.foregroundColor = .secondary; return a }
        var rest = Substring(line)
        var out = AttributedString()
        let indent = line.prefix { $0 == " " }
        out += AttributedString(String(indent)); rest = rest.dropFirst(indent.count)
        if rest.hasPrefix("- ") { out += AttributedString("- "); rest = rest.dropFirst(2) }
        let keyEnd: Substring.Index? = rest.hasSuffix(":") ? rest.index(before: rest.endIndex) : rest.range(of: ": ")?.lowerBound
        if let keyEnd, !rest.hasPrefix("{"), !rest.hasPrefix("["), !rest[..<keyEnd].contains(" ") {
            var key = AttributedString(String(rest[...keyEnd]))
            key.foregroundColor = Color(red: 0.05, green: 0.56, blue: 0.54)
            out += key
            out += scalar(String(rest[rest.index(after: keyEnd)...]))
            return out
        }
        out += scalar(String(rest))
        return out
    }
}

/// Monospaced, selectable code box with an optional syntax-highlight hook and line numbers.
public struct CodeView: View {
    private let text: String
    private let language: CodeLanguage
    private let highlighter: SyntaxHighlighter?
    private let showsLineNumbers: Bool
    private let wraps: Bool

    public init(_ text: String, language: CodeLanguage = .plain, highlighter: SyntaxHighlighter? = nil, showsLineNumbers: Bool = false, wraps: Bool = false) {
        self.text = text
        self.language = language
        self.highlighter = highlighter
        self.showsLineNumbers = showsLineNumbers
        self.wraps = wraps
    }

    private var attributed: AttributedString {
        (highlighter ?? CodeHighlighters.highlighter(for: language))?(text) ?? AttributedString(text)
    }

    public var body: some View {
        ScrollView(wraps ? .vertical : [.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 10) {
                if showsLineNumbers {
                    Text((1...max(1, text.split(separator: "\n", omittingEmptySubsequences: false).count)).map(String.init).joined(separator: "\n"))
                        .font(.whCodeSmall).foregroundStyle(.tertiary).multilineTextAlignment(.trailing)
                        .accessibilityHidden(true)
                }
                Text(attributed).font(.whCode).textSelection(.enabled).fixedSize(horizontal: !wraps, vertical: true)
                    .frame(maxWidth: wraps ? .infinity : nil, alignment: .leading)
            }
            .padding(12)
        }
        .background(Color.whCardBackground, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
        .scrollEdgeEffectStyle(.hard, for: .all)
    }
}
