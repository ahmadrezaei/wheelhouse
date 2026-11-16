import Foundation

/// A pack template such as `cmctl renew {{name}} -n {{namespace}}` (ARCHITECTURE-MAC section 11).
///
/// Only `{{variable}}` substitution exists, and only for an allowlist fixed when the template is parsed. For terminal text two layers
/// apply. First, a value must be made of plain characters (`A-Z a-z 0-9 . _ : / @ = + , % -`), so no value can mean anything to
/// any shell (bash, zsh, fish and tcsh read quotes differently). Second, it is wrapped in single quotes anyway. A template that
/// would put a variable anywhere but in an argument position of plain unquoted text is rejected when the pack loads. A value that is
/// not safe is refused, never "cleaned": the text that was previewed is the text that is inserted.
public struct RiggingTemplate: Hashable, Sendable {
    public enum Mode: Sendable { case shell, plain }

    enum Part: Hashable, Sendable {
        case literal(String)
        case variable(name: String, atWordStart: Bool)
    }

    public struct TemplateError: Error, Equatable, Sendable, LocalizedError {
        public var message: String
        public var errorDescription: String? { message }
    }

    /// The variables every pack may use; a view adds the names of its own `fields`.
    public static let baseVariables: Set<String> = ["name", "namespace", "cluster", "kind", "localPort"]
    public static let maxLength = 2000
    public static let maxValueLength = 1024

    public let source: String
    public let mode: Mode
    let parts: [Part]

    public var variables: [String] {
        var seen = Set<String>()
        return parts.compactMap { if case .variable(let n, _) = $0, seen.insert(n).inserted { n } else { nil } }
    }

    public init(_ text: String, mode: Mode, allowed: Set<String>) throws {
        try self.init(text, mode: mode, allowed: allowed, programs: Self.allowedPrograms)
    }

    /// `programs` is only varied by tests that need a harmless program to run through a real shell.
    init(_ text: String, mode: Mode, allowed: Set<String>, programs: Set<String>) throws {
        guard text.utf8.count <= Self.maxLength else { throw TemplateError(message: "A template may be at most \(Self.maxLength) bytes.") }
        var parts: [Part] = []
        var literal = ""
        var rest = Substring(text)
        while let open = rest.range(of: "{{") {
            literal += rest[..<open.lowerBound]
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "}}") else { throw TemplateError(message: "“{{” has no closing “}}” in “\(text)”.") }
            let name = rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard Self.isVariableName(name) else { throw TemplateError(message: "“{{\(name)}}” is not a variable name.") }
            guard allowed.contains(name) else { throw TemplateError(message: "The variable “\(name)” is not available here.") }
            if !literal.isEmpty { parts.append(.literal(literal)); literal = "" }
            parts.append(.variable(name: name, atWordStart: false))
            rest = rest[close.upperBound...]
        }
        literal += rest
        if literal.contains("}}") { throw TemplateError(message: "A stray “}}” in “\(text)”.") }
        if !literal.isEmpty { parts.append(.literal(literal)) }
        for case .literal(let l) in parts {
            if let bad = l.unicodeScalars.first(where: Self.isUnsafe) {
                throw TemplateError(message: "The template contains a control, hidden or bidirectional character (U+\(String(bad.value, radix: 16, uppercase: true))).")
            }
        }
        self.source = text
        self.mode = mode
        if mode == .shell { try Self.checkCommands(parts, programs: programs) }
        self.parts = mode == .shell ? try Self.checkShell(parts) : parts
    }

    static func isVariableName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, ("a"..."z").contains(first) || ("A"..."Z").contains(first), s.utf8.count <= 40 else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }

    /// Control characters, DEL, C1, format and bidirectional characters, line and paragraph separators, Unicode spaces other than
    /// U+0020, private-use and unassigned code points, and look-alike blanks.
    public static func isUnsafe(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x20 || v == 0x7F || (0x80...0x9F).contains(v) || v == 0x2028 || v == 0x2029 || (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v)
            || v == 0x061C || v == 0x115F || v == 0x1160 || v == 0x3164 || v == 0xFFA0 || v == 0x2800 { return true }
        switch s.properties.generalCategory {
        case .format, .privateUse, .unassigned, .surrogate, .lineSeparator, .paragraphSeparator, .control: return true
        case .spaceSeparator: return v != 0x20
        default: return false
        }
    }

    // MARK: Shell check

    /// Unquoted literal text of a terminal template: plain words, spaces and `|`. Redirections, globs, braces, `~`, `!`, `#`, `$`,
    /// backslashes, backticks, `;`, `&`, parentheses and non-ASCII are refused outside quotes.
    private static let plainLiteral = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _./:=,@%+-|".unicodeScalars)
    /// What may stand directly before a variable: a space or a word character, never a quote or an operator.
    private static let beforeVariable = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _./:=,@%+-".unicodeScalars)
    /// What a shell-mode value may be made of.
    static let plainValue = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:/@=+,%-".unicodeScalars)

    /// Commands that run or re-parse their arguments; a value must not reach them.
    private static let wrappers: Set<String> = ["env", "sudo", "exec", "eval", "command", "builtin", "xargs", "sh", "bash", "zsh", "fish", "dash", "ksh", "ssh", "nohup", "time", "watch", "su", "doas", "timeout", "nice"]

    private static func checkShell(_ parts: [Part]) throws -> [Part] {
        enum State { case plain, single, double }
        var state = State.plain
        var word = ""                 // the current word so far; "q" stands for a quoted piece, "v" for a variable
        var words = 0                 // words started since the start or the last `|`
        var assignments = 0           // leading NAME=value words of the current command (they are not the command)
        var commandWord: String?      // the command's own word, once complete
        var previous: Unicode.Scalar?
        var afterVariable = false
        var out: [Part] = []
        func startWord() { if word.isEmpty { words += 1 } }
        for part in parts {
            switch part {
            case .literal(let text):
                for ch in text.unicodeScalars {
                    guard ch.isASCII else { throw TemplateError(message: "A terminal template may only contain ASCII text.") }
                    switch state {
                    case .plain:
                        if afterVariable, ch == "'" || ch == "\"" { throw TemplateError(message: "A quote cannot directly follow a variable.") }
                        if ch == "'" { startWord(); state = .single; word += "q" }
                        else if ch == "\"" { startWord(); state = .double; word += "q" }
                        else if plainLiteral.contains(ch) {
                            if ch == " " {
                                if word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil, words == assignments + 1 { assignments += 1 }
                                else if words == assignments + 1, !word.isEmpty { commandWord = word }
                                word = ""
                            }
                            else if ch == "|" { word = ""; words = 0; assignments = 0; commandWord = nil }
                            else { startWord(); word.unicodeScalars.append(ch) }
                        } else {
                            throw TemplateError(message: "The character “\(ch)” is not allowed in the unquoted text of a terminal template; put it inside quotes.")
                        }
                    case .single:
                        if ch == "'" { state = .plain }
                    case .double:
                        if ch == "\"" { state = .plain }
                        else if "$`\\!".unicodeScalars.contains(ch) { throw TemplateError(message: "“\(ch)” is not allowed inside double quotes in a terminal template.") }
                    }
                    afterVariable = false
                    previous = ch
                }
                out.append(part)
            case .variable(let name, _):
                guard state == .plain else { throw TemplateError(message: "“{{\(name)}}” must not be inside quotes: Wheelhouse quotes it for you.") }
                guard !afterVariable else { throw TemplateError(message: "Two variables cannot touch: put text between them.") }
                guard let before = previous, beforeVariable.contains(before) else {
                    throw TemplateError(message: "“{{\(name)}}” must follow a space or a word character, not a quote, an operator or the start of the command.")
                }
                if let command = commandWord ?? (words == assignments + 1 && before != " " ? word : nil),
                   Self.wrappers.contains((command as NSString).lastPathComponent) {
                    throw TemplateError(message: "“{{\(name)}}” cannot be an argument of “\(command)”, which runs what it is given.")
                }
                guard words - assignments >= (before == " " ? 1 : 2) else { throw TemplateError(message: "“{{\(name)}}” cannot be the command itself.") }
                if before == "=", word == "=" { throw TemplateError(message: "“{{\(name)}}” cannot follow a leading “=”.") }
                if word.range(of: "^[A-Za-z_][A-Za-z0-9_]*=", options: .regularExpression) != nil {
                    throw TemplateError(message: "“{{\(name)}}” cannot be the value of a variable assignment.")
                }
                out.append(.variable(name: name, atWordStart: before == " "))
                startWord()
                word += "v"
                afterVariable = true
                previous = "v"
            }
        }
        guard state == .plain else { throw TemplateError(message: "The template has an unclosed quote.") }
        return out
    }

    // MARK: Command allow-list

    /// The only programs a terminal template may start (in every `|` segment). Nothing here runs code from its arguments.
    static let allowedPrograms: Set<String> = ["kubectl", "cmctl", "istioctl", "velero"]
    /// What `kubectl` may do from a pack: read-only subcommands and the one plugin the built-in packs use. An unknown name would run a
    /// `kubectl-<name>` found on PATH, and `config`, `cp`, `proxy`, `create`, `apply` and `krew` reach credentials, local files or the network.
    static let allowedKubectl: Set<String> = ["get", "describe", "logs", "top", "events", "explain", "api-resources", "api-versions", "rollout", "cnpg"]
    static let allowedRollout: Set<String> = ["status", "history"]
    /// Flags that choose another identity, cluster, server, credentials or local file. Matched as a prefix, so `--as-uid` and `--kube-token` are caught.
    private static let deniedFlagPrefixes = ["--as", "--context", "--cluster", "--user", "--kube", "--server", "--token", "--insecure", "--certificate", "--client-", "--tls-",
                                              "--cache-dir", "--profile", "--password", "--address", "--raw", "--from-file", "--filename", "--local"]
    private static let marker: Character = "\u{1}"

    private struct Word { var text = ""; var quoted = false }

    /// A terminal template may only start allow-listed programs, and may not select another cluster, identity or credentials,
    /// whether or not it has a variable. Quoted and assembled words (`--kube{{x}}`, `-s{{x}}`, `'sh' -c`) are refused.
    private static func checkCommands(_ parts: [Part], programs: Set<String>) throws {
        var text = ""
        for part in parts {
            switch part {
            case .literal(let l): text += l
            case .variable: text.append(marker)
            }
        }
        var segments: [[Word]] = [[]]
        var current: Word?
        var quote: Character?
        func finish() { if let word = current { segments[segments.count - 1].append(word); current = nil } }
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil } else { current?.text.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"":
                quote = ch
                if current == nil { current = Word() }
                current?.quoted = true
            case " ": finish()
            case "|": finish(); segments.append([])
            default:
                if current == nil { current = Word() }
                current?.text.append(ch)
            }
        }
        finish()
        for words in segments { try checkSegment(words, programs: programs) }
    }

    private static func checkSegment(_ words: [Word], programs: Set<String>) throws {
        guard let first = words.first else { throw TemplateError(message: "A terminal template has an empty command (check the “|”).") }
        guard !first.quoted, programs.contains(first.text) else {
            throw TemplateError(message: "A terminal template may only start kubectl, cmctl, istioctl or velero (not “\(first.text.replacingOccurrences(of: String(marker), with: "{{…}}"))”).")
        }
        if first.text == "kubectl" {
            guard words.count > 1, !words[1].quoted, allowedKubectl.contains(words[1].text) else {
                throw TemplateError(message: "kubectl in a terminal template may only use get, describe, logs, top, events, explain, api-resources, api-versions, rollout status|history or the cnpg plugin.")
            }
            if words[1].text == "rollout", !(words.count > 2 && allowedRollout.contains(words[2].text)) {
                throw TemplateError(message: "kubectl rollout in a terminal template may only be “status” or “history”.")
            }
        }
        for word in words.dropFirst() {
            let w = word.text
            if w.hasPrefix("--") {
                let name = w.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? w
                if name.contains(marker) { throw TemplateError(message: "A variable cannot be part of a flag name.") }
                if deniedFlagPrefixes.contains(where: { name.hasPrefix($0) }) {
                    throw TemplateError(message: "“\(name)” selects another cluster, identity, server or local file and is not allowed in a terminal template.")
                }
            } else if w.hasPrefix("-"), w != "-" {
                if w.contains(marker), !w.contains("=") { throw TemplateError(message: "A variable cannot be glued to a flag; put a space before it.") }
                let body = w.dropFirst()
                let isShort = body.count == 1 && (body.first?.isLetter ?? false)
                let isOutput = body.hasPrefix("o") && body.dropFirst().allSatisfy { $0.isLetter || $0 == "=" || $0 == "-" || $0 == "." || $0 == marker }
                guard isShort || isOutput else {
                    throw TemplateError(message: "The flag “\(w)” is not allowed in a terminal template; write each short flag on its own (such as -n or -A).")
                }
                if body == "s" || (body == "c" && first.text == "istioctl") {
                    throw TemplateError(message: "“\(w)” selects a server or kubeconfig and is not allowed in a terminal template.")
                }
            }
        }
    }

    // MARK: Rendering

    /// The text with every variable replaced. Throws when a variable has no value or its value is not safe to insert.
    public func render(_ values: [String: String]) throws -> String {
        var out = ""
        for part in parts {
            switch part {
            case .literal(let text): out += text
            case .variable(let name, let atWordStart):
                guard let value = values[name] else { throw TemplateError(message: "“\(name)” has no value for this object.") }
                try Self.check(value, name: name)
                switch mode {
                case .plain: out += value
                case .shell:
                    guard !value.isEmpty, value.unicodeScalars.allSatisfy(Self.plainValue.contains) else {
                        throw TemplateError(message: "The value of “\(name)” has characters a terminal could read as something else, so it cannot be inserted.")
                    }
                    if atWordStart, value.hasPrefix("-") { throw TemplateError(message: "The value of “\(name)” starts with “-” and would be read as an option.") }
                    out += Self.shellQuote(value)
                }
            }
        }
        return out
    }

    /// `'value'` with each `'` written as `'\''`. The second layer of quoting (values are already restricted to plain characters).
    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func check(_ value: String, name: String) throws {
        guard value.utf8.count <= maxValueLength else { throw TemplateError(message: "The value of “\(name)” is too long.") }
        if value.unicodeScalars.contains(where: isUnsafe) {
            throw TemplateError(message: "The value of “\(name)” contains a control, hidden or bidirectional character, so it cannot be inserted.")
        }
    }
}

/// The values a template may use, built from the object, the cluster and the view's declared fields. Names are checked against the
/// Kubernetes naming rules here, so a pack cannot be made to insert text that is not a real object name.
public enum RiggingValues {
    public struct Subject: Sendable {
        public var name: String?
        public var namespace: String?
        public var kind: String?
        public var raw: JSONValue?
        public init(name: String? = nil, namespace: String? = nil, kind: String? = nil, raw: JSONValue? = nil) {
            self.name = name
            self.namespace = namespace
            self.kind = kind
            self.raw = raw
        }
    }

    /// Variables with a value. A variable with no value (a cluster-scoped object has no `namespace`) is simply absent, which makes a
    /// template that needs it fail to render.
    public static func make(subject: Subject?, cluster: String, fields: [RiggingPack.Field] = [], localPort: Int? = nil) -> [String: String] {
        var out: [String: String] = ["cluster": cluster]
        // Secret objects never feed a template, whatever a pack declares.
        if let subject, subject.kind?.lowercased() != "secret" {
            if let name = subject.name, KubeNames.isObjectName(name) { out["name"] = name }
            if let ns = subject.namespace, KubeNames.isDNSLabel(ns) { out["namespace"] = ns }
            if let kind = subject.kind, isKindName(kind) { out["kind"] = kind }
            if let raw = subject.raw {
                for field in fields where !RiggingTemplate.baseVariables.contains(field.name) {
                    guard let path = try? JSONPathSubset(field.path), let text = path.text(in: raw) else { continue }
                    out[field.name] = text
                }
            }
        }
        if let localPort, (1...65535).contains(localPort) { out["localPort"] = String(localPort) }
        return out
    }

    static func isKindName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, ("A"..."Z").contains(first) || ("a"..."z").contains(first), s.utf8.count <= 63 else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) }
    }
}
