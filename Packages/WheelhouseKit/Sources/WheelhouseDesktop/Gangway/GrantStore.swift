#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// Decides whether a reported command line may get a command approval (owner decision 8): one simple `kubectl`, `helm` or `flux`
/// invocation, and nothing a shell could expand into something else.
public enum CommandEligibility {
    static let builtinKubectl: Set<String> = [
        "get", "describe", "create", "delete", "apply", "patch", "replace", "edit", "scale", "rollout", "set", "label", "annotate", "expose",
        "run", "autoscale", "taint", "cordon", "uncordon", "drain", "top", "logs", "diff", "wait", "auth", "api-resources", "api-versions",
        "config", "explain", "version", "cluster-info", "certificate", "events", "kustomize", "options", "plugin", "completion", "help",
    ]
    // `edit` (and `--edit`) start an editor whose shell escape would inherit the grant.
    static let neverEligible: Set<String> = ["proxy", "port-forward", "exec", "attach", "cp", "debug", "edit", "edit-last-applied"]
    static let flagsWithValue: Set<String> = ["-n", "--namespace", "--context", "--cluster", "--user", "--as", "--as-group", "--request-timeout", "-v", "--v"]
    static let bannedWords: Set<String> = ["edit-last-applied", "xargs", "eval", "exec", "watch", "for", "while", "until", "do", "if", "then", "fi", "done"]
    static let bannedFragments = [";", "&", "|", "$(", "`", "<(", ">(", "\n", "\r"]

    /// A shell-words split without any expansion. nil for an unterminated quote.
    public static func tokenize(_ line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaped = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; inToken = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\", q == "\"" { escaped = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "'", "\"": quote = ch; inToken = true
            case "\\": escaped = true
            case " ", "\t":
                if inToken { tokens.append(current); current = ""; inToken = false }
            default: current.append(ch); inToken = true
            }
        }
        if quote != nil || escaped { return nil }
        if inToken { tokens.append(current) }
        return tokens
    }

    public static func isEligible(_ line: String) -> Bool {
        guard bannedFragments.allSatisfy({ !line.contains($0) }), let tokens = tokenize(line), let first = tokens.first else { return false }
        let name = (first as NSString).lastPathComponent
        guard ["kubectl", "helm", "flux"].contains(name), first == name || first.hasPrefix("/") else { return false }
        for token in tokens.dropFirst() {
            if bannedWords.contains(token) { return false }
        }
        // The bypass flags of the Deck Terminal (section 3.4).
        for token in tokens.dropFirst() {
            for flag in ["--kubeconfig", "--server", "--token"] where token == flag || token.hasPrefix(flag + "=") { return false }
            if token == "-s" || token.hasPrefix("-s=") || (token.hasPrefix("-s") && !token.hasPrefix("--") && token.count > 2) { return false }   // -s<server>, -s=<server>
            if token == "--edit" || token.hasPrefix("--edit=") { return false }
        }
        guard name == "kubectl" else { return true }
        var index = 1
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-") {
                index += flagsWithValue.contains(token) ? 2 : 1
                continue
            }
            return builtinKubectl.contains(token) && !neverEligible.contains(token)
        }
        return false
    }
}

/// An object a Helm or Tides run may change after its review (ARCHITECTURE-MAC section 5.2).
public struct GrantedObject: Hashable, Sendable {
    public var group: String
    public var resource: String
    public var namespace: String?
    /// nil: no exact name. Never a wildcard for PUT, PATCH, DELETE or deletecollection.
    public var name: String?
    /// Matches names that start with this prefix (Helm release Secrets: `sh.helm.release.v1.<release>.v`).
    public var namePrefix: String?
    /// A hook that uses `generateName`: covers a create whose body has exactly this `metadata.generateName` (compared as bytes).
    public var generateNamePrefix: String?
    /// An explicit stand-in that covers a create of any name. Helm runs never set it: their creates are matched by the body's name
    /// (`GrantBody`). Fail closed by default.
    public var createAnyName: Bool
    public init(group: String = "", resource: String, namespace: String? = nil, name: String? = nil, namePrefix: String? = nil,
                generateNamePrefix: String? = nil, createAnyName: Bool = false) {
        self.generateNamePrefix = generateNamePrefix
        self.createAnyName = createAnyName
        self.group = group
        self.resource = resource
        self.namespace = namespace
        self.name = name
        self.namePrefix = namePrefix
    }

    /// Whether `candidate` is the exact name or starts with the prefix. Compared as UTF-8 bytes, not by Unicode equivalence: a body name
    /// is not restricted to ASCII like a path name.
    func matches(name candidate: String) -> Bool {
        if let exact = name { return exact.utf8.elementsEqual(candidate.utf8) }
        if let prefix = namePrefix { return candidate.utf8.starts(with: prefix.utf8) }
        return false
    }
}

/// What a request looks like to the grant store.
public struct GrantRequest: Sendable {
    public var holdID: UUID?
    public var kind: GangwayClass
    public var shape: APIPathShape
    public var method: String
    /// The name a create (POST) asks for, read from its buffered body (`GrantBody`). nil when there is no usable body.
    public var createdName: CreatedName?
    public init(holdID: UUID? = nil, kind: GangwayClass, shape: APIPathShape, method: String, createdName: CreatedName? = nil) {
        self.createdName = createdName
        self.holdID = holdID
        self.kind = kind
        self.shape = shape
        self.method = method
    }
}

/// Grants (ARCHITECTURE-MAC section 3.6, step 6): command grants, batch approvals, object grants and dry-run-only sessions.
///
/// A batch approval is bound to the held requests the person saw (their IDs), not to a hash of what they might send later: bodies are
/// streamed, never buffered, so a body hash does not exist at decision time (recorded as a deviation in the architecture notes).
public final class GrantStore: Sendable {
    public static let commandCap: TimeInterval = 600
    public static let batchLifetime: TimeInterval = 120

    private struct CommandGrant {
        var commandID: String
        var expiry: Date
    }
    private struct State {
        var commands: [UUID: CommandGrant] = [:]
        var batches: [UUID: Set<UUID>] = [:]
        var batchExpiry: [UUID: Date] = [:]
        var objects: [UUID: (items: Set<GrantedObject>, expiry: Date)] = [:]
    }
    private let state = Mutex(State())
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) { self.now = now }

    // MARK: Command grants

    /// Approves one grant-eligible command for this session. Returns false (and grants nothing) for any other command line.
    @discardableResult
    public func grantCommand(session: GangwaySession, command: ReportedCommand) -> Bool {
        guard CommandEligibility.isEligible(command.line) else { return false }
        let expiry = now().addingTimeInterval(Self.commandCap)
        state.withLock { $0.commands[session.id] = CommandGrant(commandID: command.id, expiry: expiry) }
        return true
    }

    /// The nonce-verified OSC 133 D of a command: its grant ends, and is never carried to the next command.
    public func endCommand(session: GangwaySession, commandID: String) {
        state.withLock { s in
            if s.commands[session.id]?.commandID == commandID { s.commands[session.id] = nil }
        }
    }

    public func hasCommandGrant(session: GangwaySession) -> Bool {
        state.withLock { s in
            guard let grant = s.commands[session.id] else { return false }
            return grant.expiry > now()
        }
    }

    // MARK: Batch approvals

    /// Approves exactly these held requests.
    public func approveBatch(session: GangwaySession, holdIDs: [UUID]) {
        let expiry = now().addingTimeInterval(Self.batchLifetime)
        state.withLock { s in
            s.batches[session.id, default: []].formUnion(holdIDs)
            s.batchExpiry[session.id] = expiry
        }
    }

    /// Spends the approval of one held request. True once.
    func consumeBatch(session: GangwaySession, holdID: UUID) -> Bool {
        state.withLock { s in
            guard let expiry = s.batchExpiry[session.id], expiry > now(), s.batches[session.id]?.remove(holdID) != nil else { return false }
            return true
        }
    }

    // MARK: Objects and dry-run-only

    // Contract for Helm runs (the grant is only as good as its binding): (1) the session is bound to the spawned helm process group
    // (`PeerBinding.isolatedGroup`) and the peer is checked per request by `covers`; (2) a POST is matched by `metadata.name` from a
    // buffered body (3 MB, `GrantBody`) against the reviewed objects; (3) the caller closes the session when the helm process exits, and
    // the lifetime is only the backstop.
    public func setObjects(session: GangwaySession, objects: Set<GrantedObject>, lifetime: TimeInterval = 600) {
        let expiry = now().addingTimeInterval(lifetime)
        state.withLock { $0.objects[session.id] = (objects, expiry) }
    }

    /// Whether the object grant of this session covers `request`, by what the request changes alone. The peer is checked by `covers`.
    public func coversObject(_ request: GrantRequest, session: GangwaySession) -> Bool {
        guard request.kind == .mutation else { return false }
        let grant = state.withLock { $0.objects[session.id] }
        guard let grant, grant.expiry > now() else { return false }
        let shape = request.shape
        guard shape.isResourcePath, shape.legacyVerb == nil, shape.subresource == nil || shape.subresource == "status" else { return false }
        return grant.items.contains { item in
            guard item.group == shape.group, item.resource == shape.resource, item.namespace == shape.namespace else { return false }
            if request.method == "POST", shape.name == nil {
                if item.createAnyName { return true }
                switch request.createdName {
                case .name(let created)?: return item.matches(name: created)
                case .generateName(let prefix)?: return item.generateNamePrefix.map { $0.utf8.elementsEqual(prefix.utf8) } ?? false
                case nil: return false
                }
            }
            guard let name = shape.name else { return false }                    // deletecollection and list-shaped writes are never covered
            return item.matches(name: name)
        }
    }

    // MARK: Covering

    /// Whether a held mutation is already covered: a spent batch approval, or the session's command grant when the requesting process is
    /// the terminal's foreground job. Streams and proxy requests are never covered.
    public func covers(_ request: GrantRequest, session: GangwaySession, peer: PeerProcess?) -> Bool {
        // A Helm or Tides run is covered only for the process it was opened for, whatever the object.
        if session.scope == .objects { return Self.peerIsBound(peer, to: session.binding) && coversObject(request, session: session) }
        // An approval is for exactly the request that was listed, whatever its class (a proxy request is approved per request too).
        if let id = request.holdID, consumeBatch(session: session, holdID: id) { return true }
        guard request.kind == .mutation else { return false }
        guard Self.peerIsBound(peer, to: session.binding) else { return false }
        return state.withLock { s in
            guard let grant = s.commands[session.id] else { return false }
            if grant.expiry <= now() { s.commands[session.id] = nil; return false }
            // The grant belongs to the command it was given for: once the shell reports another one (or none), it does not apply.
            return session.reportedCommand?.id == grant.commandID
        }
    }

    /// The PTY binding: `getsid(peer) == boundSession` and `getpgid(peer) == tcgetpgrp(master)`; for a helm or flux run the peer must be in
    /// the spawned process group.
    public static func peerIsBound(_ peer: PeerProcess?, to binding: PeerBinding) -> Bool {
        guard let peer else { return false }
        switch binding {
        case .none: return false
        case .pty(_, let session, let foreground):
            guard let group = foreground() else { return false }
            return peer.session == session && peer.group == group
        case .processGroup(let group): return peer.group == group
        case .isolatedGroup(let group): return peer.group == group && peer.session == group
        }
    }

    // MARK: Revocation

    /// Ends every grant of a session (session close, lock, a cluster that became read-only or Production).
    public func revoke(session: GangwaySession) {
        state.withLock { s in
            s.commands[session.id] = nil
            s.batches[session.id] = nil
            s.batchExpiry[session.id] = nil
            s.objects[session.id] = nil
        }
    }

    public func revokeAll() {
        state.withLock { $0 = State() }
    }
}
#endif
