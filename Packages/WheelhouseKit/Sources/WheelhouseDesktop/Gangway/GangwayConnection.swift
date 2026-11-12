#if os(macOS)
import Foundation
import Network
import os
import Synchronization
import WheelhouseKit

private let signposter = OSSignposter(subsystem: "app.wheelhouse.mac", category: "Gangway")

/// Delivers the status of the first response after a request, to whoever waits for it.
final class StatusGate: Sendable {
    private struct State {
        var result: Int?
        var continuation: CheckedContinuation<Int, Never>?
        var closed = false
    }
    private let state = Mutex(State())

    /// A new request starts; a connection that already closed stays closed (its -1 is not erased).
    func reset() { state.withLock { s in s.result = s.closed ? -1 : nil } }

    func fulfill(_ status: Int) {
        let c = state.withLock { s -> CheckedContinuation<Int, Never>? in
            if status < 0 { s.closed = true }
            s.result = status
            defer { s.continuation = nil }
            return s.continuation
        }
        c?.resume(returning: status)
    }

    /// -1 when the connection closed first.
    func wait() async -> Int {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { s -> Int? in
                if let r = s.result { return r }
                s.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

/// One accepted connection (ARCHITECTURE-MAC section 3.6): sequential HTTP/1.1 requests, one upstream for the whole connection.
final class GangwayConnection: @unchecked Sendable {
    private enum Next { case keepGoing, close }

    private struct Awaiting {
        var audit: ActivityEntry?
        var upgrade: Bool
        var overheadMicroseconds: Double
        var suffix = ""
    }
    private struct Shared {
        var awaiting: Awaiting?
        var lastActivity = ContinuousClock.now
        var idleArmed = false
        var idleTask: Task<Void, Never>?
        var closed = false
        var upstream: UpstreamLink?
    }

    private let downstream: NWStream
    private let ctx: GangwayContext
    private let shared = Mutex(Shared())
    private let status = StatusGate()
    private var buffer = Data()                 // touched only by `run()`
    private var session: GangwaySession?
    private var sessionCloser: UUID?
    private var pump: Task<Void, Never>?
    private var peerMemo: (resolved: Bool, peer: PeerProcess?) = (false, nil)

    init(downstream: NWStream, context: GangwayContext) {
        self.downstream = downstream
        self.ctx = context
    }

    // MARK: Lifecycle

    func run() async {
        defer { teardown() }
        armIdle()          // a connection that never sends a request line is closed too
        do {
            while true {
                guard let (head, consumed) = try await readHead() else { return }
                let parsedAt = ContinuousClock.now
                buffer.removeFirst(consumed)
                let next: Next
                do { next = try await serve(head, parsedAt: parsedAt) } catch let r as GangwayRejection {
                    try await respond(r.status, r.reason, close: true)
                    return
                }
                if next == .close { return }
            }
        } catch {
            return
        }
    }

    func cancel() {
        closeAll()
    }

    /// Records "forwarded, no response" for a request whose first response line never arrived.
    private func flushPendingAudit(reason: String) {
        let pending = shared.withLock { s -> ActivityEntry? in
            defer { s.awaiting = nil }
            return s.awaiting?.audit.map { entry in
                var e = entry
                e.result = reason + (s.awaiting?.suffix ?? "")
                return e
            }
        }
        if let pending { ctx.audit(pending) }
    }

    private func closeAll() {
        let already = shared.withLock { s -> Bool in
            defer { s.closed = true }
            return s.closed
        }
        guard !already else { return }
        flushPendingAudit(reason: "forwarded, no response")
        shared.withLock { $0.upstream }?.stream.cancel()
        downstream.cancel()
        status.fulfill(-1)
    }

    private func teardown() {
        closeAll()
        shared.withLock { $0.idleTask?.cancel(); $0.idleTask = nil }
        pump?.cancel()
        if let session, let sessionCloser { session.unregister(sessionCloser) }
    }

    // MARK: Reading a head

    private func readHead() async throws -> (HTTPRequestHead, Int)? {
        while true {
            do {
                if let parsed = try HTTPHeadParser.parse(buffer) { return parsed }
            } catch let error as HTTPParseError {
                try? await respond(400, "Wheelhouse: refused a malformed request (\(error.reason))", close: true)
                return nil
            }
            guard let data = try await downstream.receive() else { return nil }
            touch()
            buffer.append(data)
        }
    }

    // MARK: Idle deadline (one task per connection, no polling)

    private func touch() { shared.withLock { $0.lastActivity = .now } }

    /// Arms the idle deadline: a single `Task.sleep` until `lastActivity + timeout`, re-slept for the remainder on wake. Traffic only moves
    /// `lastActivity`; no task is created or cancelled per chunk.
    private func armIdle() {
        shared.withLock { s in
            guard !s.idleArmed, !s.closed else { return }
            s.idleArmed = true
            let timeout = ctx.idleTimeout
            ctx.countIdleTask()
            s.idleTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let deadline = self.shared.withLock { $0.lastActivity } + timeout
                    if ContinuousClock.now >= deadline {
                        let stillArmed = self.shared.withLock { $0.idleArmed }
                        if stillArmed { self.closeAll() }
                        return
                    }
                    try? await Task.sleep(until: deadline, tolerance: min(.seconds(5), timeout / 10), clock: .continuous)
                }
            }
        }
    }

    private func disarmIdle() {
        shared.withLock { s in
            s.idleArmed = false
            s.idleTask?.cancel()
            s.idleTask = nil
        }
    }

    // MARK: Responses of our own

    private func respond(_ code: Int, _ message: String, close: Bool) async throws {
        try await downstream.send(GangwayStatusBody.response(code: code, message: message, close: close))
        if close { downstream.finish() }
    }

    /// Refuses a request that may still have a body (ARCHITECTURE-MAC: a refusal must reach kubectl, not be lost to a reset).
    private func refuse(_ head: HTTPRequestHead, framing: HTTPFraming, code: Int, message: String) async throws -> Next {
        let expects = head.value("Expect") != nil
        switch framing {
        case .none:
            try await respond(code, message, close: false)
            return .keepGoing
        case .length(let n) where n <= 1 << 20 && !expects:
            var remaining = n
            let take = min(buffer.count, remaining)
            buffer.removeFirst(take)
            remaining -= take
            while remaining > 0 {
                guard let data = try await downstream.receive() else { return .close }
                remaining -= data.count
                if remaining < 0 { return .close }           // more than announced: a pipelined request
            }
            try await respond(code, message, close: false)
            return .keepGoing
        default:
            try await respond(code, message, close: true)
            // Linger: read and discard for a moment so the peer sees the response before any reset.
            await lingerDiscard()
            return .close
        }
    }

    private func lingerDiscard() async {
        let stream = downstream
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var total = 0
                while total < 4 << 20, let data = try? await stream.receive() { total += data.count }
            }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: One request

    private func serve(_ head: HTTPRequestHead, parsedAt: ContinuousClock.Instant) async throws -> Next {
        let framing: HTTPFraming
        do { framing = try HTTPHeadParser.framing(of: head) } catch let e as HTTPParseError { throw GangwayRejection(status: 400, reason: "Wheelhouse: \(e.reason)") }

        // Browser-style requests are never kubectl: refuse an Origin header, and a Host that is not this listener (DNS rebinding).
        let port = ctx.listenerPort
        let host = (head.value("Host") ?? "").lowercased()
        guard head.value("Origin") == nil, host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else {
            throw GangwayRejection(status: 400, reason: "Wheelhouse: unexpected Host or Origin header")
        }

        // 2. authenticate (every request) and pin the connection to its first session. The token is the bearer token of the session
        // kubeconfig; the loopback leg is TLS (a plain-http server makes kubectl drop kubeconfig credentials).
        guard let authorization = head.value("Authorization"), authorization.lowercased().hasPrefix("bearer ") else {
            return try await refuse(head, framing: framing, code: 401, message: "Wheelhouse: no session token in this request")
        }
        guard let found = ctx.registry.session(forToken: String(authorization.dropFirst(7)).trimmingCharacters(in: .whitespaces)) else {
            return try await refuse(head, framing: framing, code: 401, message: "Wheelhouse: session ended")
        }
        if let pinned = session, pinned.id != found.id { throw GangwayRejection(status: 400, reason: "Wheelhouse: a connection serves one session") }
        if session == nil {
            session = found
            sessionCloser = found.register { [weak self] in self?.cancel() }
        }
        let session = found
        if session.isRevoked { return try await refuse(head, framing: framing, code: 401, message: "Wheelhouse: session ended") }

        // /c/<clusterID> is the server path of the session kubeconfig. Tools that replace the whole path (`kubectl get --raw`) send none:
        // the token already names the cluster, so a request without the prefix is that cluster's. With a prefix it must be this session's.
        let rawPath = head.rawPath
        let prefix = "/c/\(session.clusterID)"
        let path: String
        if rawPath == "/c" || rawPath.hasPrefix("/c/") {
            if rawPath == prefix { path = "/" } else if rawPath.hasPrefix(prefix + "/") { path = String(rawPath.dropFirst(prefix.count)) } else {
                return try await refuse(head, framing: framing, code: 403, message: "Wheelhouse: this session belongs to another cluster")
            }
        } else {
            path = rawPath
        }

        // 3. canonicalise and classify.
        let analysis = try RequestClassifier.analyze(method: head.method, rawPath: path, rawQuery: head.rawQuery, headers: head.headers)
        var bufferedBody: Data?
        if analysis.needsBody {
            bufferedBody = try await bufferDeleteBody(framing: framing)
        }
        let classified = RequestClassifier.finish(analysis, headers: head.headers, body: bufferedBody)
        // Leftover bytes after a request without a body are a pipelined request.
        if bufferedBody == nil, framing == .none, !buffer.isEmpty, !head.isUpgrade {
            throw GangwayRejection(status: 400, reason: "Wheelhouse: pipelined requests are not supported")
        }

        // 4. decide against the LIVE configuration.
        guard let cluster = ctx.clusters.config(for: session.clusterID) else {
            return try await refuse(head, framing: framing, code: 403, message: "Wheelhouse: this cluster is no longer available")
        }
        var waitedForPerson = Duration.zero
        var auditBase = auditEntry(session: session, cluster: cluster, classified: classified, analysis: analysis)

        if let denial = sessionScopeDenial(classified, analysis: analysis, session: session, cluster: cluster, bufferedBody: bufferedBody) {
            auditBase.result = "refused: \(denial)" + impersonationNote(classified)
            auditIfNeeded(auditBase, classified: classified)
            return try await finishRefusal(head, framing: framing, code: 403, message: denial, bufferedBody: bufferedBody)
        }
        if ctx.isLocked, !isHarmless(classified.kind) {
            auditBase.result = "refused: locked" + impersonationNote(classified)
            auditIfNeeded(auditBase, classified: classified)
            return try await finishRefusal(head, framing: framing, code: 403, message: "Wheelhouse: Wheelhouse is locked", bufferedBody: bufferedBody)
        }
        var verdict = MutationPolicy.decide(gangway: classified, cluster: cluster, origin: session.origin.changeOrigin)
        var objectPeer: PeerProcess?
        if session.scope == .objects {
            // Every request of a Chart Room or Tides run, reads included, must come from the process it was opened for. Checked before
            // any body is buffered.
            objectPeer = resolvePeer(session: session)
            if !GrantStore.peerIsBound(objectPeer, to: session.binding) {
                let denial = "Wheelhouse: this request does not come from the reviewed operation"
                auditBase.result = "refused: \(denial)" + impersonationNote(classified)
                auditIfNeeded(auditBase, classified: classified)
                return try await finishRefusal(head, framing: framing, code: 403, message: denial, bufferedBody: bufferedBody)
            }
        }
        if session.scope == .objects, classified.kind == .mutation {
            // A Chart Room or Tides run: covered by its grant or refused, on every cluster; never a sheet from Gangway.
            if case .refuse = verdict {} else {
                // A create names its object in the body: read it (bounded), after the session, policy and peer checks.
                var createdName: CreatedName?
                let isCreate = head.method == "POST" && analysis.shape.isResourcePath && analysis.shape.name == nil && analysis.shape.legacyVerb == nil
                if isCreate, bufferedBody == nil {
                    if head.value("Expect") != nil {
                        return try await finishRefusal(head, framing: framing, code: 403, message: "Wheelhouse: Expect is not supported in a Chart Room run", bufferedBody: nil)
                    }
                    do { bufferedBody = try await bufferDeleteBody(framing: framing, limit: GrantBody.maxCreateBody) } catch let r as GangwayRejection {
                        try await respond(r.status, r.reason, close: true)
                        await lingerDiscard()
                        return .close
                    }
                }
                if isCreate { createdName = GrantBody.createdName(body: bufferedBody, headers: head.headers, pathNamespace: analysis.shape.namespace) }
                let covered = ctx.grants.covers(GrantRequest(kind: .mutation, shape: analysis.shape, method: head.method, createdName: createdName),
                                                session: session, peer: objectPeer)
                verdict = covered ? .pass : .refuse("Wheelhouse: this change is not part of the reviewed operation")
            }
        }
        switch verdict {
        case .pass:
            break
        case .refuse(let message):
            auditBase.result = "refused: \(message)" + impersonationNote(classified)
            auditIfNeeded(auditBase, classified: classified)
            return try await finishRefusal(head, framing: framing, code: 403, message: message, bufferedBody: bufferedBody)
        case .confirm(let requiresTyping):
            let peer = session.scope == .standard ? resolvePeer(session: session) : nil
            let request = GrantRequest(kind: classified.kind, shape: analysis.shape, method: head.method)
            if !ctx.grants.covers(request, session: session, peer: peer) {
                let hold = GangwayHold(
                    id: UUID(), sessionID: session.id, clusterID: cluster.id, clusterName: cluster.name, request: classified, method: head.method,
                    path: analysis.canonicalPath, query: head.rawQuery,
                    bodySHA256: bufferedBody.map(Hashing.sha256Hex), reportedCommand: session.reportedCommand?.line,
                    execCommand: analysis.query.filter { $0.key == "command" }.map(\.value), requiresTyping: requiresTyping, origin: session.origin, peerGroup: peer?.group)
                let waitStart = ContinuousClock.now
                disarmIdle()
                let outcome = await ctx.holds.request(hold, peerBound: GrantStore.peerIsBound(peer, to: session.binding))
                waitedForPerson += ContinuousClock.now - waitStart
                touch()
                armIdle()
                var approved = outcome == .approved && !session.isRevoked
                let liveConfig = ctx.clusters.config(for: session.clusterID)
                if liveConfig == nil { approved = false }                                  // the cluster went away while held
                if approved, ctx.isLocked {                                                // the app locked while held
                    auditBase.result = "refused: locked" + impersonationNote(classified)
                    auditIfNeeded(auditBase, classified: classified)
                    return try await finishRefusal(head, framing: framing, code: 403, message: "Wheelhouse: Wheelhouse is locked", bufferedBody: bufferedBody)
                }
                if approved, !hold.isStream {
                    let peerNow = peer.flatMap { ctx.resolver.refresh($0) }
                    approved = ctx.grants.covers(GrantRequest(holdID: hold.id, kind: classified.kind, shape: analysis.shape, method: head.method),
                                                 session: session, peer: peerNow)
                }
                // 8. Re-check the live configuration after the wait (it may have become read-only meanwhile).
                if approved, let live = liveConfig,
                   case .refuse(let message) = MutationPolicy.decide(gangway: classified, cluster: live, origin: session.origin.changeOrigin) {
                    auditBase.result = "refused: \(message)" + impersonationNote(classified)
                    auditIfNeeded(auditBase, classified: classified)
                    return try await finishRefusal(head, framing: framing, code: 403, message: message, bufferedBody: bufferedBody)
                }
                guard approved else {
                    auditBase.result = "refused: not confirmed" + impersonationNote(classified)
                    auditIfNeeded(auditBase, classified: classified)
                    return try await finishRefusal(head, framing: framing, code: 403, message: "Wheelhouse: change not confirmed", bufferedBody: bufferedBody)
                }
            }
        }

        // 7. forward.
        return try await forward(head, framing: framing, path: path, analysis: analysis, classified: classified, bufferedBody: bufferedBody,
                                 session: session, cluster: cluster, audit: auditBase, parsedAt: parsedAt, waited: waitedForPerson)
    }

    private func isHarmless(_ kind: GangwayClass) -> Bool {
        switch kind {
        case .read, .review, .dryRun: true
        case .stream, .proxy, .mutation: false
        }
    }

    /// A refusal of a request whose body may already be buffered (deletes): nothing left to drain then.
    private func finishRefusal(_ head: HTTPRequestHead, framing: HTTPFraming, code: Int, message: String, bufferedBody: Data?) async throws -> Next {
        if bufferedBody != nil {
            try await respond(code, message, close: false)
            return .keepGoing
        }
        return try await refuse(head, framing: framing, code: code, message: message)
    }

    /// The session scope rules that come before the policy table: dry-run-only sessions never change, stream or proxy; object sessions
    /// never open streams or proxies.
    private func sessionScopeDenial(_ classified: GangwayRequestClass, analysis: RequestClassifier.Analysis, session: GangwaySession,
                                    cluster: ClusterConfig, bufferedBody: Data?) -> String? {
        switch session.scope {
        case .standard:
            return nil
        case .dryRunOnly:
            return isHarmless(classified.kind) && classified.impersonation.isEmpty ? nil : "Wheelhouse: this session may only read and dry-run on \(cluster.name)"
        case .objects:
            if !classified.impersonation.isEmpty { return "Wheelhouse: impersonation is not allowed in a Chart Room run" }
            switch classified.kind {
            case .stream, .proxy: return "Wheelhouse: this session may not open streams or proxy requests"
            default: return nil
            }
        }
    }

    private func resolvePeer(session: GangwaySession) -> PeerProcess? {
        if peerMemo.resolved { return peerMemo.peer.flatMap { ctx.resolver.refresh($0) } }
        // A session that is not bound yet (a helm run between its spawn and its bind) is looked up again on the next request.
        if case .none = session.binding { return nil }
        peerMemo.resolved = true
        guard let port = downstream.remotePort else { return nil }
        let scope: PeerSearchScope
        switch session.binding {
        case .none: return nil
        case .pty(let device, _, _): scope = .tty(device)
        case .processGroup(let group), .isolatedGroup(let group): scope = .processGroup(group)
        }
        peerMemo.peer = ctx.resolver.resolve(clientPort: port, listenerPort: ctx.listenerPort, scope: scope)
        return peerMemo.peer
    }

    // MARK: Delete bodies

    /// Buffers the body of a DELETE or an eviction (at most 64 KB; larger is 413). The bytes never reach the buffer again.
    private func bufferDeleteBody(framing: HTTPFraming, limit: Int = RequestClassifier.maxDeleteBody) async throws -> Data {
        let limitText = limit >= 1 << 20 ? "\(limit >> 20) MB" : "\(limit >> 10) KB"
        switch framing {
        case .none:
            return Data()
        case .length(let n):
            guard n <= limit else { throw GangwayRejection(status: 413, reason: "Wheelhouse: the request body is too large to check (limit \(limitText))") }
            var body = Data()
            while body.count < n {
                if !buffer.isEmpty {
                    let take = min(buffer.count, n - body.count)
                    body.append(buffer.prefix(take))
                    buffer.removeFirst(take)
                } else {
                    guard let data = try await downstream.receive() else { throw GangwayRejection(status: 400, reason: "Wheelhouse: the request body ended early") }
                    buffer.append(data)
                }
            }
            return body
        case .chunked:
            var parser = ChunkedBodyReencoder(decode: true)
            var body = Data()
            while !parser.isFinished {
                if buffer.isEmpty {
                    guard let data = try await downstream.receive() else { throw GangwayRejection(status: 400, reason: "Wheelhouse: the request body ended early") }
                    buffer.append(data)
                }
                do {
                    let (out, used) = try parser.feed(buffer)
                    body.append(out)
                    buffer.removeFirst(used)
                } catch let e as HTTPParseError { throw GangwayRejection(status: 400, reason: "Wheelhouse: \(e.reason)") }
                if body.count > limit { throw GangwayRejection(status: 413, reason: "Wheelhouse: the request body is too large to check (limit \(limitText))") }
            }
            return body
        }
    }

    // MARK: Audit

    private func auditEntry(session: GangwaySession, cluster: ClusterConfig, classified: GangwayRequestClass, analysis: RequestClassifier.Analysis) -> ActivityEntry {
        var origin = session.origin.changeOrigin
        if case .terminal(let pane, _) = origin { origin = .terminal(session: pane, reportedCommand: session.reportedCommand?.line) }
        let verb: String
        switch classified.kind {
        case .stream(let kind):
            switch kind {
            case .exec: verb = "exec"
            case .attach: verb = "attach"
            case .portForward: verb = "port-forward"
            case .otherUpgrade: verb = "upgrade"
            }
        case .proxy: verb = "proxy"
        case .read: verb = classified.impersonation.isEmpty ? "get" : "impersonated get"
        case .review: verb = "review"
        case .dryRun, .mutation:
            switch analysis.method {
            case "POST": verb = analysis.isEviction ? "evict" : "create"
            case "PUT": verb = "replace"
            case "PATCH": verb = "patch"
            case "DELETE": verb = "delete"
            default: verb = analysis.method.lowercased()
            }
        }
        var object = analysis.shape.resource.isEmpty ? analysis.canonicalPath : analysis.shape.resource
        if let name = analysis.shape.name { object += "/\(name)" }
        if let ns = analysis.shape.namespace, analysis.shape.resource != "namespaces" { object = "\(ns)/\(object)" }
        var result = "forwarded"
        if !classified.impersonation.isEmpty {
            result += " · " + classified.impersonation.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
        }
        if case .dryRun = classified.kind { result += " · dry-run" }
        return ActivityEntry(cluster: cluster.id, origin: origin, verb: verb, object: object, result: result, commandLine: session.reportedCommand?.line)
    }

    /// Every mutation, stream and proxy request, and every request with `Impersonate-*` headers, is audited.
    private func auditIfNeeded(_ entry: ActivityEntry, classified: GangwayRequestClass) {
        if needsAudit(classified) { ctx.audit(entry) }
    }

    private func impersonationNote(_ classified: GangwayRequestClass) -> String {
        classified.impersonation.isEmpty ? "" : " · " + classified.impersonation.map { "\($0.name)=\($0.value)" }.joined(separator: ", ")
    }

    private func needsAudit(_ classified: GangwayRequestClass) -> Bool {
        switch classified.kind {
        case .stream, .proxy, .mutation: true
        case .read, .review, .dryRun: !classified.impersonation.isEmpty
        }
    }

    // MARK: Forwarding

    private func forward(_ head: HTTPRequestHead, framing: HTTPFraming, path: String, analysis: RequestClassifier.Analysis, classified: GangwayRequestClass,
                         bufferedBody: Data?, session: GangwaySession, cluster: ClusterConfig, audit: ActivityEntry, parsedAt: ContinuousClock.Instant,
                         waited: Duration) async throws -> Next {
        let state = signposter.beginInterval("request")
        defer { signposter.endInterval("request", state) }
        let connectStart = ContinuousClock.now
        var connected = false
        let link: UpstreamLink
        if let existing = shared.withLock({ $0.upstream }) { link = existing } else {
            connected = true
            do {
                let target = try await ctx.clusters.upstream(for: session.clusterID)
                link = try await ctx.connector.connect(target)
            } catch {
                var entry = audit
                entry.result = "failed: \(error.localizedDescription)"
                ctx.audit(entry)
                // The client gets a generic message (an exec plugin's stderr can hold account details); the detail is in the audit entry.
                let generic = "Wheelhouse could not reach the cluster or get credentials for it. See Activity for details."
                if bufferedBody != nil || framing == .none {
                    try await respond(502, generic, close: false)
                    return .keepGoing
                }
                try await respond(502, generic, close: true)
                return .close
            }
            let stored = shared.withLock { s -> Bool in
                if s.closed { return false }
                s.upstream = link
                return true
            }
            guard stored else {                                    // revoked, locked or closed while connecting: nothing is sent
                link.stream.cancel()
                return .close
            }
            startPump(link)
        }
        // An upgrade is only ever the first request on a fresh upstream connection, so the first status line after it is its own.
        if head.isUpgrade, !connected { throw GangwayRejection(status: 400, reason: "Wheelhouse: an upgrade needs a new connection") }
        let connectTime = connected ? (ContinuousClock.now - connectStart) : Duration.zero

        let isUpgrade = head.isUpgrade
        // The head Gangway writes is fresh: nothing of the received bytes is forwarded as is.
        var out = "\(head.method) \(link.basePath)\(path)"
        if let q = head.rawQuery { out += "?\(q)" }
        out += " HTTP/1.1\r\nHost: \(link.hostHeader)\r\n"
        let dropped: Set<String> = ["host", "authorization", "proxy-authorization", "connection", "keep-alive", "te", "trailer", "upgrade",
                                    "content-length", "transfer-encoding", "proxy-connection"]
        for header in head.headers where !dropped.contains(header.name.lowercased()) && !header.name.lowercased().hasPrefix("proxy-")
            && !header.name.lowercased().hasPrefix("x-remote-") {
            out += "\(header.name): \(header.value)\r\n"
        }
        // An exec plugin's token is asked for on every request (the provider caches it and renews it when it expires).
        var authorization = link.authorization
        if let provider = link.provider, let token = try? await provider.authorization()?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            authorization = "Bearer \(token)"
        }
        if let authorization { out += "Authorization: \(authorization)\r\n" }
        if isUpgrade, let upgrade = head.value("Upgrade") { out += "Connection: Upgrade\r\nUpgrade: \(upgrade)\r\n" }
        switch framing {
        case .none: if bufferedBody != nil { out += "Content-Length: \(bufferedBody?.count ?? 0)\r\n" }
        case .length(let n): out += "Content-Length: \(bufferedBody?.count ?? n)\r\n"
        case .chunked: out += bufferedBody == nil ? "Transfer-Encoding: chunked\r\n" : "Content-Length: \(bufferedBody?.count ?? 0)\r\n"
        }
        out += "\r\n"

        // Last look before anything reaches the API server (and before it is logged as forwarded): revoked, closed or locked while we waited.
        if shared.withLock({ $0.closed }) || session.isRevoked || (ctx.isLocked && !isHarmless(classified.kind)) {
            try? await respond(401, "Wheelhouse: session ended", close: true)
            return .close
        }

        // Every change, stream, proxy request and impersonation attempt is recorded when it is forwarded, before any response; the status
        // follows as a second entry, or "no response" when the connection ends first.
        flushPendingAudit(reason: "forwarded, response status not seen")
        var entry = audit
        let suffix = impersonationNote(classified) + (classified.kind == .dryRun ? " · dry-run" : "")
        entry.result = "forwarded" + suffix
        if needsAudit(classified) { ctx.audit(entry) }
        shared.withLock { s in
            s.awaiting = Awaiting(audit: needsAudit(classified) ? audit : nil, upgrade: isUpgrade, overheadMicroseconds: 0, suffix: suffix)
        }
        status.reset()
        if isUpgrade || (classified.kind == .read && head.rawQuery?.contains("watch") == true) || isLongRunning(classified, analysis: analysis) {
            disarmIdle()
        } else {
            armIdle()
        }
        touch()
        var wire = Data(out.utf8)
        if let bufferedBody { wire.append(bufferedBody) }
        try await link.stream.send(wire)
        let overhead = (ContinuousClock.now - parsedAt) - waited - connectTime
        shared.withLock { $0.awaiting?.overheadMicroseconds = max(0, overhead.microseconds) }

        // Body.
        if bufferedBody == nil {
            switch framing {
            case .none: break
            case .length(let n): try await pipeBody(length: n, to: link)
            case .chunked: try await pipeChunked(to: link)
            }
        }

        if isUpgrade {
            let code = await status.wait()
            guard code == 101 else { return .close }
            return try await rawPipe(link: link, classified: classified, session: session, cluster: cluster)
        }
        return .keepGoing
    }

    private func isLongRunning(_ classified: GangwayRequestClass, analysis: RequestClassifier.Analysis) -> Bool {
        if analysis.shape.legacyVerb == "watch" || analysis.shape.subresource == "log" { return true }
        let watch = analysis.query.contains { $0.key == "watch" && ($0.value == "true" || $0.value == "1") }
        if watch { return true }
        switch classified.kind {
        case .stream, .proxy: return true
        default: return false
        }
    }

    private func pipeBody(length: Int, to link: UpstreamLink) async throws {
        var remaining = length
        while remaining > 0 {
            if buffer.isEmpty {
                guard let data = try await downstream.receive() else { throw StreamError.closed }
                buffer.append(data)
            }
            let take = min(buffer.count, remaining)
            let piece = Data(buffer.prefix(take))
            buffer.removeFirst(take)
            remaining -= take
            touch()
            try await link.stream.send(piece)
        }
        // Bytes beyond the announced length are a pipelined request.
        if !buffer.isEmpty { throw StreamError.closed }
    }

    private func pipeChunked(to link: UpstreamLink) async throws {
        var parser = ChunkedBodyReencoder()
        while !parser.isFinished {
            if buffer.isEmpty {
                guard let data = try await downstream.receive() else { throw StreamError.closed }
                buffer.append(data)
            }
            let (out, used) = try parser.feed(buffer)
            buffer.removeFirst(used)
            touch()
            try await link.stream.send(out)
        }
        if !buffer.isEmpty { throw StreamError.closed }
    }

    // MARK: Response pump (a pure byte pipe)

    private func startPump(_ link: UpstreamLink) {
        pump = Task { [weak self] in
            do {
                while let data = try await link.stream.receive() {
                    guard let self else { return }
                    let arrived = ContinuousClock.now
                    self.touch()
                    var overhead: Double?
                    if let awaiting = self.shared.withLock({ s -> Awaiting? in
                        guard let a = s.awaiting else { return nil }
                        guard let code = Self.statusCode(of: data) else { s.awaiting = nil; return a }
                        if code == 100 { return nil }                  // interim: keep waiting for the real status line
                        s.awaiting = nil
                        return a
                    }) {
                        let code = Self.statusCode(of: data) ?? 0
                        if var entry = awaiting.audit {
                            entry.result = "HTTP \(code)" + awaiting.suffix
                            self.ctx.audit(entry)
                        }
                        overhead = awaiting.overheadMicroseconds
                        if code == 401, let provider = link.provider { Task { await provider.invalidate() } }
                        // The first chunk reaches the client BEFORE the status is announced: whoever acts on the status (a refused upgrade
                        // closes the connection) must not cut the response off.
                        try await self.downstream.send(data)
                        self.status.fulfill(code)
                        if let overhead { self.ctx.metrics.record(microseconds: overhead + (ContinuousClock.now - arrived).microseconds) }
                        continue
                    }
                    try await self.downstream.send(data)
                    if let overhead { self.ctx.metrics.record(microseconds: overhead + (ContinuousClock.now - arrived).microseconds) }
                }
            } catch {}
            self?.closeAll()
        }
    }

    static func statusCode(of data: Data) -> Int? {
        guard data.count >= 12, data.prefix(5) == Data("HTTP/".utf8) else { return nil }
        let line = String(decoding: data.prefix(16), as: UTF8.self)
        let parts = line.split(separator: " ", maxSplits: 2)
        return parts.count >= 2 ? Int(parts[1].prefix(3)) : nil
    }

    // MARK: Upgraded streams

    private func rawPipe(link: UpstreamLink, classified: GangwayRequestClass, session: GangwaySession, cluster: ClusterConfig) async throws -> Next {
        disarmIdle()
        guard case .stream(let kind) = classified.kind else {
            // An upgrade the classifier did not call a stream cannot happen (any Upgrade header is a stream); fail closed.
            return .close
        }
        let id = ctx.register(stream: StreamRecord(clusterID: cluster.id, sessionID: session.id, openedOnProduction: cluster.environment.requiresTypeToConfirm,
                                                   kind: kind, close: { [weak self] reason in
            self?.ctx.audit(ActivityEntry(cluster: cluster.id, origin: session.origin.changeOrigin, verb: "stream closed", object: nil, result: reason))
            self?.cancel()
        }))
        defer { ctx.unregister(stream: id) }
        // The lock or the policy may have changed between the decision and this registration (a closer that ran earlier did not see this
        // stream): check once more, now that it can be closed.
        if ctx.isLocked { cancel(); return .close }
        if let live = ctx.clusters.config(for: cluster.id) {
            if case .refuse = MutationPolicy.decide(gangway: classified, cluster: live, origin: session.origin.changeOrigin) { cancel(); return .close }
            if live.environment.requiresTypeToConfirm, !cluster.environment.requiresTypeToConfirm { cancel(); return .close }
        } else { cancel(); return .close }
        if !buffer.isEmpty {
            try await link.stream.send(buffer)
            buffer.removeAll()
        }
        while let data = try await downstream.receive() {
            try await link.stream.send(data)
        }
        return .close
    }
}
#endif
