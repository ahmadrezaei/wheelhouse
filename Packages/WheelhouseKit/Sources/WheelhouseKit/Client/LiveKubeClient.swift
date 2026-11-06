import Foundation
import Security
import Synchronization

/// REST client for a real cluster. One instance per cluster; owns its `URLSession` and TLS delegate.
public actor LiveKubeClient: KubeClientProtocol {
    public nonisolated let config: ClusterConfig
    private nonisolated let session: URLSession
    nonisolated let delegate: ClusterSessionDelegate
    private nonisolated let token: String?
    private nonisolated let identity: LazyClientIdentity?
    private nonisolated let anchors: [SecCertificate]
    private nonisolated let hasConnected = Mutex(false)
    private nonisolated let auxiliary = Mutex<URLSession?>(nil)
    /// Watch objects that could not be decoded and were skipped (a broken CRD must not kill the stream).
    private nonisolated let skippedWatchObjects = Mutex(0)

    /// `tlsServerName` is the kubeconfig `tls-server-name`: the name the server certificate must be valid for.
    public init(config: ClusterConfig, secrets: ClusterSecrets, tlsServerName: String? = nil) {
        self.init(config: config, secrets: secrets, tlsServerName: tlsServerName, protocolClasses: nil)
    }

    /// `protocolClasses` lets tests install a `URLProtocol` that captures outgoing requests.
    init(config: ClusterConfig, secrets: ClusterSecrets, tlsServerName: String? = nil, protocolClasses: [AnyClass]?) {
        self.config = config
        self.token = secrets.token?.trimmingCharacters(in: .whitespacesAndNewlines)

        let anchors = secrets.caPEM.map { PEM.decode($0).filter { $0.label == "CERTIFICATE" }.compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) } } ?? []
        var lazyIdentity: LazyClientIdentity?
        if config.authKind == .clientCertificate, let cert = secrets.clientCertificatePEM, let key = secrets.clientKeyPEM {
            let id = config.id
            // The keychain work (SecItemAdd, identity query) happens off the main thread: prewarmed here, awaited on first use.
            lazyIdentity = LazyClientIdentity { try ClientIdentityBuilder.build(certificatePEM: cert, keyPEM: key, label: ClientIdentityBuilder.label(for: id)) }
        }
        self.identity = lazyIdentity
        self.anchors = anchors
        // Production clusters can never skip verification (see ClusterConfig.allowsInsecureTLS).
        let provider: (@Sendable () -> Result<ClientIdentityBuilder.Result, ClientIdentityError>)? = lazyIdentity.map { li in
            { @Sendable in
                let r = li.resolve()
                if let built = r.built { return .success(built) }
                return .failure(r.error ?? .identityNotFound)
            }
        }
        let delegate = ClusterSessionDelegate(anchors: anchors, insecure: config.allowsInsecureTLS, serverName: tlsServerName,
                                              identityProvider: provider)
        self.delegate = delegate
        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = 30
        sc.waitsForConnectivity = false
        sc.httpMaximumConnectionsPerHost = 8
        sc.httpAdditionalHeaders = ["User-Agent": "Wheelhouse/1.0"]
        if let protocolClasses { sc.protocolClasses = protocolClasses }
        self.session = URLSession(configuration: sc, delegate: delegate, delegateQueue: nil)
        if let lazyIdentity { Task.detached(priority: .utility) { _ = lazyIdentity.resolve() } }
    }

    /// Number of watch objects skipped because they failed to decode.
    public nonisolated var skippedWatchObjectCount: Int { skippedWatchObjects.withLock { $0 } }

    deinit {
        session.invalidateAndCancel()
        auxiliary.withLock { $0?.invalidateAndCancel() }
    }

    /// A `URLSession` for talking to *other* endpoints of this cluster's environment (a user-supplied Prometheus URL):
    /// system trust first, then the cluster CA; honours the cluster's skip-verify setting; never presents the client certificate.
    public nonisolated func auxiliarySession() -> URLSession {
        auxiliary.withLock { existing in
            if let existing { return existing }
            let sc = URLSessionConfiguration.ephemeral
            sc.timeoutIntervalForRequest = 30
            sc.httpAdditionalHeaders = ["User-Agent": "Wheelhouse/1.0"]
            let d = ClusterSessionDelegate(anchors: anchors, insecure: config.allowsInsecureTLS, systemTrustFirst: true)
            let made = URLSession(configuration: sc, delegate: d, delegateQueue: nil)
            existing = made
            return made
        }
    }

    // MARK: Request plumbing

    private nonisolated func guardMutable(_ kind: ResourceKind? = nil) throws {
        if config.readOnly {
            // Access reviews are POSTs but read-only in effect.
            if let kind, kind == .selfSubjectAccessReview || kind == .selfSubjectRulesReview { return }
            throw KubeError.readOnly
        }
    }

    /// Refuses cleartext HTTP for production clusters (the bearer token would travel unencrypted) and surfaces a client
    /// certificate that could not be loaded.
    private nonisolated func guardTransport() throws {
        if config.isProduction, config.server.scheme?.lowercased() == "http" {
            throw KubeError.unreachable(cause: "Plain HTTP is not allowed for production clusters. Use an https:// API server URL.")
        }
        if let identity, let error = identity.resolve().error {
            throw KubeError.unauthorized(message: "Client certificate could not be loaded (\(error))")
        }
    }

    nonisolated func makeURL(path: String, query: [(String, String)] = [], websocket: Bool = false) throws -> URL {
        guard var comps = URLComponents(url: config.server, resolvingAgainstBaseURL: false) else {
            throw KubeError.unreachable(cause: "Invalid server URL")
        }
        let base = comps.percentEncodedPath.hasSuffix("/") ? String(comps.percentEncodedPath.dropLast()) : comps.percentEncodedPath
        comps.percentEncodedPath = base + path
        if websocket { comps.scheme = comps.scheme == "http" ? "ws" : "wss" }
        if !query.isEmpty {
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            comps.percentEncodedQuery = query.map { k, v in
                "\(k.addingPercentEncoding(withAllowedCharacters: allowed) ?? k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
            }.joined(separator: "&")
        }
        guard let url = comps.url else { throw KubeError.unreachable(cause: "Invalid request URL") }
        return url
    }

    nonisolated func makeRequest(path: String, query: [(String, String)] = [], method: String = "GET",
                                 contentType: String? = nil, body: Data? = nil, timeout: TimeInterval = 30) throws -> URLRequest {
        try guardTransport()
        var req = URLRequest(url: try makeURL(path: path, query: query), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        req.httpBody = body
        return req
    }

    /// Non-secret TLS facts for the connection report (challenge outcomes, client identity, last error chain).
    public nonisolated var tlsTrace: TLSTrace { delegate.trace }

    /// Maps an HTTP error status; a 401 on a client-certificate cluster carries the identity problem (if any) so the reason isn't lost.
    private nonisolated func httpError(code: Int, body: Data) -> KubeError {
        let e = Status.decodeError(code: code, body: body)
        if case .unauthorized(let m) = e, let note = delegate.identityNote { return .unauthorized(message: KubeError.appendingIdentityNote(note, to: m)) }
        return e
    }

    /// `responseReceived`: the task already got an HTTP response, so a later `-1005` / SSL-domain error is a dropped stream, never a handshake failure.
    nonisolated func mapTransportError(_ error: Error, responseReceived: Bool = false) -> KubeError {
        if let kube = error as? KubeError { return kube }
        if error is CancellationError { return .cancelled }
        guard let url = error as? URLError else { return .unreachable(cause: error.localizedDescription) }
        delegate.recordTransportError(url)
        let failure = delegate.failure(for: url.failureURLString.flatMap(URL.init(string:)))
        let https = config.server.scheme?.lowercased() == "https"
        switch url.code {
        case .cancelled:
            // A rejected server-trust challenge surfaces as -999. Real task cancellation never follows a rejection.
            if let failure { return .tlsUntrusted(summary: failure.summary) }
            if !Task.isCancelled, https, delegate.trace.serverTrust == .failed {
                return .tlsUntrusted(summary: nil)
            }
            return .cancelled
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return .tlsUntrusted(summary: failure?.summary)
        case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired, .networkConnectionLost:
            if responseReceived { return .unreachable(cause: "Connection lost") }
            if failure != nil { return .tlsUntrusted(summary: failure?.summary) }
            if https, let e = TLSDiagnostics.handshakeError(for: url, clientIdentityFailure: delegate.identityFailure,
                                                           clientCertificateMissing: delegate.clientCertificateMissing,
                                                           neverConnected: !hasConnected.withLock { $0 }) { return e }
            if url.code == .networkConnectionLost { return .unreachable(cause: "Connection lost") }
            return .tlsHandshake(reason: "TLS handshake failed.", code: url.code.rawValue)
        case .timedOut: return .unreachable(cause: "Timed out")
        case .cannotFindHost, .dnsLookupFailed: return .unreachable(cause: "DNS lookup failed for \(config.host)")
        case .cannotConnectToHost: return .unreachable(cause: "Connection refused by \(config.host)")
        case .notConnectedToInternet: return .unreachable(cause: "No internet connection")
        default: return .unreachable(cause: url.localizedDescription)
        }
    }

    private nonisolated func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KubeError.decoding("Not an HTTP response") }
            hasConnected.withLock { $0 = true }
            guard (200..<300).contains(http.statusCode) else { throw httpError(code: http.statusCode, body: data) }
            return data
        } catch { throw mapTransportError(error) }
    }

    private nonisolated func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try KubeJSON.decoder.decode(T.self, from: data) }
        catch { throw KubeError.decoding(String(describing: error).prefix(300).description) }
    }

    private nonisolated func queryItems(_ o: ListOptions) -> [(String, String)] {
        var q: [(String, String)] = []
        if let v = o.labelSelector, !v.isEmpty { q.append(("labelSelector", v)) }
        if let v = o.fieldSelector, !v.isEmpty { q.append(("fieldSelector", v)) }
        if let v = o.limit { q.append(("limit", String(v))) }
        if let v = o.resourceVersion { q.append(("resourceVersion", v)) }
        return q
    }

    private nonisolated func mutationQuery(_ o: MutationOptions, apply: Bool = false) -> [(String, String)] {
        var q: [(String, String)] = [("fieldManager", o.fieldManager)]
        if o.dryRun { q.append(("dryRun", "All")) }
        if apply, o.force { q.append(("force", "true")) }
        return q
    }

    // MARK: Version & discovery

    public func version() async throws -> KubeVersion {
        try decode(KubeVersion.self, from: try await perform(try makeRequest(path: "/version")))
    }

    public func discovery() async throws -> DiscoveryInfo {
        var targets: [(group: String, version: String, path: String)] = [("", "v1", "/api/v1")]
        let groups = try JSONValue.parse(try await perform(try makeRequest(path: "/apis")))
        for g in groups["groups"]?.arrayValue ?? [] {
            if let gv = g["preferredVersion"]?["groupVersion"]?.stringValue,
               let name = g["name"]?.stringValue, let version = g["preferredVersion"]?["version"]?.stringValue {
                targets.append((name, version, "/apis/\(gv)"))
            }
        }
        let resources = await withTaskGroup(of: [APIResource].self) { taskGroup in
            for t in targets {
                taskGroup.addTask { [self] in
                    guard let data = try? await perform(try makeRequest(path: t.path)),
                          let json = try? JSONValue.parse(data) else { return [] }
                    return (json["resources"]?.arrayValue ?? []).compactMap { r -> APIResource? in
                        guard let name = r["name"]?.stringValue, let kind = r["kind"]?.stringValue else { return nil }
                        return APIResource(name: name, singularName: r["singularName"]?.stringValue,
                                           namespaced: r["namespaced"]?.boolValue ?? false, kind: kind,
                                           verbs: (r["verbs"]?.arrayValue ?? []).compactMap(\.stringValue),
                                           shortNames: r["shortNames"]?.arrayValue?.compactMap(\.stringValue),
                                           group: t.group, version: t.version)
                    }
                }
            }
            var all: [APIResource] = []
            for await part in taskGroup { all += part }
            return all
        }
        return DiscoveryInfo(resources: resources)
    }

    // MARK: Reads

    public func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        var opts = options
        let paginate = options.limit == nil
        if paginate { opts.limit = 500 }
        var all: KubeList<T>?
        var continueToken: String?
        repeat {
            var q = queryItems(opts)
            if let continueToken { q.append(("continue", continueToken)) }
            let page = try decode(KubeList<T>.self, from: try await perform(try makeRequest(path: kind.collectionPath(namespace: namespace), query: q)))
            if var existing = all {
                existing.items += page.items
                existing.skippedItems += page.skippedItems
                all = existing
            } else { all = page }
            continueToken = paginate ? page.metadata.continue.flatMap { $0.isEmpty ? nil : $0 } : nil
        } while continueToken != nil
        return all ?? KubeList(items: [])
    }

    public func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T {
        try decode(T.self, from: try await perform(try makeRequest(path: kind.itemPath(name: name, namespace: namespace))))
    }

    public func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue {
        let data = try await perform(try makeRequest(path: kind.collectionPath(namespace: namespace), query: queryItems(options)))
        return try decode(JSONValue.self, from: data)
    }

    public func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue {
        try decode(JSONValue.self, from: try await perform(try makeRequest(path: kind.itemPath(name: name, namespace: namespace))))
    }

    // MARK: Watch

    private struct WatchFrame<T: Decodable>: Decodable {
        enum Payload { case object(T), bookmark(String), failure(Status), undecodable }
        let type: String
        let payload: Payload
        enum CodingKeys: String, CodingKey { case type, object }
        struct BookmarkObject: Decodable { struct Meta: Decodable { var resourceVersion: String? }; var metadata: Meta }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            switch type {
            case "ERROR": payload = .failure(try c.decode(Status.self, forKey: .object))
            case "BOOKMARK": payload = .bookmark((try? c.decode(BookmarkObject.self, forKey: .object).metadata.resourceVersion) ?? "")
            default:
                // One object that does not fit the model must not end the whole watch.
                if let object = try? c.decode(T.self, forKey: .object) { payload = .object(object) } else { payload = .undecodable }
            }
        }
    }

    public nonisolated func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var gotResponse = false
                do {
                    var q: [(String, String)] = [("watch", "1"), ("allowWatchBookmarks", "true"), ("timeoutSeconds", String(options.timeoutSeconds))]
                    if let v = options.resourceVersion { q.append(("resourceVersion", v)) }
                    if let v = options.labelSelector, !v.isEmpty { q.append(("labelSelector", v)) }
                    if let v = options.fieldSelector, !v.isEmpty { q.append(("fieldSelector", v)) }
                    let request = try makeRequest(path: kind.collectionPath(namespace: namespace), query: q, timeout: TimeInterval(options.timeoutSeconds + 30))
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw KubeError.decoding("Not an HTTP response") }
                    gotResponse = true
                    hasConnected.withLock { $0 = true }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 8192 { break } }
                        throw httpError(code: http.statusCode, body: body)
                    }
                    let decoder = KubeJSON.decoder
                    // Frames are newline-delimited JSON. Split on the 0x0A byte only: `bytes.lines` would also split on
                    // U+0085 / U+2028 / U+2029, which may legitimately appear inside JSON strings.
                    var buffer: [UInt8] = []
                    buffer.reserveCapacity(4096)
                    func process(_ line: [UInt8]) throws {
                        guard !line.isEmpty else { return }
                        let frame: WatchFrame<T>
                        do { frame = try decoder.decode(WatchFrame<T>.self, from: Data(line)) } catch {
                            skippedWatchObjects.withLock { $0 += 1 }
                            return
                        }
                        switch (frame.type, frame.payload) {
                        case ("ADDED", .object(let o)): continuation.yield(.added(o))
                        case ("MODIFIED", .object(let o)): continuation.yield(.modified(o))
                        case ("DELETED", .object(let o)): continuation.yield(.deleted(o))
                        case (_, .bookmark(let rv)): continuation.yield(.bookmark(resourceVersion: rv))
                        case (_, .failure(let s)): throw KubeError.from(httpStatus: s.code ?? 500, status: s)
                        case (_, .undecodable): skippedWatchObjects.withLock { $0 += 1 }
                        default: break
                        }
                    }
                    for try await byte in bytes {
                        if byte == 0x0A {
                            try process(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        } else { buffer.append(byte) }
                    }
                    try process(buffer)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error, responseReceived: gotResponse))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Mutations

    public func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try guardMutable(kind)
        let path = (name != nil && subresource != nil) ? kind.itemPath(name: name ?? "", namespace: namespace, subresource: subresource) : kind.collectionPath(namespace: namespace)
        let request = try makeRequest(path: path, query: mutationQuery(options), method: "POST", contentType: "application/json", body: try body.data())
        return try decode(JSONValue.self, from: try await perform(request))
    }

    public func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try guardMutable()
        let request = try makeRequest(path: kind.itemPath(name: name, namespace: namespace), query: mutationQuery(options), method: "PUT", contentType: "application/json", body: try body.data())
        return try decode(JSONValue.self, from: try await perform(request))
    }

    public func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue {
        try guardMutable()
        var isApply = false
        if case .apply = patch { isApply = true }
        let request = try makeRequest(path: kind.itemPath(name: name, namespace: namespace, subresource: subresource),
                                      query: mutationQuery(options, apply: isApply), method: "PATCH",
                                      contentType: patch.contentType, body: try patch.body.data())
        return try decode(JSONValue.self, from: try await perform(request))
    }

    public func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws {
        try guardMutable()
        var body: JSONValue = ["apiVersion": "v1", "kind": "DeleteOptions"]
        if let p = options.propagation { body["propagationPolicy"] = .string(p.rawValue) }
        if let g = options.gracePeriodSeconds { body["gracePeriodSeconds"] = .int(g) }
        // The API server decodes DeleteOptions from the body and ignores the query when a body is present, so the
        // dry-run flag MUST be in the body; the query parameter is kept as well.
        if options.dryRun { body["dryRun"] = ["All"] }
        let q: [(String, String)] = options.dryRun ? [("dryRun", "All")] : []
        _ = try await perform(try makeRequest(path: kind.itemPath(name: name, namespace: namespace), query: q, method: "DELETE", contentType: "application/json", body: try body.data()))
    }

    // MARK: Logs

    public nonisolated func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var gotResponse = false
                do {
                    var q: [(String, String)] = []
                    if let c = options.container { q.append(("container", c)) }
                    if options.follow { q.append(("follow", "true")) }
                    if options.previous { q.append(("previous", "true")) }
                    if options.timestamps { q.append(("timestamps", "true")) }
                    if let t = options.tailLines { q.append(("tailLines", String(t))) }
                    if let t = options.sinceTime { q.append(("sinceTime", t)) } else if let s = options.sinceSeconds { q.append(("sinceSeconds", String(s))) }
                    if let l = options.limitBytes { q.append(("limitBytes", String(l))) }
                    var request = try makeRequest(path: ResourceKind.pod.itemPath(name: pod, namespace: namespace, subresource: "log"), query: q,
                                                  timeout: options.follow ? 3600 : 60)
                    request.setValue("text/plain, */*", forHTTPHeaderField: "Accept")
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw KubeError.decoding("Not an HTTP response") }
                    gotResponse = true
                    hasConnected.withLock { $0 = true }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = Data()
                        for try await b in bytes { body.append(b); if body.count > 8192 { break } }
                        throw httpError(code: http.statusCode, body: body)
                    }
                    var buffer: [UInt8] = []
                    for try await byte in bytes {
                        if byte == 0x0A {
                            continuation.yield(String(decoding: buffer, as: UTF8.self))
                            buffer.removeAll(keepingCapacity: true)
                        } else if byte != 0x0D { buffer.append(byte) }
                    }
                    if !buffer.isEmpty { continuation.yield(String(decoding: buffer, as: UTF8.self)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: mapTransportError(error, responseReceived: gotResponse))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Metrics & proxy

    public func podMetrics(namespace: String?) async throws -> [PodMetrics] {
        try decode(KubeList<PodMetrics>.self, from: try await perform(try makeRequest(path: ResourceKind.podMetrics.collectionPath(namespace: namespace)))).items
    }

    public func nodeMetrics() async throws -> [NodeMetrics] {
        try decode(KubeList<NodeMetrics>.self, from: try await perform(try makeRequest(path: ResourceKind.nodeMetrics.collectionPath()))).items
    }

    public func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let base = "/api/v1/namespaces/\(ResourceKind.escape(namespace))/services/\(ResourceKind.escape(service)):\(ResourceKind.escape(port))/proxy/\(trimmed)"
        return try await perform(try makeRequest(path: base, query: query.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, timeout: 20))
    }

    // MARK: WebSockets

    private nonisolated func webSocket(path: String, query: [(String, String)], protocols: [String]) throws -> KubeWebSocket {
        if config.readOnly && !config.allowExecInReadOnly { throw KubeError.readOnly }
        try guardTransport()
        // Long timeout: the shell or tunnel may sit idle (the socket sends keepalive pings every 30 s).
        var request = URLRequest(url: try makeURL(path: path, query: query, websocket: true), timeoutInterval: 3600)
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.setValue(protocols.joined(separator: ", "), forHTTPHeaderField: "Sec-WebSocket-Protocol")
        let url = request.url
        let delegate = delegate
        return KubeWebSocket(task: session.webSocketTask(with: request), offeredProtocols: protocols, tlsFailure: { delegate.failure(for: url) }, identityFailure: { delegate.identityFailure }, clientCertificateMissing: { delegate.clientCertificateMissing })
    }

    public nonisolated func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket {
        var q: [(String, String)] = options.command.map { ("command", $0) }
        if let c = options.container { q.append(("container", c)) }
        q += [("stdin", options.stdin ? "true" : "false"), ("stdout", "true"), ("stderr", options.tty ? "false" : "true"), ("tty", options.tty ? "true" : "false")]
        return try webSocket(path: ResourceKind.pod.itemPath(name: pod, namespace: namespace, subresource: "exec"), query: q,
                             protocols: ["v5.channel.k8s.io", "v4.channel.k8s.io"])
    }

    public nonisolated func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket {
        try webSocket(path: ResourceKind.pod.itemPath(name: pod, namespace: namespace, subresource: "portforward"),
                      query: ports.map { ("ports", String($0)) }, protocols: ["v4.channel.k8s.io"])
    }
}

extension URLError {
    /// `failingURL` as a string; avoids a Foundation overlay quirk where it is nil for WebSocket upgrades.
    var failureURLString: String? { (userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString ?? (userInfo["NSErrorFailingURLStringKey"] as? String) ?? failingURL?.absoluteString }
}

/// Builds the client-certificate identity once, on first use, serialised and off the caller's critical path.
final class LazyClientIdentity: Sendable {
    private enum State: Sendable { case pending, built(ClientIdentityBuilder.Result), failed(ClientIdentityError) }
    private let state = Mutex(State.pending)
    private let build: @Sendable () throws -> ClientIdentityBuilder.Result

    init(build: @escaping @Sendable () throws -> ClientIdentityBuilder.Result) { self.build = build }

    func resolve() -> (built: ClientIdentityBuilder.Result?, error: ClientIdentityError?) {
        state.withLock { state in
            if case .pending = state {
                do {
                    var built = try build()
                    // Diagnostic only: the identity is presented to the server even if the test signature failed.
                    built.signTestFailure = ClientIdentityBuilder.testSign(built.identity)
                    built.signTestRan = true
                    state = .built(built)
                } catch let e as ClientIdentityError { state = .failed(e) } catch { state = .failed(.identityNotFound) }
            }
            switch state {
            case .built(let r): return (r, nil)
            case .failed(let e): return (nil, e)
            case .pending: return (nil, .identityNotFound)
            }
        }
    }
}
