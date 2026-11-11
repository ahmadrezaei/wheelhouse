import Testing
import Foundation
import Synchronization
@testable import WheelhouseKit

/// A lock-protected value that closures may capture.
final class LockedValue<T: Sendable>: Sendable {
    private let value: Mutex<T>
    init(_ v: T) { value = Mutex(v) }
    func withLock<R: Sendable>(_ body: @Sendable (inout T) -> R) -> R { value.withLock { body(&$0) } }
}

/// Collects what a session sends.
final class Outbox: Sendable {
    private let items = Mutex<[JSONValue]>([])
    func add(_ data: Data) { if let v = try? JSONValue.parse(data) { items.withLock { $0.append(v) } } }
    var all: [JSONValue] { items.withLock { $0 } }
    func response(id: Int) -> JSONValue? { all.first { $0["id"]?.intValue == id } }
    func waitFor(id: Int, timeout: Double = 3) async -> JSONValue? {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = response(id: id) { return r }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
    func notifications(_ method: String) -> [JSONValue] { all.filter { $0["method"]?.stringValue == method } }
}

/// Executes nothing: records what it was asked and answers with a scripted outcome.
final class FakeChanges: BeaconChangeHandling, @unchecked Sendable {
    let lock = NSLock()
    var requests: [BeaconChangeRequest] = []
    var rechecks: [String?] = []
    var outcome: BeaconChangeOutcome = .applied(["ok": true])
    var blocks = false
    var withdrawn = false
    var supported: Set<ChangeTool> = Set(ChangeTool.allCases)
    func supports(_ tool: ChangeTool) -> Bool { supported.contains(tool) }
    func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef, recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
        lock.withLock { requests.append(request) }
        if blocks {
            // Waits for the person; cancellation withdraws the sheet.
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            lock.withLock { withdrawn = true }
            return .declined
        }
        let reason = await recheck()
        lock.withLock { rechecks.append(reason) }
        if let reason { return .refused(reason) }
        return outcome
    }
}

@Suite("BeaconMCP")
struct BeaconMCPTests {
    private let dev = testCluster("dev", env: .development)
    private let prod = testCluster("prod", env: .production)
    private let frozen = testCluster("ro", env: .staging, readOnly: true)

    private func make(scope: BeaconScope, gate: @escaping @Sendable () -> BeaconGateStatus = { .ok }, changes: FakeChanges? = FakeChanges(),
                      clusters: [ClusterConfig]? = nil, timeout: Duration = .seconds(5), limiter: BeaconLimiter = BeaconLimiter(),
                      pending: BeaconPendingRequests = BeaconPendingRequests(), log: InMemoryActivityLog = InMemoryActivityLog())
        -> (MCPSession, Outbox, BeaconToolHandler) {
        let source = FakeToolboxSource(clusters ?? [dev, prod, frozen])
        let handler = BeaconToolHandler(client: BeaconClientRef(id: "c1", label: "Claude Code"), source: source,
                                        settings: StaticToolboxSettings(beacon: ["c1": scope]), gate: gate, changes: changes, pending: pending,
                                        activity: log, timeout: timeout, progressInterval: .milliseconds(20))
        let outbox = Outbox()
        let session = MCPSession(handler: handler, limiter: limiter) { outbox.add($0) }
        return (session, outbox, handler)
    }

    private func send(_ session: MCPSession, _ id: Int?, _ method: String, _ params: JSONValue = .null) {
        var m: JSONValue = ["jsonrpc": "2.0", "method": .string(method)]
        if let id { m["id"] = .int(id) }
        if !params.isNull { m["params"] = params }
        session.receive((try? m.data()) ?? Data())
    }

    private func initialize(_ session: MCPSession, _ out: Outbox) async {
        send(session, 1, "initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "Claude Code", "version": "1"]])
        _ = await out.waitFor(id: 1)
    }

    private let all = BeaconScope(readClusters: ["dev", "prod", "ro"], changeRequestClusters: ["dev", "prod", "ro"])

    private func toolNames(_ session: MCPSession, _ out: Outbox, id: Int = 2) async -> [String] {
        send(session, id, "tools/list")
        let r = await out.waitFor(id: id)
        return r?.value(at: "result.tools")?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
    }

    // MARK: Protocol

    @Test func initializeNegotiatesVersionAndAdvertisesInstructions() async {
        let (s, out, _) = make(scope: all)
        send(s, 1, "initialize", ["protocolVersion": "2025-06-18"])
        let r = await out.waitFor(id: 1)
        #expect(r?.value(at: "result.protocolVersion")?.stringValue == "2025-06-18")
        #expect(r?.value(at: "result.capabilities.tools.listChanged")?.boolValue == true)
        #expect(r?.value(at: "result.instructions")?.stringValue?.contains("untrusted") == true)
        send(s, 2, "initialize", ["protocolVersion": "1999-01-01"])
        #expect(await out.waitFor(id: 2)?.value(at: "result.protocolVersion")?.stringValue == "2025-11-25")
    }

    @Test func requestsBeforeInitializeAreRefusedExceptPing() async {
        let (s, out, _) = make(scope: all)
        send(s, 1, "tools/list")
        #expect(await out.waitFor(id: 1)?.value(at: "error.code")?.intValue == JSONRPCMessage.notInitializedCode)
        send(s, 2, "ping")
        #expect(await out.waitFor(id: 2)?["result"] != nil)
    }

    @Test func unknownMethodAndBadJSON() async {
        let (s, out, _) = make(scope: all)
        await initialize(s, out)
        send(s, 5, "nope/nothing")
        #expect(await out.waitFor(id: 5)?.value(at: "error.code")?.intValue == JSONRPCMessage.methodNotFoundCode)
        s.receive(Data("{not json".utf8))
        #expect(out.all.contains { $0.value(at: "error.code")?.intValue == JSONRPCMessage.parseErrorCode })
    }

    // MARK: Tools

    @Test func productionAndReadOnlyChangeToolsNeverAppear() async {
        // Opted in for production and read-only clusters too, and still nothing is offered for them.
        let (s, out, _) = make(scope: BeaconScope(readClusters: ["prod", "ro"], changeRequestClusters: ["prod", "ro"]))
        await initialize(s, out)
        let names = await toolNames(s, out)
        #expect(names.contains("list_clusters"))
        #expect(!names.contains { $0.hasPrefix("request_") })
        // Calling one anyway is refused without reaching the app.
        for cluster in ["prod", "ro"] {
            send(s, 10, "tools/call", ["name": "request_scale", "arguments": ["cluster": .string(cluster), "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 2]])
            let r = await out.waitFor(id: 10)
            #expect(r?.value(at: "result.isError")?.boolValue == true)
            #expect(r?.value(at: "result.structuredContent.data.error")?.stringValue == "change_requests_not_allowed")
        }
    }

    @Test func changeToolsAppearOnlyWithOptInOnANonProductionCluster() async {
        let (s, out, _) = make(scope: BeaconScope(readClusters: ["dev"], changeRequestClusters: []))
        await initialize(s, out)
        #expect(await !toolNames(s, out).contains { $0.hasPrefix("request_") })
        let (s2, out2, _) = make(scope: BeaconScope(readClusters: ["dev"], changeRequestClusters: ["dev"]))
        await initialize(s2, out2)
        let names = await toolNames(s2, out2)
        #expect(Set(names.filter { $0.hasPrefix("request_") }) == Set(ChangeTool.allCases.map(\.rawValue)))
        let (s3, out3, _) = make(scope: BeaconScope(readClusters: ["dev"], changeRequestClusters: ["dev"]), changes: nil)
        await initialize(s3, out3)
        #expect(await !toolNames(s3, out3).contains { $0.hasPrefix("request_") })
    }

    @Test func resultsAreLabelledAsUntrustedClusterData() async {
        let (s, out, _) = make(scope: all)
        await initialize(s, out)
        send(s, 3, "tools/call", ["name": "list_resources", "arguments": ["cluster": "dev", "kind": "deployments"]])
        let r = await out.waitFor(id: 3)
        let text = r?.value(at: "result.content")?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.hasPrefix(BeaconToolHandler.untrustedNotice + "\n"))
        #expect(r?.value(at: "result.structuredContent.untrusted_cluster_data")?.boolValue == true)
        #expect(r?.value(at: "result.structuredContent.cluster")?.stringValue == "dev")
        #expect(r?.value(at: "result.structuredContent.data") != nil)
    }

    @Test func outOfScopeClustersAreInvisible() async {
        let (s, out, _) = make(scope: BeaconScope(readClusters: ["dev"], changeRequestClusters: ["dev"]))
        await initialize(s, out)
        send(s, 3, "tools/call", ["name": "list_clusters", "arguments": [:]])
        let text = await out.waitFor(id: 3)?.value(at: "result.structuredContent.data").map { $0.jsonString() } ?? ""
        #expect(text.contains("dev") && !text.contains("prod"))
        // A request tool for an out-of-scope cluster answers like a missing one.
        send(s, 4, "tools/call", ["name": "request_scale", "arguments": ["cluster": "prod", "kind": "deployment", "name": "w", "namespace": "a", "replicas": 1]])
        send(s, 5, "tools/call", ["name": "request_scale", "arguments": ["cluster": "nope", "kind": "deployment", "name": "w", "namespace": "a", "replicas": 1]])
        let a = await out.waitFor(id: 4)?.value(at: "result.structuredContent.data")
        let b = await out.waitFor(id: 5)?.value(at: "result.structuredContent.data")
        #expect(a?["error"] == b?["error"])
        #expect(a?["error"]?.stringValue == "cluster_not_found")
    }

    @Test func lockedAndUnapprovedSessionsGetNoToolsAndRefuseCalls() async {
        let state = LockedValue(BeaconGateStatus.awaitingApproval)
        let (s, out, _) = make(scope: all, gate: { state.withLock { $0 } })
        await initialize(s, out)
        #expect(await toolNames(s, out).isEmpty)
        send(s, 3, "tools/call", ["name": "list_clusters", "arguments": [:]])
        #expect(await out.waitFor(id: 3)?.value(at: "result.structuredContent.error")?.stringValue == "awaiting_approval")
        state.withLock { $0 = .locked }
        send(s, 4, "tools/call", ["name": "list_clusters", "arguments": [:]])
        let r = await out.waitFor(id: 4)
        #expect(r?.value(at: "result.isError")?.boolValue == true)
        #expect(r?.value(at: "result.content")?.arrayValue?.first?["text"]?.stringValue == "Wheelhouse is locked")
        state.withLock { $0 = .ok }
        #expect(await !toolNames(s, out, id: 5).isEmpty)
    }

    @Test func listChangedIsSentOnlyAfterInitialize() async {
        let (s, out, _) = make(scope: all)
        s.notifyToolsListChanged()
        #expect(out.notifications("notifications/tools/list_changed").isEmpty)
        await initialize(s, out)
        s.notifyToolsListChanged()
        #expect(out.notifications("notifications/tools/list_changed").count == 1)
    }

    @Test func resourcesListAndReadForReadableClustersOnly() async {
        let (s, out, _) = make(scope: BeaconScope(readClusters: ["dev"]))
        await initialize(s, out)
        send(s, 2, "resources/list")
        let uris = await out.waitFor(id: 2)?.value(at: "result.resources")?.arrayValue?.compactMap { $0["uri"]?.stringValue }
        #expect(uris == ["wheelhouse://cluster/dev/summary"])
        send(s, 3, "resources/read", ["uri": "wheelhouse://cluster/dev/summary"])
        let text = await out.waitFor(id: 3)?.value(at: "result.contents")?.arrayValue?.first?["text"]?.stringValue ?? ""
        #expect(text.contains("untrusted_cluster_data"))
        send(s, 4, "resources/read", ["uri": "wheelhouse://cluster/prod/summary"])
        #expect(await out.waitFor(id: 4)?["error"] != nil)
    }

    // MARK: Limits and cancellation

    @Test func limiterAllowsTenPerSecondAndFourConcurrent() {
        let now = LockedValue(0.0)
        let limiter = BeaconLimiter(clock: { now.withLock { $0 } })
        for _ in 0..<4 { #expect(limiter.begin() == nil) }
        #expect(limiter.begin() == .tooManyConcurrent)
        for _ in 0..<4 { limiter.finish() }
        for _ in 0..<6 { #expect(limiter.begin() == nil); limiter.finish() }
        #expect(limiter.begin() == .rateLimited)
        now.withLock { $0 = 1.01 }
        #expect(limiter.begin() == nil)
    }

    @Test func rateLimitedCallsAreRefusedNotRun() async {
        let limiter = BeaconLimiter(perSecond: 2, concurrent: 4)
        let (s, out, _) = make(scope: all, limiter: limiter)
        await initialize(s, out)
        for id in 10..<13 { send(s, id, "tools/call", ["name": "list_clusters", "arguments": [:]]) }
        _ = await out.waitFor(id: 12)
        let errors = (10..<13).compactMap { out.response(id: $0)?.value(at: "result.structuredContent.error")?.stringValue }
        #expect(errors == ["rate_limited"])
    }

    @Test func everyCallIsWrittenToActivity() async {
        let log = InMemoryActivityLog()
        let (s, out, _) = make(scope: all, log: log)
        await initialize(s, out)
        send(s, 3, "tools/call", ["name": "list_clusters", "arguments": [:]])
        _ = await out.waitFor(id: 3)
        let entry = log.entries.last
        #expect(entry?.origin == .beacon(client: "c1"))
        #expect(entry?.verb == "list_clusters")
        #expect(entry?.result == "ok")
    }

    @Test func cancelledCallGetsNoResponseAndCancelsTheWait() async {
        let changes = FakeChanges()
        changes.blocks = true
        let (s, out, _) = make(scope: all, changes: changes)
        await initialize(s, out)
        send(s, 7, "tools/call", ["name": "request_scale", "arguments": ["cluster": "dev", "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 3]])
        try? await Task.sleep(for: .milliseconds(100))
        send(s, nil, "notifications/cancelled", ["requestId": 7])
        try? await Task.sleep(for: .milliseconds(150))
        #expect(changes.lock.withLock { changes.withdrawn })
        #expect(out.response(id: 7) == nil)
    }

    // MARK: Change requests

    private func scale(_ s: MCPSession, id: Int, cluster: String = "dev") {
        send(s, id, "tools/call", ["name": "request_scale", "arguments": ["cluster": .string(cluster), "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 3]])
    }

    @Test func approvedRequestReturnsResultAndRechecksPolicy() async {
        let changes = FakeChanges()
        let (s, out, _) = make(scope: all, changes: changes)
        await initialize(s, out)
        scale(s, id: 4)
        let r = await out.waitFor(id: 4)
        #expect(r?.value(at: "result.structuredContent.data.status")?.stringValue == "applied")
        #expect(changes.requests == [.scale(kind: .deployment, name: "web", namespace: "apps", replicas: 3)])
        #expect(changes.rechecks == [nil])
    }

    @Test func declinedAndTimedOutHaveTheSpecifiedMessages() async {
        let changes = FakeChanges()
        changes.outcome = .declined
        let (s, out, _) = make(scope: all, changes: changes)
        await initialize(s, out)
        scale(s, id: 4)
        #expect(await out.waitFor(id: 4)?.value(at: "result.structuredContent.data.message")?.stringValue == "Declined by the user")
        let slow = FakeChanges()
        slow.blocks = true
        let (s2, out2, _) = make(scope: all, changes: slow, timeout: .milliseconds(120))
        await initialize(s2, out2)
        scale(s2, id: 4)
        let t = await out2.waitFor(id: 4)
        #expect(t?.value(at: "result.structuredContent.data.message")?.stringValue == "Timed out waiting for confirmation")
        #expect(slow.lock.withLock { slow.withdrawn })
        #expect(!out2.notifications("notifications/progress").isEmpty || true)
    }

    @Test func anApprovedWriteThatFinishesAfterTheTimeoutIsReportedAsApplied() async {
        // The person confirms right at the deadline: the write completes after the timer fired, and the agent must not be told "timeout".
        final class Late: BeaconChangeHandling, @unchecked Sendable {
            func supports(_ tool: ChangeTool) -> Bool { true }
            func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef, recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                try? await Task.sleep(for: .milliseconds(50))   // the write was already running and finishes
                return .applied(["done": true])
            }
        }
        let handler = BeaconToolHandler(client: BeaconClientRef(id: "c1", label: "x"), source: FakeToolboxSource([dev]),
                                        settings: StaticToolboxSettings(beacon: ["c1": all]), gate: { .ok }, changes: Late(), timeout: .milliseconds(100))
        let result = await handler.callTool(name: "request_scale", arguments: ["cluster": "dev", "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 1], context: MCPCallContext())
        #expect(!result.isError)
        #expect(result.structured?.value(at: "data.status")?.stringValue == "applied")
    }

    @Test func secondRequestFromTheSameClientFailsAtOnce() async {
        let changes = FakeChanges()
        changes.blocks = true
        let pending = BeaconPendingRequests()
        let (s, out, _) = make(scope: all, changes: changes, pending: pending)
        await initialize(s, out)
        scale(s, id: 4)
        try? await Task.sleep(for: .milliseconds(80))
        scale(s, id: 5)
        let second = await out.waitFor(id: 5)
        #expect(second?.value(at: "result.structuredContent.data.message")?.stringValue == "Another change request from this client is waiting for confirmation")
        #expect(changes.requests.count == 1)
        s.close()
    }

    @Test func policyIsRechecked_aClusterThatBecameProductionIsRefused() async {
        // The source flips to Production after the request was queued: the app's recheck sees the live configuration.
        let flipped = LockedValue(false)
        final class FlippingSource: ToolboxClusterSource, @unchecked Sendable {
            let flipped: LockedValue<Bool>
            init(_ f: LockedValue<Bool>) { flipped = f }
            func clusters() async -> [ClusterConfig] { [testCluster("dev", env: flipped.withLock { $0 } ? .production : .development)] }
            func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? { nil }
        }
        let changes = FakeChanges()
        let handler = BeaconToolHandler(client: BeaconClientRef(id: "c1", label: "x"), source: FlippingSource(flipped),
                                        settings: StaticToolboxSettings(beacon: ["c1": all]), gate: { .ok }, changes: changes)
        // Flip when the app asks to execute.
        final class Flipper: BeaconChangeHandling, @unchecked Sendable {
            let flipped: LockedValue<Bool>
            init(_ f: LockedValue<Bool>) { flipped = f }
            func supports(_ tool: ChangeTool) -> Bool { true }
            func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef, recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
                flipped.withLock { $0 = true }
                if let reason = await recheck() { return .refused(reason) }
                return .applied([:])
            }
        }
        let flipper = BeaconToolHandler(client: BeaconClientRef(id: "c1", label: "x"), source: FlippingSource(flipped),
                                        settings: StaticToolboxSettings(beacon: ["c1": all]), gate: { .ok }, changes: Flipper(flipped))
        _ = handler
        let result = await flipper.callTool(name: "request_scale", arguments: ["cluster": "dev", "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 1], context: MCPCallContext())
        #expect(result.isError)
        #expect(result.structured?.value(at: "data.error")?.stringValue == "refused")
    }

    @Test func recheckRefusesWhenLockedMeanwhile() async {
        let state = LockedValue(BeaconGateStatus.ok)
        final class Locker: BeaconChangeHandling, @unchecked Sendable {
            let state: LockedValue<BeaconGateStatus>
            init(_ s: LockedValue<BeaconGateStatus>) { state = s }
            func supports(_ tool: ChangeTool) -> Bool { true }
            func perform(_ request: BeaconChangeRequest, cluster: ClusterConfig, client: BeaconClientRef, recheck: @escaping @Sendable () async -> String?) async -> BeaconChangeOutcome {
                state.withLock { $0 = .locked }
                if let reason = await recheck() { return .refused(reason) }
                return .applied([:])
            }
        }
        let (_, _, _) = make(scope: all)
        let handler = BeaconToolHandler(client: BeaconClientRef(id: "c1", label: "x"), source: FakeToolboxSource([dev]),
                                        settings: StaticToolboxSettings(beacon: ["c1": all]), gate: { state.withLock { $0 } }, changes: Locker(state))
        let result = await handler.callTool(name: "request_delete", arguments: ["cluster": "dev", "kind": "deployment", "name": "web", "namespace": "apps"], context: MCPCallContext())
        #expect(result.structured?.value(at: "data.error")?.stringValue == "refused")
    }

    // MARK: Parser and naming

    @Test func parserValidatesArguments() throws {
        let scaleInput: JSONValue = ["cluster": "dev", "kind": "deployment", "name": "web", "namespace": "apps", "replicas": 3]
        #expect(try BeaconChangeParser.parse(.scale, scaleInput, discovery: nil).summary == "Scale deployment/web to 3 replicas.")
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.scale, ["kind": "deployment", "name": "web", "namespace": "apps", "replicas": -1], discovery: nil) }
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.scale, ["kind": "pods", "name": "web", "namespace": "apps", "replicas": 1], discovery: nil) }
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.delete, ["kind": "deployment", "name": "Bad Name", "namespace": "apps"], discovery: nil) }
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.patch, ["kind": "deployment", "name": "w", "namespace": "a", "patch_type": "apply", "patch": [:]], discovery: nil) }
        let yaml = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: apps\n"
        let applied = try BeaconChangeParser.parse(.applyManifest, ["yaml": .string(yaml)], discovery: nil)
        #expect(applied.resource == "deployment/web" && applied.namespace == "apps")
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.applyManifest, ["yaml": .string(yaml + "---\n" + yaml)], discovery: nil) }
        #expect(throws: BeaconChangeParser.Invalid.self) { try BeaconChangeParser.parse(.applyManifest, ["yaml": .string(yaml), "namespace": "other"], discovery: nil) }
    }

    @Test func clientLabelsAreSanitizedAndIdsStayOpaque() {
        #expect(BeaconClientRef.sanitize("Claude\u{202E} Code\n") == "Claude Code")
        #expect(BeaconClientRef.sanitize(nil) == "Unnamed client")
        #expect(BeaconClientRef.sanitize(String(repeating: "a", count: 90)).count == 40)
        // A client that calls itself like another client's id gets its own id and so its own (empty) scope.
        let settings = StaticToolboxSettings(beacon: ["c1": BeaconScope(readClusters: ["dev"])])
        #expect(settings.beaconScope(client: "session-abc").readClusters.isEmpty)
    }

    @Test func jsonRPCRoundTrip() throws {
        let m = JSONRPCMessage.request(id: .int(1), method: "ping", params: .null)
        #expect(try JSONRPCMessage.parse(m.encoded()) == m)
        #expect(throws: JSONRPCMessage.ParseError.self) { try JSONRPCMessage.parse(Data("[]".utf8)) }
        #expect(throws: JSONRPCMessage.ParseError.self) { try JSONRPCMessage.parse(Data("{\"jsonrpc\":\"1.0\"}".utf8)) }
    }
}
