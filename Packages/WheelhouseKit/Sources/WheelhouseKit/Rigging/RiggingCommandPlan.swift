import Foundation

/// What a pack command turns into. There are exactly two outcomes and neither runs anything by itself: text for the person's own
/// terminal (inserted, never run), or a port-forward request that always goes through a confirmation sheet.
public enum RiggingCommandPlan: Equatable, Sendable {
    /// Text to insert into a guarded Deck Terminal as a bracketed paste. No Return is ever added.
    case insert(text: String)
    /// A tunnel to start after the person confirms.
    case portForward(PortForwardPlan)
}

public struct PortForwardPlan: Equatable, Sendable {
    public var target: PortForwardTarget
    /// Where to open the browser once the forward is up; `localPort` is substituted and the result checked again.
    public var openTemplate: String?

    public init(target: PortForwardTarget, openTemplate: String? = nil) {
        self.target = target
        self.openTemplate = openTemplate
    }

    /// The address to open for `localPort`: loopback http(s) on exactly that port, or nil.
    public func openURL(localPort: Int) -> URL? {
        guard let openTemplate, let template = try? RiggingTemplate(openTemplate, mode: .plain, allowed: ["localPort"]),
              let text = try? template.render(["localPort": String(localPort)]), let url = URL(string: text),
              let scheme = url.scheme, ["http", "https"].contains(scheme), url.user == nil, url.port == localPort,
              ["127.0.0.1", "localhost"].contains(url.host ?? "") else { return nil }
        return url
    }
}

public enum RiggingCommandPlanner {
    /// Renders `command` for `subject` on the cluster named `cluster`. Throws when a value is not safe to insert or a variable has no
    /// value (the message says which), so nothing partial is ever produced.
    public static func plan(_ command: RiggingPack.Command, in pack: RiggingPack, subject: RiggingValues.Subject?, cluster: String) throws -> RiggingCommandPlan {
        let fields = command.for.map { pack.fields(for: $0) } ?? []
        let allowed: Set<String> = command.for == nil ? ["cluster"] : Set(["name", "namespace", "cluster", "kind"]).union(fields.map(\.name))
        let values = RiggingValues.make(subject: command.for == nil ? nil : subject, cluster: cluster, fields: fields)
        if let kind = command.for, let subject, let have = subject.kind, have != kind.kind {
            throw RiggingTemplate.TemplateError(message: "This command is for \(kind.kind), not \(have).")
        }
        if let text = command.terminal {
            let line = try RiggingTemplate(text, mode: .shell, allowed: allowed).render(values)
            return .insert(text: line)
        }
        if let forward = command.portForward {
            let plain = allowed.intersection(["name", "namespace"])
            func render(_ text: String) throws -> String { try RiggingTemplate(text, mode: .plain, allowed: plain).render(values) }
            let namespace = try render(forward.namespace)
            guard KubeNames.isDNSLabel(namespace) else { throw RiggingTemplate.TemplateError(message: "“\(namespace)” is not a valid namespace.") }
            let rawName = try forward.service.map(render) ?? render(forward.pod ?? "")
            guard KubeNames.isObjectName(rawName) else { throw RiggingTemplate.TemplateError(message: "“\(rawName)” is not a valid name.") }
            guard (1...65535).contains(forward.port) else { throw RiggingTemplate.TemplateError(message: "The port is out of range.") }
            let target = PortForwardTarget(kind: forward.service != nil ? .service : .pod, namespace: namespace, name: rawName, remotePort: forward.port)
            return .portForward(PortForwardPlan(target: target, openTemplate: forward.open))
        }
        throw RiggingTemplate.TemplateError(message: "The command has nothing to do.")
    }
}

/// The full declaration of a pack in plain words, shown before it is enabled and in Settings.
public enum RiggingDeclaration {
    public struct Section: Equatable, Sendable, Identifiable {
        public var title: String
        public var lines: [String]
        public var id: String { title }
    }

    public static func sections(for pack: RiggingPack) -> [Section] {
        var out: [Section] = []
        func kind(_ k: RiggingPack.KindMatch) -> String { k.group.isEmpty ? k.kind : "\(k.kind) (\(k.group))" }
        if !pack.allViews.isEmpty {
            out.append(Section(title: "Reads these kinds (through the cluster connection you already use)", lines: pack.allViews.map { view in
                var text = "\(view.title ?? view.match.kind): \(kind(view.match))"
                if let c = view.columns, !c.isEmpty { text += " · columns: " + c.map(\.name).joined(separator: ", ") }
                if let r = view.related, !r.isEmpty { text += " · related: " + r.map(\.label).joined(separator: ", ") }
                return text
            }))
        }
        if !pack.allSidebar.isEmpty {
            out.append(Section(title: "Changes the sidebar", lines: pack.allSidebar.map { "\($0.apiGroup)" + ($0.title.map { " shown as “\($0)”" } ?? "") + ($0.kinds.map { " · order: " + $0.joined(separator: ", ") } ?? "") }))
        }
        let terminal = pack.allCommands.filter { $0.terminal != nil }
        if !terminal.isEmpty {
            out.append(Section(title: "Inserts these commands into a guarded terminal (never runs them)", lines: terminal.map { "\($0.title): \($0.terminal ?? "")" + ($0.for.map { " · for \(kind($0))" } ?? "") }))
        }
        let forwards = pack.allCommands.filter { $0.portForward != nil }
        if !forwards.isEmpty {
            out.append(Section(title: "Starts these port forwards (each asks you to confirm)", lines: forwards.compactMap { c in
                c.portForward.map { "\(c.title): \($0.service.map { "service \($0)" } ?? "pod \($0.pod ?? "")") in \($0.namespace), port \($0.port)" + ($0.open.map { " · opens \($0)" } ?? "") }
            }))
        }
        if !pack.allHealthRules.isEmpty {
            out.append(Section(title: "Adds health rules to Alerts", lines: pack.allHealthRules.map { "\(kind($0.for)): \($0.message) (\($0.tone.rawValue))" }))
        }
        out.append(Section(title: "Cannot", lines: ["Run code, make network calls, read files, or change anything in a cluster."]))
        return out
    }
}
