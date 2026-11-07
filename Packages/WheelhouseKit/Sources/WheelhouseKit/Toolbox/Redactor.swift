import Foundation

/// The one choke point for every byte that leaves the Mac through First Mate or Beacon (ARCHITECTURE-MAC section 9.3).
///
/// Pure and deterministic: the same input always gives the same output, nothing is read from the network, the keychain or the
/// clock, and applying it twice changes nothing more (placeholders are never re-matched). It removes Secret values, tokens,
/// private keys, certificates, kubeconfig credentials and bearer headers. Replacements are labelled, for example
/// `‹redacted: jwt›`.
public struct Redactor: Sendable {
    public static let placeholderPrefix = "‹redacted"

    /// Environment variable, ConfigMap key and Helm values key names that are masked (section 9.3).
    /// Deliberately broad: a false positive hides a harmless value, a false negative leaks a secret.
    public static let sensitiveNamePattern = "(?i)pass|secret|token|key|credential|dsn|auth"

    /// User-defined patterns from Settings that failed to compile. They are skipped, never fatal.
    public let invalidUserPatterns: [String]
    private let userRules: [Rule]

    public init(userPatterns: [String] = []) {
        var rules: [Rule] = []
        var invalid: [String] = []
        for pattern in userPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                rules.append(Rule(label: "custom", regex: regex) { _, _ in Redactor.mark("custom") })
            } else {
                invalid.append(pattern)
            }
        }
        userRules = rules
        invalidUserPatterns = invalid
    }

    static func mark(_ label: String) -> String { "\(placeholderPrefix): \(label)›" }

    // MARK: Names

    private static let nameRegex = try! NSRegularExpression(pattern: sensitiveNamePattern)

    /// Whether a variable, key or field name looks like it names a secret.
    public static func isSensitiveName(_ name: String) -> Bool {
        nameRegex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
    }

    private static let fieldRegex = try! NSRegularExpression(pattern: "(?i)password|passwd|secret|token|api[_-]?key|private[_-]?key|credential")

    /// Structured fields (custom resource specs, Flux `substitute`, Argo parameters) whose name says the value is a secret.
    /// References to a secret (`secretName`, `tokenSecretRef`, `...Selector`) are names, not values, and stay visible.
    static func endsWithReferenceSuffix(_ key: String) -> Bool {
        key.hasSuffix("Name") || key.hasSuffix("Ref") || key.hasSuffix("Selector")
    }

    public static func isSecretFieldName(_ key: String) -> Bool {
        if endsWithReferenceSuffix(key) { return false }
        return fieldRegex.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil
    }

    // MARK: Text

    /// Redacts content patterns in free text: logs, YAML, events, Helm notes.
    public func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        if Self.looksLikeKubeconfig(text) { return Self.mark("kubeconfig") }
        var out = text
        for rule in Self.builtInRules + userRules { out = rule.apply(to: out) }
        return Self.base64Pass(out)
    }

    private static let base64Token = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/]{40,}={0,2}"#)

    /// Long base64 strings whose decoded text is itself a secret (a PEM, a JWT, a `password=` pair) are replaced whole.
    /// Decoding is bounded, and binary or non-text content is left alone.
    static func base64Pass(_ text: String) -> String {
        let ns = text as NSString
        let matches = base64Token.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            let token = ns.substring(with: match.range)
            guard token.utf8.count <= 24 * 1024 else { continue }
            var padded = token
            while padded.count % 4 != 0 { padded += "=" }
            guard let data = Data(base64Encoded: padded), let decoded = String(data: data, encoding: .utf8) else { continue }
            let hit = decoded.contains("-----BEGIN") || builtInRules.contains { $0.apply(to: decoded) != decoded }
            guard hit, let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: mark("base64 secret"))
        }
        return out
    }

    /// Redacts a log. PEM blocks span lines, so the rules run on the whole text and the result is split again.
    public func redactLog(_ lines: [String]) -> [String] {
        redact(lines.joined(separator: "\n")).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: JSON

    /// Redacts a Kubernetes object (or list) in the context of its kind.
    ///
    /// - Secrets become `{type, keys, sizes}` (no value is ever kept). Lists are handled item by item.
    /// - `metadata.managedFields` is dropped; `last-applied-configuration` is scanned structurally (removed for Secrets).
    /// - Container env entries whose `name` looks sensitive have their literal `value` replaced; `valueFrom` is never resolved.
    /// - ConfigMap `data` is masked by key name and by content; `binaryData` is replaced by its size.
    /// - Every remaining string goes through the content patterns.
    public func resource(_ raw: JSONValue, kind: ResourceKind? = nil) -> JSONValue {
        guard case .object(let obj) = raw else { return walk(raw, parentKey: nil, kindName: nil) }
        let declaredKind = obj["kind"]?.stringValue
        if let items = obj["items"]?.arrayValue, obj["spec"] == nil, obj["data"] == nil {
            // A list envelope. Items of a typed list usually carry no `kind` of their own.
            var itemKind = kind
            if itemKind == nil, let declaredKind, declaredKind.hasSuffix("List") { itemKind = ResourceKind.lookup(String(declaredKind.dropLast(4))) }
            var out = obj
            out["items"] = .array(items.map { resource($0, kind: itemKind) })
            if let meta = obj["metadata"] { out["metadata"] = walk(meta, parentKey: "metadata", kindName: nil) }
            return .object(out)
        }
        let name = declaredKind ?? kind?.kind
        if name == "Secret", kind == nil || kind?.group.isEmpty == true { return secretSummary(raw) }
        if name == "Config", obj["users"] != nil { return .string(Self.mark("kubeconfig")) }
        return walk(raw, parentKey: nil, kindName: name)
    }

    /// `{type, keys, sizes}` for a Secret, built before the values are dropped. Nothing of any value is retained.
    public func secretSummary(_ raw: JSONValue) -> JSONValue {
        guard case .object(let obj) = raw else { return .null }
        var sizes: [String: JSONValue] = [:]
        for (key, value) in obj["data"]?.objectValue ?? [:] { sizes[key] = .int(Self.decodedBase64Size(value.stringValue ?? "")) }
        for (key, value) in obj["binaryData"]?.objectValue ?? [:] { sizes[key] = .int(Self.decodedBase64Size(value.stringValue ?? "")) }
        for (key, value) in obj["stringData"]?.objectValue ?? [:] { sizes[key] = .int(value.stringValue?.utf8.count ?? 0) }
        let meta = walk(SecretRedaction.strip(raw)["metadata"] ?? .object([:]), parentKey: "metadata", kindName: "Secret")
        var out: [String: JSONValue] = [
            "kind": "Secret",
            "metadata": meta,
            "keys": .array(sizes.keys.sorted().map { .string($0) }),
            "sizes": .object(sizes),
            "values": .string(Self.mark("secret values are never sent")),
        ]
        if let apiVersion = obj["apiVersion"] { out["apiVersion"] = apiVersion }
        if let type = obj["type"]?.stringValue { out["type"] = .string(type) }
        return .object(out)
    }

    static func isMaskableScalar(_ value: JSONValue) -> Bool {
        switch value {
        case .string(let s): !s.isEmpty && !s.hasPrefix(placeholderPrefix)
        case .int, .double: true
        default: false
        }
    }

    /// An env-style pair: a literal `value` next to a `name` that looks sensitive. `valueFrom` is never touched.
    static func maskingEnvPair(_ o: [String: JSONValue]) -> [String: JSONValue] {
        guard let name = o["name"]?.stringValue, isSensitiveName(name), let value = o["value"], isMaskableScalar(value) else { return o }
        var copy = o
        copy["value"] = .string(mark("env value"))
        return copy
    }

    /// The final pass over every tool result, providers' included:
    /// - content patterns on every string;
    /// - env-style `{name, value}` pairs with a sensitive name;
    /// - any non-empty scalar under a secret-like field name, and everything nested below such a key (`password: {value: x}`).
    ///   A key that ends in `Name`, `Ref` or `Selector` does not start that; it only inherits;
    /// - byte counts under `sizes` are left alone, but only inside the toolbox's own Secret summary (`kind` is "Secret" and
    ///   `values` is the placeholder).
    public func scrubOutput(_ value: JSONValue) -> JSONValue { scrubOutput(value, key: nil, sensitive: false, numbersExempt: false, inReference: false) }

    /// Containers that hold a reference to a secret (a volume source, `imagePullSecrets`), not a value.
    private static let referenceContainers: Set<String> = ["secret", "secrets", "imagePullSecrets"]
    /// Keys that are plain metadata of a reference: `items[].key`, `path`, `defaultMode`, `optional`.
    private static let referenceMetadata: Set<String> = ["key", "path", "defaultMode", "optional", "items"]

    private func scrubOutput(_ value: JSONValue, key: String?, sensitive: Bool, numbersExempt: Bool, inReference: Bool) -> JSONValue {
        let label = "field \(key ?? "")"
        switch value {
        case .string(let s):
            if sensitive, Self.isMaskableScalar(value) { return .string(Self.mark(label)) }
            return .string(redact(s))
        case .int, .double:
            if sensitive, !numbersExempt { return .string(Self.mark(label)) }
            return value
        case .array(let a):
            return .array(a.map { scrubOutput($0, key: key, sensitive: sensitive, numbersExempt: numbersExempt, inReference: inReference) })
        case .object(let raw):
            let o = Self.maskingEnvPair(raw)
            let isOwnSummary = o["kind"]?.stringValue == "Secret" && (o["values"]?.stringValue?.hasPrefix(Self.placeholderPrefix) ?? false)
            return .object(o.reduce(into: [:]) { acc, pair in
                let isReference = Self.referenceContainers.contains(pair.key)
                // An inherited flag is cleared for names of things (`secretName`, `...Ref`, `...Selector`) and, inside a
                // reference container, for its plain metadata. A reference container never starts the flag itself.
                var inherited = sensitive
                if Self.endsWithReferenceSuffix(pair.key) || (inReference && Self.referenceMetadata.contains(pair.key)) { inherited = false }
                let childSensitive = inherited || (Self.isSecretFieldName(pair.key) && !isReference)
                let exempt = numbersExempt || (isOwnSummary && pair.key == "sizes")
                acc[pair.key] = scrubOutput(pair.value, key: pair.key, sensitive: childSensitive, numbersExempt: exempt, inReference: inReference || isReference)
            })
        default:
            return value
        }
    }

    /// Helm values (or any free-form tree): scalar strings and numbers under a sensitive key name are masked, containers are
    /// walked, and every string goes through the content patterns.
    public func values(_ raw: JSONValue) -> JSONValue { valuesWalk(raw, key: nil) }

    private func valuesWalk(_ value: JSONValue, key: String?) -> JSONValue {
        switch value {
        case .object(let raw):
            let o = Self.maskingEnvPair(raw)
            return .object(o.reduce(into: [:]) { $0[$1.key] = valuesWalk($1.value, key: $1.key) })
        case .array(let a):
            return .array(a.map { valuesWalk($0, key: key) })
        case .string(let s):
            if let key, Self.isSensitiveName(key), !s.isEmpty, !s.hasPrefix(Self.placeholderPrefix) { return .string(Self.mark("key name")) }
            return .string(redact(s))
        case .int, .double:
            if let key, Self.isSensitiveName(key) { return .string(Self.mark("key name")) }
            return value
        case .bool, .null:
            return value
        }
    }

    private func walk(_ value: JSONValue, parentKey: String?, kindName: String?) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(redact(s))
        case .array(let a):
            return .array(a.map { walk($0, parentKey: parentKey, kindName: kindName) })
        case .object(var o):
            if o["kind"]?.stringValue == "Config", o["users"] != nil { return .string(Self.mark("kubeconfig")) }
            if parentKey == "annotations" { return annotations(o, kindName: kindName) }
            // Env entry: a literal value under a sensitive name. `valueFrom` is left as a reference and never resolved.
            if let name = o["name"]?.stringValue, case .string(let literal)? = o["value"], Self.isSensitiveName(name),
               !literal.isEmpty, !literal.hasPrefix(Self.placeholderPrefix) {
                o["value"] = .string(Self.mark("env value"))
            }
            let isConfigMap = kindName == "ConfigMap" && o["data"] != nil
            var out: [String: JSONValue] = [:]
            for (key, child) in o {
                if key == "managedFields", parentKey == "metadata" { continue }
                if isConfigMap, key == "data", case .object(let data) = child {
                    out[key] = .object(data.reduce(into: [:]) { acc, pair in
                        let text = pair.value.stringValue ?? ""
                        let masked = Self.isSensitiveName(pair.key) && !text.isEmpty && !text.hasPrefix(Self.placeholderPrefix)
                        acc[pair.key] = masked ? .string(Self.mark("key name")) : .string(redact(text))
                    })
                } else if isConfigMap, key == "binaryData", case .object(let data) = child {
                    out[key] = .object(data.mapValues { .string("‹binary, \(Self.decodedBase64Size($0.stringValue ?? "")) bytes›") })
                } else if Self.isSecretFieldName(key), Self.isMaskableScalar(child) {
                    out[key] = .string(Self.mark("field \(key)"))
                } else {
                    out[key] = walk(child, parentKey: key, kindName: kindName)
                }
            }
            return .object(out)
        default:
            return value
        }
    }

    private static let lastApplied = "kubectl.kubernetes.io/last-applied-configuration"

    private func annotations(_ o: [String: JSONValue], kindName: String?) -> JSONValue {
        var out: [String: JSONValue] = [:]
        for (key, value) in o {
            if key == Self.lastApplied {
                // Removed for Secrets (it can embed the values); parsed and walked for every other kind.
                if kindName == "Secret" { continue }
                if let text = value.stringValue, let data = text.data(using: .utf8), let parsed = try? JSONValue.parse(data) {
                    out[key] = .string(resource(parsed, kind: nil).jsonString())
                    continue
                }
            }
            out[key] = walk(value, parentKey: key, kindName: kindName)
        }
        return .object(out)
    }

    // MARK: Helpers

    static func decodedBase64Size(_ s: String) -> Int {
        let trimmed = s.filter { !$0.isWhitespace }
        guard !trimmed.isEmpty else { return 0 }
        let padding = trimmed.hasSuffix("==") ? 2 : (trimmed.hasSuffix("=") ? 1 : 0)
        return max(0, trimmed.utf8.count * 3 / 4 - padding)
    }

    static func looksLikeKubeconfig(_ text: String) -> Bool {
        guard text.count > 40 else { return false }
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard compact.contains("kind:Config") || compact.contains("\"kind\":\"Config\"") else { return false }
        return compact.contains("clusters:") || compact.contains("\"clusters\":")
    }
}

// MARK: - Rules

extension Redactor {
    struct Rule: @unchecked Sendable {
        let label: String
        let regex: NSRegularExpression
        let replacement: @Sendable (NSTextCheckingResult, NSString) -> String

        init(label: String, regex: NSRegularExpression, replacement: @escaping @Sendable (NSTextCheckingResult, NSString) -> String) {
            self.label = label
            self.regex = regex
            self.replacement = replacement
        }

        func apply(to text: String) -> String {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { return text }
            var out = text
            for match in matches.reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                out.replaceSubrange(range, with: replacement(match, ns))
            }
            return out
        }
    }

    private static func rule(_ label: String, _ pattern: String) -> Rule {
        let regex = try! NSRegularExpression(pattern: pattern)
        return Rule(label: label, regex: regex) { _, _ in mark(label) }
    }

    /// A rule that keeps capture group 1 (the key, or the scheme) and replaces the rest.
    private static func keepingPrefix(_ label: String, _ pattern: String) -> Rule {
        let regex = try! NSRegularExpression(pattern: pattern)
        return Rule(label: label, regex: regex) { match, ns in ns.substring(with: match.range(at: 1)) + mark(label) }
    }

    private static let keyWords = "password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credentials?"
    /// A value is anything except references and obvious non-secrets: `$VAR`, `${VAR}`, `{{ template }}`, `<placeholder>`, booleans.
    private static let valueClass = #"(?!‹redacted)(?!\$|\{\{|<|(?:true|false|null|none)\b)[^\s,;&"'}\]]+"#

    static let builtInRules: [Rule] = [
        // 1. PEM private keys and certificates (an unterminated block is redacted to the end of the text).
        Rule(label: "pem", regex: try! NSRegularExpression(
            pattern: #"-----BEGIN ((?:[A-Z0-9]+ )*(?:PRIVATE KEY|CERTIFICATE))-----[\s\S]*?(?:-----END \1-----|\z)"#)) { match, ns in
            mark(ns.substring(with: match.range(at: 1)).contains("PRIVATE") ? "private key" : "certificate")
        },
        // 1b. A log tail can start inside a PEM block: redact from the start of the text to the END line when no BEGIN precedes it.
        Rule(label: "pem tail", regex: try! NSRegularExpression(
            pattern: #"\A(?:(?!-----BEGIN)[\s\S])*?-----END (?:[A-Z0-9]+ )*(PRIVATE KEY|CERTIFICATE)-----"#)) { match, ns in
            mark(ns.substring(with: match.range(at: 1)).contains("PRIVATE") ? "private key" : "certificate")
        },
        // 2. Tokens with a recognisable shape.
        rule("jwt", #"eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"#),
        rule("aws access key", #"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#),
        rule("github token", #"\bgh[pousr]_[A-Za-z0-9]{36,}"#),
        rule("github token", #"\bgithub_pat_[A-Za-z0-9_]{22,}"#),
        rule("slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        rule("anthropic key", #"\bsk-ant-[A-Za-z0-9_-]{16,}"#),
        rule("google api key", #"\bAIza[0-9A-Za-z_-]{35}"#),
        keepingPrefix("azure key", #"(?i)(\bAccountKey=)(?!‹redacted)[^;\s"']+"#),
        keepingPrefix("azure sas", #"(?i)(\bSharedAccessSignature=)(?!‹redacted)[^;\s"']+"#),
        keepingPrefix("azure sas", #"(?i)([?&]sig=)(?!‹redacted)[A-Za-z0-9%+/=]{20,}"#),
        // 3. Authorization headers and bare bearer credentials.
        Rule(label: "bearer", regex: try! NSRegularExpression(
            pattern: #"(?i)\b(authorization|proxy-authorization)(["']?[ \t]*[:=][ \t]*["']?)(bearer|basic|token|negotiate)[ \t]+(?!‹redacted)[A-Za-z0-9._~+/=-]+"#)) { match, ns in
            ns.substring(with: match.range(at: 1)) + ns.substring(with: match.range(at: 2)) + ns.substring(with: match.range(at: 3)) + " " + mark("bearer")
        },
        rule("bearer", #"(?i)\bbearer[ \t]+(?!‹redacted)[A-Za-z0-9._~+/=-]{16,}"#),
        // 4. URL userinfo: scheme://user:pass@host
        Rule(label: "url credentials", regex: try! NSRegularExpression(pattern: #"(\b[A-Za-z][A-Za-z0-9+.-]*://)[^\s/@:'"]+:[^\s/@'"]+@"#)) { match, ns in
            ns.substring(with: match.range(at: 1)) + mark("url credentials") + "@"
        },
        // 5. Kubeconfig credentials.
        keepingPrefix("kubeconfig credential", #"(?i)(\b(?:client-key-data|client-certificate-data|access-token|refresh-token|id-token)["']?[ \t]*:[ \t]*)(?!‹redacted)[^\s"',}]+"#),
        rule("pem (base64)", #"\bLS0tLS1CRUdJTi[A-Za-z0-9+/=]{20,}(?:\r?\n[A-Za-z0-9+/=]{4,})*"#),
        // 6. Key/value forms: password=..., passwd: ..., secret: ..., token=..., aws_secret_access_key=...
        Rule(label: "kv", regex: try! NSRegularExpression(
            pattern: #"(?i)(\b[A-Za-z0-9_.-]*(?:\#(keyWords))["']?[ \t]*[=:][ \t]*)("[^"\n]*"|'[^'\n]*'|\#(valueClass))"#)) { match, ns in
            let prefix = ns.substring(with: match.range(at: 1))
            let value = ns.substring(with: match.range(at: 2))
            let quote = value.first.map { $0 == "\"" || $0 == "'" ? String($0) : "" } ?? ""
            if !quote.isEmpty {
                let inner = String(value.dropFirst().dropLast())
                if inner.isEmpty || inner.hasPrefix(placeholderPrefix) || inner.hasPrefix("$") || inner.hasPrefix("{{") { return prefix + value }
                return prefix + quote + mark("secret") + quote
            }
            return prefix + mark("secret")
        },
    ]
}
