import Foundation
import Yams

/// A pack that did not load, with every reason found.
public struct RiggingPackError: Error, Equatable, Sendable, LocalizedError {
    public var issues: [String]
    public init(_ issues: [String]) { self.issues = issues }
    public init(_ issue: String) { self.issues = [issue] }
    public var errorDescription: String? { issues.joined(separator: "\n") }
}

/// Reads `rigging.yaml` text into a ``RiggingPack``: YAML, then the bundled JSON Schema (through the Kit schema engine), then
/// ``RiggingPackValidator``. A pack that fails any step is rejected whole; nothing is evaluated from a half-valid pack.
public enum RiggingPackParser {
    public static let maxBytes = 256 * 1024

    /// The schema bundled in `BundledData/rigging/rigging.schema.json`.
    public static let schema: JSONValue? = {
        guard let url = Bundle.module.url(forResource: "BundledData", withExtension: nil)?.appending(path: "rigging/rigging.schema.json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }()

    public static let maxNodes = 50_000
    public static let maxDepth = 64
    private static func kindTag(_ node: Yams.Node) -> String { if case .mapping = node { "m" } else if case .sequence = node { "q" } else { "s" } }

    /// Composes the YAML once, before anything copies or expands it, and refuses aliases and merge keys (which could multiply
    /// a small file into a huge tree), too many nodes and too deep nesting. The walk is iterative and linear.
    static func guardStructure(_ text: String) throws {
        let root: Yams.Node?
        do { root = try Yams.compose(yaml: YAMLCodec.normalized(text)) } catch { throw RiggingPackError("rigging.yaml is not valid YAML: \(error.localizedDescription)") }
        guard let root else { return }
        var stack: [(Yams.Node, Int)] = [(root, 1)]
        var count = 0
        var seen = Set<String>()
        while let (node, depth) = stack.popLast() {
            count += 1
            guard count <= maxNodes else { throw RiggingPackError("rigging.yaml has too many entries.") }
            guard depth <= maxDepth else { throw RiggingPackError("rigging.yaml is nested too deeply.") }
            // Compose drops the anchor but shares the anchored node, so a node reached twice (same source position) is an alias.
            if let mark = node.mark, !seen.insert("\(Self.kindTag(node))\(mark.line):\(mark.column)").inserted { throw RiggingPackError("YAML anchors and aliases are not allowed in a pack.") }
            switch node {
            case .alias: throw RiggingPackError("YAML anchors and aliases are not allowed in a pack.")
            case .scalar: break
            case .sequence(let s): stack.append(contentsOf: s.map { ($0, depth + 1) })
            case .mapping(let m):
                for (k, v) in m {
                    if k.scalar?.string == "<<" { throw RiggingPackError("YAML merge keys (“<<”) are not allowed in a pack.") }
                    stack.append((k, depth + 1))
                    stack.append((v, depth + 1))
                }
            }
        }
    }

    public static func parse(_ text: String, schema override: JSONValue? = nil) throws -> RiggingPack {
        guard text.utf8.count <= maxBytes else { throw RiggingPackError("rigging.yaml is larger than \(maxBytes / 1024) KB.") }
        try guardStructure(text)
        let documents = YAMLNodeMap.documents(in: text)
        guard documents.count == 1, let document = documents.first else { throw RiggingPackError("rigging.yaml must hold exactly one document.") }
        if let d = document.diagnostic { throw RiggingPackError("Line \(d.line): \(d.message)") }
        guard let root = document.root else { throw RiggingPackError("rigging.yaml is empty.") }
        guard let schema = override ?? Self.schema else { throw RiggingPackError("The pack schema is missing from this build.") }
        let engine = JSONSchemaEngine(document: SchemaDocument(root: schema), options: .jsonSchema)
        let issues = engine.validate(root, schema: schema).filter { $0.severity == .error }
        guard issues.isEmpty else {
            throw RiggingPackError(issues.sorted { ($0.span.line, $0.span.column) < ($1.span.line, $1.span.column) }.prefix(20).map { "Line \($0.span.line + 1): \($0.message)" })
        }
        let pack: RiggingPack
        do { pack = try root.value.decode(RiggingPack.self) } catch { throw RiggingPackError("The pack could not be read: \(error.localizedDescription)") }
        let problems = RiggingPackValidator.problems(in: pack)
        guard problems.isEmpty else { throw RiggingPackError(problems) }
        return pack
    }
}

/// The checks a schema cannot express: every path and template must parse in its closed grammar, every variable must be allowed
/// where it is used, and the pieces must agree with each other.
public enum RiggingPackValidator {
    public static func problems(in pack: RiggingPack) -> [String] {
        var out: [String] = []
        func path(_ text: String, _ context: String) {
            do { _ = try JSONPathSubset(text) } catch { out.append("\(context): \(error.localizedDescription)") }
        }
        func template(_ text: String, mode: RiggingTemplate.Mode, allowed: Set<String>, _ context: String) {
            do { _ = try RiggingTemplate(text, mode: mode, allowed: allowed) } catch { out.append("\(context): \(error.localizedDescription)") }
        }
        func condition(_ c: RiggingPack.Condition, allowDuration: Bool, _ context: String) {
            let hasCondition = c.condition != nil, hasPath = c.path != nil
            if hasCondition == hasPath { out.append("\(context): use either “condition” (with “status”) or “path”.") }
            if hasCondition {
                if c.status == nil { out.append("\(context): a condition check needs “status”.") }
                if c.exists != nil || c.equals != nil || c.oneOf != nil { out.append("\(context): “exists”, “equals” and “in” go with “path”.") }
            }
            if let p = c.path {
                path(p, context)
                if [c.exists != nil, c.equals != nil, c.oneOf != nil].filter({ $0 }).count != 1 { out.append("\(context): a path check needs exactly one of “exists”, “equals” or “in”.") }
                if c.status != nil { out.append("\(context): “status” goes with “condition”.") }
            }
            if c.duration != nil, !(allowDuration && hasCondition) { out.append("\(context): “for” is only valid on a condition check in a health rule.") }
        }

        var ids = Set<String>()
        for (i, view) in pack.allViews.enumerated() {
            let ctx = "views[\(i)] (\(view.match.kind))"
            if !ids.insert(view.viewID).inserted { out.append("\(ctx): the view id “\(view.viewID)” is used twice; give each view an “id”.") }
            for c in view.columns ?? [] { path(c.path, "\(ctx) column “\(c.name)”") }
            var seen = Set<String>()
            for f in view.fields ?? [] {
                path(f.path, "\(ctx) field “\(f.name)”")
                if RiggingTemplate.baseVariables.contains(f.name) { out.append("\(ctx): the field name “\(f.name)” is reserved.") }
                if !seen.insert(f.name).inserted { out.append("\(ctx): the field “\(f.name)” is declared twice.") }
            }
            for s in view.status ?? [] { condition(s.when, allowDuration: false, "\(ctx) status rule") }
            for r in view.related ?? [] {
                path(r.nameFrom, "\(ctx) related “\(r.label)”")
                if let n = r.namespaceFrom { path(n, "\(ctx) related “\(r.label)”") }
            }
        }
        for (i, group) in pack.allSidebar.enumerated() where group.title == nil && group.kinds == nil {
            out.append("sidebar[\(i)]: give a “title” or “kinds”.")
        }
        for (i, command) in pack.allCommands.enumerated() {
            let ctx = "commands[\(i)] “\(command.title)”"
            let objectVars: Set<String> = command.for.map { Set(["name", "namespace", "cluster", "kind"]).union(pack.fields(for: $0).map(\.name)) } ?? ["cluster"]
            switch (command.terminal, command.portForward) {
            case (.some(let t), nil): template(t, mode: .shell, allowed: objectVars, ctx)
            case (nil, .some(let p)):
                if (p.service == nil) == (p.pod == nil) { out.append("\(ctx): a port forward needs exactly one of “service” or “pod”.") }
                for (label, value) in [("service", p.service), ("pod", p.pod), ("namespace", Optional(p.namespace))] {
                    guard let value else { continue }
                    template(value, mode: .plain, allowed: objectVars.subtracting(["cluster"]).intersection(["name", "namespace"]), "\(ctx) \(label)")
                }
                if let open = p.open {
                    template(open, mode: .plain, allowed: ["localPort"], "\(ctx) open")
                    if !isLocalURL(open) { out.append("\(ctx): “open” must be an http or https address on 127.0.0.1 or localhost.") }
                }
            default: out.append("\(ctx): give exactly one of “terminal” or “portForward”.")
            }
        }
        for (i, rule) in pack.allHealthRules.enumerated() {
            let ctx = "healthRules[\(i)] (\(rule.for.kind))"
            condition(rule.when, allowDuration: true, ctx)
            if let d = rule.when.duration, durationSeconds(d) == nil { out.append("\(ctx): “\(d)” is not a duration such as 30m, 1h or 2d.") }
            template(rule.message, mode: .plain, allowed: Set(["name", "namespace", "cluster", "kind"]).union(pack.fields(for: rule.for).map(\.name)), "\(ctx) message")
        }
        return out
    }

    /// `30s`, `45m`, `1h`, `2d` as seconds.
    public static func durationSeconds(_ text: String) -> TimeInterval? {
        guard let unit = text.last, let n = Double(text.dropLast()), n >= 0 else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86_400
        default: return nil
        }
    }

    /// The address must be loopback on exactly the forwarded port: `http(s)://127.0.0.1:{{localPort}}/…` or `localhost:{{localPort}}`.
    static func isLocalURL(_ template: String) -> Bool {
        guard template.contains("{{localPort}}") else { return false }
        let probe = template.replacingOccurrences(of: "{{localPort}}", with: "49999")
        guard let url = URL(string: probe), let scheme = url.scheme, ["http", "https"].contains(scheme), url.user == nil, url.port == 49999 else { return false }
        return ["127.0.0.1", "localhost"].contains(url.host ?? "") && template.contains("//\(url.host ?? ""):{{localPort}}")
    }
}
