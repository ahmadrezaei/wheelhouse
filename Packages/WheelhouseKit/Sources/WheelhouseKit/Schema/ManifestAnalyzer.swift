import Foundation

/// A problem the Manifest Editor shows: YAML syntax, or a schema finding. Schema findings never block Review (the server's dry-run
/// stays the authority); only syntax errors do, exactly as in the iOS editor.
public struct ManifestDiagnostic: Hashable, Sendable, Identifiable {
    public enum Source: Sendable { case syntax, schema }
    public var span: YAMLSpan
    public var message: String
    public var severity: YAMLDiagnostic.Severity
    public var source: Source
    public var path: String
    public var id: String { "\(span.line):\(span.column):\(message)" }

    public init(span: YAMLSpan, message: String, severity: YAMLDiagnostic.Severity, source: Source, path: String) {
        self.span = span
        self.message = message
        self.severity = severity
        self.source = source
        self.path = path
    }

    /// The line-based diagnostic the gutter and the Issues list already understand.
    public var lineDiagnostic: YAMLDiagnostic {
        YAMLDiagnostic(line: span.line, column: span.column + 1, message: message, severity: severity)
    }
}

/// One entry of the multi-document outline.
public struct ManifestOutlineItem: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    public var index: Int
    /// `Deployment/web`, or `Document 2` when there is no kind.
    public var title: String
    public var startLine: Int
    public var endLine: Int
    public var errors: Int
    public var warnings: Int

    public init(index: Int, title: String, startLine: Int, endLine: Int, errors: Int, warnings: Int) {
        self.index = index
        self.title = title
        self.startLine = startLine
        self.endLine = endLine
        self.errors = errors
        self.warnings = warnings
    }
}

/// A foldable block: the header line and the last line it hides.
public struct ManifestFoldRange: Hashable, Sendable {
    public var startLine: Int
    public var endLine: Int

    public init(startLine: Int, endLine: Int) {
        self.startLine = startLine
        self.endLine = endLine
    }
}

public struct ManifestAnalysis: Sendable {
    public var diagnostics: [ManifestDiagnostic] = []
    public var outline: [ManifestOutlineItem] = []
    public var folds: [ManifestFoldRange] = []
    /// "Schema from Kubernetes 1.32, cluster schema unavailable" when a bundled schema was used.
    public var schemaNote: String?

    public init() {}

    public var syntaxErrors: [ManifestDiagnostic] { diagnostics.filter { $0.source == .syntax } }
    public var schemaIssues: [ManifestDiagnostic] { diagnostics.filter { $0.source == .schema } }
}

/// Validation, outline and folding of a YAML stream against Kubernetes schemas. Everything here is a pure function of the text and
/// the schemas, so the editor runs it off the main actor.
public struct ManifestAnalyzer: Sendable {
    public var schemas: (any ManifestSchemaProviding)?

    public init(schemas: (any ManifestSchemaProviding)?) { self.schemas = schemas }

    /// Analyses `text`. The only awaits are schema lookups (a network read the first time a kind is seen).
    @concurrent
    public func analyze(_ text: String) async -> ManifestAnalysis {
        let documents = YAMLNodeMap.documents(in: text)
        var kindSchemas: [GroupVersionKind: KindSchema] = [:]
        if let schemas {
            var wanted: [GroupVersionKind] = []
            for doc in documents {
                if let v = doc.apiVersion, let k = doc.kind { let gvk = GroupVersionKind(apiVersion: v, kind: k); if !wanted.contains(gvk) { wanted.append(gvk) } }
            }
            await withTaskGroup(of: (GroupVersionKind, KindSchema?).self) { group in
                for gvk in wanted { group.addTask { (gvk, await schemas.kindSchema(for: gvk)) } }
                for await (gvk, found) in group { if let found { kindSchemas[gvk] = found } }
            }
        }
        return Self.analyze(documents: documents, text: text, kindSchemas: kindSchemas)
    }

    /// The synchronous part: positions, validation, outline and folds for already-resolved schemas.
    public static func analyze(documents: [YAMLMapDocument], text: String, kindSchemas: [GroupVersionKind: KindSchema]) -> ManifestAnalysis {
        var out = ManifestAnalysis()
        for doc in documents {
            var found: [ManifestDiagnostic] = []
            if let d = doc.diagnostic {
                found.append(ManifestDiagnostic(span: YAMLSpan(line: d.line, column: max(0, d.column - 1), endLine: d.line, endColumn: max(0, d.column - 1) + 1),
                                                message: d.message, severity: .error, source: .syntax, path: ""))
            } else if let root = doc.root {
                found += check(root, doc: doc, kindSchemas: kindSchemas)
                if let gvk = gvk(of: doc), let kindSchema = kindSchemas[gvk] {
                    if out.schemaNote == nil { out.schemaNote = kindSchema.source.note(serverVersion: nil) }
                    let engine = kindSchema.engine
                    found += engine.validate(root, schema: kindSchema.schema).map {
                        ManifestDiagnostic(span: $0.span, message: $0.message, severity: $0.severity == .error ? .error : .warning, source: .schema, path: $0.path)
                    }
                }
            }
            out.diagnostics += found
            out.outline.append(ManifestOutlineItem(
                index: doc.index, title: title(of: doc), startLine: doc.startLine, endLine: doc.endLine,
                errors: found.filter { $0.severity == .error }.count, warnings: found.filter { $0.severity == .warning }.count))
        }
        out.diagnostics.sort { ($0.span.line, $0.span.column) < ($1.span.line, $1.span.column) }
        out.folds = ManifestFolding.ranges(in: text)
        return out
    }

    private static func gvk(of doc: YAMLMapDocument) -> GroupVersionKind? {
        guard let v = doc.apiVersion, let k = doc.kind else { return nil }
        return GroupVersionKind(apiVersion: v, kind: k)
    }

    private static func title(of doc: YAMLMapDocument) -> String {
        guard let kind = doc.kind else { return "Document \(doc.index + 1)" }
        return doc.name.map { "\(kind)/\($0)" } ?? kind
    }

    /// Checks that need no schema: the identity of the object and name syntax.
    private static func check(_ root: YAMLNode, doc: YAMLMapDocument, kindSchemas: [GroupVersionKind: KindSchema]) -> [ManifestDiagnostic] {
        var out: [ManifestDiagnostic] = []
        func add(_ span: YAMLSpan, _ message: String, _ severity: YAMLDiagnostic.Severity = .error, path: String) {
            out.append(ManifestDiagnostic(span: span, message: message, severity: severity, source: .schema, path: path))
        }
        guard root.kind == .mapping else {
            add(root.span, "A manifest document must be a mapping", path: "")
            return out
        }
        let top = YAMLSpan(line: doc.startLine, column: 0, endLine: doc.startLine, endColumn: 0)
        if root.child("apiVersion") == nil { add(root.entries.first?.keySpan ?? top, "apiVersion is required", path: "apiVersion") }
        if root.child("kind") == nil { add(root.entries.first?.keySpan ?? top, "kind is required", path: "kind") }
        guard let meta = root.child("metadata"), meta.kind == .mapping else { return out }
        if let name = meta.entry("name"), let s = name.value.scalar.stringValue, !KubeNames.isObjectName(s) {
            add(name.value.span, "“\(s)” is not a valid name: use lowercase letters, digits, “-” and “.”", path: "metadata.name")
        }
        if let ns = meta.entry("namespace"), let s = ns.value.scalar.stringValue, !KubeNames.isDNSLabel(s) {
            add(ns.value.span, "“\(s)” is not a valid namespace name", path: "metadata.namespace")
        }
        if let labels = meta.child("labels"), labels.kind == .mapping {
            for e in labels.entries {
                if !isLabelKey(e.key) { add(e.keySpan, "“\(e.key)” is not a valid label key", path: "metadata.labels") }
                if let v = e.value.scalar.stringValue, !isLabelValue(v) { add(e.value.span, "“\(v)” is not a valid label value", path: "metadata.labels.\(e.key)") }
            }
        }
        return out
    }

    private static let labelName = #"^[A-Za-z0-9]([-A-Za-z0-9_.]{0,61}[A-Za-z0-9])?$"#

    static func isLabelValue(_ s: String) -> Bool {
        s.isEmpty || (JSONSchemaEngine.regex(labelName).map { $0.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil } ?? true)
    }

    static func isLabelKey(_ s: String) -> Bool {
        let parts = s.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2 { return parts[0].utf8.count <= 253 && KubeNames.isObjectName(parts[0]) && isLabelValue(parts[1]) && !parts[1].isEmpty }
        return !s.isEmpty && isLabelValue(s)
    }
}

/// Folding by indentation.
public enum ManifestFolding {
    /// Header lines of folds that start closed: `metadata.managedFields` (server bookkeeping nobody edits by hand).
    public static func defaultCollapsed(in text: String, folds: [ManifestFoldRange]) -> [Int] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return folds.map(\.startLine).filter { line in
            lines.indices.contains(line - 1) && lines[line - 1].drop { $0 == " " }.hasPrefix("managedFields:")
        }
    }

    /// Every line that is followed by deeper-indented lines starts a fold that ends at the last of them. Blank lines inside a
    /// block belong to it; trailing blank lines do not.
    public static func ranges(in text: String) -> [ManifestFoldRange] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [ManifestFoldRange] = []
        var open: [(line: Int, indent: Int)] = []
        var lastContent = 0
        func indentOf(_ l: Substring) -> Int? {
            let shape = YAMLLineShape(l)
            if l.hasPrefix("---") { return -1 }
            return shape.content.isEmpty || shape.content.hasPrefix("#") ? nil : shape.indent
        }
        func close(downTo indent: Int, endingAt end: Int) {
            while let top = open.last, top.indent >= indent {
                open.removeLast()
                if end > top.line { out.append(ManifestFoldRange(startLine: top.line, endLine: end)) }
            }
        }
        for (i, l) in lines.enumerated() {
            guard let indent = indentOf(l) else { continue }
            if indent <= (open.last?.indent ?? -2) || indent == -1 { close(downTo: indent == -1 ? 0 : indent, endingAt: lastContent) }
            if indent >= 0 { open.append((i + 1, indent)) }
            lastContent = i + 1
        }
        close(downTo: 0, endingAt: lastContent)
        return out.sorted { $0.startLine < $1.startLine }
    }
}
