import Testing
import Foundation
@testable import WheelhouseKit

@Suite("ClusterToolbox")
@MainActor
struct ClusterToolboxTests {
    private func demoToolbox(caller: ToolboxCaller = .firstMate(conversation: "c1")) -> ClusterToolbox {
        let registry = ClusterRegistry.preview()
        var settings = StaticToolboxSettings()
        for c in registry.clusters { settings.firstMate[c.id] = .allowed }
        return ClusterToolbox(source: RegistryToolboxSource(registry: registry), policy: ToolboxPolicy(caller: caller, settings: settings))
    }

    @Test func listClustersOverTheDemoFleet() async {
        let out = await demoToolbox().call(.listClusters, input: [:])
        let names = out.json["clusters"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.sorted() == ["edge-oslo", "homelab-k3s", "prod-eu-west", "staging"])
        #expect(!out.isError)
    }

    @Test func listResourcesReturnsCompactRows() async throws {
        let out = await demoToolbox().call(.listResources, input: ["cluster": .string(DemoFleet.stagingID), "kind": "pods", "limit": 20])
        #expect(!out.isError, "\(out.text)")
        let items = try #require(out.json["items"]?.arrayValue)
        #expect(!items.isEmpty && items.count <= 20)
        #expect(items.allSatisfy { $0["name"]?.stringValue?.isEmpty == false })
        #expect(items.contains { $0["status"]?.stringValue != nil })
    }

    @Test func secretsListNamesAndKeyCountsOnly() async throws {
        let out = await demoToolbox().call(.listResources, input: ["cluster": .string(DemoFleet.stagingID), "kind": "secrets"])
        let items = try #require(out.json["items"]?.arrayValue)
        #expect(!items.isEmpty)
        for item in items {
            #expect(item["key_count"] != nil)
            #expect(item["data"] == nil)
        }
    }

    @Test func getResourceOnASecretReturnsTypeKeysAndSizesNeverValues() async throws {
        let toolbox = demoToolbox()
        let list = await toolbox.call(.listResources, input: ["cluster": .string(DemoFleet.stagingID), "kind": "secrets"])
        let first = try #require(list.json["items"]?.arrayValue?.first)
        let name = try #require(first["name"]?.stringValue)
        let ns = try #require(first["namespace"]?.stringValue)
        let out = await toolbox.call(.getResource, input: ["cluster": .string(DemoFleet.stagingID), "kind": "Secret", "name": .string(name), "namespace": .string(ns)])
        #expect(!out.isError, "\(out.text)")
        let object = try #require(out.json["object"])
        #expect(object["keys"]?.arrayValue?.isEmpty == false)
        #expect(object["sizes"]?.objectValue?.isEmpty == false)
        #expect(object["data"] == nil && object["stringData"] == nil)
    }

    @Test func getResourceValidatesNames() async {
        let out = await demoToolbox().call(.getResource, input: ["cluster": .string(DemoFleet.stagingID), "kind": "pods", "name": "../etc", "namespace": "apps"])
        #expect(out.json["error"]?.stringValue == "invalid_input")
        let missingKind = await demoToolbox().call(.getResource, input: ["cluster": .string(DemoFleet.stagingID), "kind": "nonsense", "name": "x", "namespace": "apps"])
        #expect(missingKind.json["error"]?.stringValue == "invalid_input")
    }

    @Test func logsAreRedactedAndCappedToTheTail() async throws {
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(logs: { _, _, options in
                #expect(options.tailLines == 3)
                #expect(!options.follow)
                return AsyncThrowingStream {
                    $0.yield("one\ntwo\n")
                    $0.yield("login password=hunter2 ok\nBearer abcdefghijklmnopqrstuvwxyz0123456789\n")
                    $0.finish()
                }
            })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.getLogs, input: ["cluster": "dev", "namespace": "apps", "pod": "web-1", "tail_lines": 3])
        let lines = try #require(out.json["lines"]?.arrayValue?.compactMap { $0.stringValue })
        #expect(lines.count == 3)
        #expect(lines.first == "two")
        #expect(!out.text.contains("hunter2"))
        #expect(!out.text.contains("abcdefghijklmnopqrstuvwxyz0123456789"))
    }

    @Test func logsAtMost2000Lines() async {
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(logs: { _, _, _ in AsyncThrowingStream { c in (0..<5000).forEach { c.yield("line \($0)\n") }; c.finish() } })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.getLogs, input: ["cluster": "dev", "namespace": "apps", "pod": "p", "tail_lines": 5000])
        // The schema allows 2,000; the toolbox clamps anyway, and the 48 KB cap may shorten further.
        #expect((out.json["line_count"]?.intValue ?? 0) <= 2000)
        #expect(out.text.utf8.count <= ToolResultLimiter.maxBytes)
    }

    @Test func resultsOverTheCapAreTruncatedExplicitly() async throws {
        let big = (0..<400).map { i -> JSONValue in
            ["metadata": ["name": .string("deployment-with-a-rather-long-name-\(i)-\(String(repeating: "x", count: 100))"), "namespace": "apps"], "status": ["phase": "Running"]]
        }
        let source = FakeToolboxSource([testCluster("dev")]) { _ in ReadOnlyKubeAccess(listRaw: { _, _, _ in ["items": .array(big)] }) }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.listResources, input: ["cluster": "dev", "kind": "pods", "limit": 500])
        #expect(out.text.utf8.count <= ToolResultLimiter.maxBytes)
        #expect(out.json["truncated"]?.boolValue == true)
        let omitted = try #require(out.json["omitted"]?.intValue)
        #expect(omitted > 0)
        #expect((out.json["items"]?.arrayValue?.count ?? 0) + omitted == 400)
    }

    @Test func limiterKeepsTheTailOfLogsAndTheHeadOfLists() {
        let value: JSONValue = ["lines": .array((0..<2000).map { .string("log line number \($0) with some padding text") }), "items": .array((0..<10).map { .int($0) })]
        let out = ToolResultLimiter.limit(value, maxBytes: 8_000)
        #expect(out.jsonString().utf8.count <= 8_000)
        #expect(out["truncated"]?.boolValue == true)
        #expect(out["lines"]?.arrayValue?.last?.stringValue == "log line number 1999 with some padding text")
        #expect(out["items"]?.arrayValue?.first?.intValue == 0)
    }

    @Test func limiterLeavesSmallResultsAlone() {
        let value: JSONValue = ["items": [1, 2, 3]]
        #expect(ToolResultLimiter.limit(value) == value)
    }

    @Test func eventsAreSortedNewestFirstAndRedacted() async throws {
        let events: [JSONValue] = [
            ["type": "Warning", "reason": "Failed", "message": "pull failed for https://u:pw@reg.example.com", "lastTimestamp": "2026-11-07T10:00:00Z", "involvedObject": ["kind": "Pod", "name": "a"], "metadata": ["namespace": "apps"]],
            ["type": "Normal", "reason": "Started", "message": "ok", "lastTimestamp": "2026-11-07T11:00:00Z", "involvedObject": ["kind": "Pod", "name": "b"], "metadata": ["namespace": "apps"]],
        ]
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(listRaw: { kind, _, options in
                #expect(kind == .event)
                #expect(options.fieldSelector == "involvedObject.name=a")
                return ["items": .array(events)]
            })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.getEvents, input: ["cluster": "dev", "object_name": "a"])
        let rows = try #require(out.json["events"]?.arrayValue)
        #expect(rows.first?["reason"]?.stringValue == "Started")
        #expect(!out.text.contains("u:pw@"))
    }

    @Test func metricsFromTheDemoCluster() async {
        let out = await demoToolbox().call(.getMetrics, input: ["cluster": .string(DemoFleet.stagingID), "scope": "nodes"])
        #expect(!out.isError, "\(out.text)")
        #expect(out.json["items"]?.arrayValue?.isEmpty == false)
    }

    @Test func ownerChainWalksUp() async throws {
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(
                discovery: { DiscoveryInfo(resources: []) },
                getRaw: { kind, name, _ in
                    switch kind {
                    case .pod: ["metadata": ["name": .string(name), "uid": "u1", "ownerReferences": [["apiVersion": "apps/v1", "kind": "ReplicaSet", "name": "web-abc", "controller": true]]]]
                    case .replicaSet: ["metadata": ["name": .string(name), "uid": "u2", "ownerReferences": [["apiVersion": "apps/v1", "kind": "Deployment", "name": "web", "controller": true]]]]
                    default: ["metadata": ["name": .string(name), "uid": "u3"]]
                    }
                })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.describeOwnerChain, input: ["cluster": "dev", "kind": "pod", "name": "web-abc-1", "namespace": "apps"])
        let chain = try #require(out.json["chain"]?.arrayValue?.compactMap { $0["kind"]?.stringValue })
        #expect(chain == ["Pod", "ReplicaSet", "Deployment"])
    }

    @Test func canIAsksAReviewAndNothingElse() async {
        let seen = Seen()
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(canI: { q in seen.record(q); return q.verb == "get" })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let yes = await toolbox.call(.rbacCanI, input: ["cluster": "dev", "verb": "get", "resource": "pods", "namespace": "apps"])
        let no = await toolbox.call(.rbacCanI, input: ["cluster": "dev", "verb": "delete", "resource": "pods"])
        #expect(yes.json["allowed"]?.boolValue == true)
        #expect(no.json["allowed"]?.boolValue == false)
        #expect(seen.count == 2)
        let bad = await toolbox.call(.rbacCanI, input: ["cluster": "dev", "verb": "get; rm", "resource": "pods"])
        #expect(bad.json["error"]?.stringValue == "invalid_input")
    }

    @Test func stubbedToolsSayUnavailableAfterThePermissionGate() async {
        let toolbox = demoToolbox()
        for tool in [ReadTool.helmRelease, .gitopsStatus, .surveyFindings, .explainField] {
            let out = await toolbox.call(tool, input: sampleInput(tool, cluster: DemoFleet.stagingID))
            #expect(out.json["error"]?.stringValue == "unavailable", "\(tool)")
        }
    }

    @Test func helmToolNamesDifferBetweenFirstMateAndBeacon() async {
        let firstMate = demoToolbox().tools.map(\.name)
        #expect(firstMate.contains("helm_release") && !firstMate.contains("helm_list_releases"))
        let beacon = demoToolbox(caller: .beacon(client: "c")).tools.map(\.name)
        #expect(beacon.contains("helm_list_releases") && beacon.contains("helm_get_release") && !beacon.contains("helm_release"))
        let unknown = await demoToolbox().call(named: "helm_list_releases", input: ["cluster": .string(DemoFleet.stagingID)])
        #expect(unknown.json["error"]?.stringValue == "unknown_tool")
    }

    @Test func unknownAndInvalidInput() async {
        let toolbox = demoToolbox()
        #expect(await toolbox.call(named: "delete_everything", input: [:]).json["error"]?.stringValue == "unknown_tool")
        #expect(await toolbox.call(named: "get_resource", input: [:]).json["error"]?.stringValue == "invalid_input")
    }

    @Test func clusterCanBeAddressedByName() async {
        let out = await demoToolbox().call(.listResources, input: ["cluster": "Staging", "kind": "pods", "limit": 1])
        #expect(!out.isError, "\(out.text)")
    }

    @Test func searchRanksExactBeforePrefixBeforeSubstring() async throws {
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(listRaw: { kind, _, _ in
                kind == .deployment ? ["items": [["metadata": ["name": "my-web-app", "namespace": "a"]], ["metadata": ["name": "webhook", "namespace": "a"]], ["metadata": ["name": "web", "namespace": "a"]]]] : ["items": []]
            })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.search, input: ["query": "web"])
        let names = try #require(out.json["items"]?.arrayValue?.compactMap { $0["name"]?.stringValue })
        #expect(names == ["web", "webhook", "my-web-app"])
    }

    @Test func searchNeverReadsSecrets() async {
        let kinds = Seen()
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(listRaw: { kind, _, _ in kinds.record(kind.kind); return ["items": []] })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        _ = await toolbox.call(.search, input: ["query": "db", "kinds": ["secrets", "deployments"]])
        #expect(kinds.values == ["Deployment"])
        let onlySecrets = await toolbox.call(.search, input: ["query": "db", "kinds": ["secrets"]])
        #expect(onlySecrets.json["error"]?.stringValue == "invalid_input")
    }

    @Test func kubeErrorsBecomeToolErrors() async {
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(listRaw: { _, _, _ in throw KubeError.forbidden(verb: nil, resource: nil, namespace: nil, message: "pods is forbidden") })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.listResources, input: ["cluster": "dev", "kind": "pods"])
        #expect(out.isError)
        #expect(out.json["error"]?.stringValue == "kube_error")
    }

    @Test func aLogTailThatStartsInsideAPEMBlockDoesNotLeakTheKeyBody() async {
        let full = ["before", "-----BEGIN RSA PRIVATE KEY-----", "MIIEowIBAAKCAQEAbody1", "QWERTYbody2", "ZXCVBNbody3", "-----END RSA PRIVATE KEY-----", "after"]
        // Every possible cut of the log: the server returns only the last n lines.
        for n in 1...full.count {
            let tail = Array(full.suffix(n))
            let source = FakeToolboxSource([testCluster("dev")]) { _ in
                ReadOnlyKubeAccess(logs: { _, _, _ in AsyncThrowingStream { c in c.yield(tail.joined(separator: "\n") + "\n"); c.finish() } })
            }
            let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
            let out = await toolbox.call(.getLogs, input: ["cluster": "dev", "namespace": "apps", "pod": "p"])
            for body in ["MIIEowIBAAKCAQEAbody1", "QWERTYbody2", "ZXCVBNbody3"] { #expect(!out.text.contains(body), "tail \(n) leaked \(body)") }
        }
    }

    @Test func anOwnerNameThatIsNotAPlainNameStopsTheWalk() async throws {
        let seen = Seen()
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(
                discovery: { DiscoveryInfo(resources: []) },
                getRaw: { kind, name, _ in
                    seen.record("\(kind.kind)/\(name)")
                    return ["metadata": ["name": .string(name), "uid": "u1", "ownerReferences": [["apiVersion": "v1", "kind": "Service", "name": "svc/proxy/admin", "controller": true]]]]
                })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.describeOwnerChain, input: ["cluster": "dev", "kind": "pod", "name": "p", "namespace": "apps"])
        #expect(seen.values == ["Pod/p"])
        let notes = out.json["chain"]?.arrayValue?.compactMap { $0["note"]?.stringValue } ?? []
        #expect(notes == ["invalid owner name"])
    }

    @Test func discoveredKindsWithUnsafePathPartsAreNotResolved() {
        let evilJSON: JSONValue = ["name": "x/proxy", "namespaced": true, "kind": "Evil", "verbs": ["list"], "group": "a.io", "version": "v1"]
        let evil = try! evilJSON.decode(APIResource.self)
        let fineJSON: JSONValue = ["name": "widgets", "namespaced": true, "kind": "Widget", "verbs": ["list"], "group": "a.io", "version": "v1"]
        let fine = try! fineJSON.decode(APIResource.self)
        let discovery = DiscoveryInfo(resources: [evil, fine])
        #expect(KindResolver.resolve("Evil", discovery: discovery) == nil)
        #expect(KindResolver.resolve(apiVersion: "a.io/v1", kind: "Evil", discovery: discovery) == nil)
        #expect(KindResolver.resolve("widget", discovery: discovery)?.plural == "widgets")
    }

    @Test func anEightyKilobyteConfigMapIsTruncatedNotRefused() async throws {
        let data: JSONValue = ["blob": .string(String(repeating: "x", count: 80_000)), "small": "keep me"]
        let source = FakeToolboxSource([testCluster("dev")]) { _ in
            ReadOnlyKubeAccess(getRaw: { _, name, _ in ["kind": "ConfigMap", "metadata": ["name": .string(name), "namespace": "apps"], "data": data] })
        }
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await toolbox.call(.getResource, input: ["cluster": "dev", "kind": "configmap", "name": "big", "namespace": "apps"])
        #expect(out.json["error"] == nil, "\(out.text.prefix(200))")
        #expect(out.text.utf8.count <= ToolResultLimiter.maxBytes)
        #expect(out.json["truncated"]?.boolValue == true)
        #expect((out.json["omitted_chars"]?.intValue ?? 0) > 20_000)
        #expect(out.json["omitted"]?.intValue == 0)
        #expect(out.json.value(at: "object.data.small")?.stringValue == "keep me")
    }

    @Test func limiterCountsItemsAndCharactersSeparately() {
        let value: JSONValue = ["items": .array((0..<100).map { _ in .object(["text": .string(String(repeating: "y", count: 300))]) })]
        let out = ToolResultLimiter.limit(value, maxBytes: 4_000)
        #expect(out.jsonString().utf8.count <= 4_000)
        #expect((out["omitted"]?.intValue ?? 0) > 0)
        let nested: JSONValue = ["a": ["b": ["c": .string(String(repeating: "z", count: 50_000))]]]
        let cut = ToolResultLimiter.limit(nested, maxBytes: 2_000)
        #expect(cut["truncated"]?.boolValue == true && (cut["omitted_chars"]?.intValue ?? 0) > 0)
    }

    @Test func aProviderPlugsInAfterThePermissionGate() async {
        struct HelmProvider: ToolboxExtensionProviding {
            var tools: Set<ReadTool> { [.helmRelease] }
            func call(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue, redactor: Redactor) async throws -> JSONValue {
                ["release": "web", "values": redactor.values(["adminPassword": "hunter2", "replicas": 2])]
            }
        }
        let source = FakeToolboxSource([testCluster("dev"), testCluster("prod", env: .production)])
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")), extensions: [HelmProvider()])
        let ok = await toolbox.call(.helmRelease, input: sampleInput(.helmRelease, cluster: "dev"))
        #expect(ok.json["release"]?.stringValue == "web")
        #expect(!ok.text.contains("hunter2"))
        let gated = await toolbox.call(.helmRelease, input: sampleInput(.helmRelease, cluster: "prod"))
        #expect(gated.json["error"]?.stringValue == "permission_required")
        let other = await toolbox.call(.gitopsStatus, input: sampleInput(.gitopsStatus, cluster: "dev"))
        #expect(other.json["error"]?.stringValue == "unavailable")
    }

    @Test(arguments: [(200, 400), (50, 20_000), (2_000, 400)])
    func wideConfigMapsAreTruncatedQuicklyAndWithinTheCap(keys: Int, length: Int) throws {
        var data: [String: JSONValue] = [:]
        for i in 0..<keys { data["key-\(String(format: "%04d", i))"] = .string(String(repeating: "v", count: length)) }
        let value: JSONValue = ["cluster": "dev", "object": ["kind": "ConfigMap", "data": .object(data)]]
        let started = ContinuousClock.now
        let out = ToolResultLimiter.limit(value)
        let elapsed = ContinuousClock.now - started
        #expect(out["error"] == nil, "\(out.jsonString().prefix(120))")
        #expect(out["truncated"]?.boolValue == true)
        #expect(out.jsonString().utf8.count <= ToolResultLimiter.maxBytes)
        #expect(elapsed < .milliseconds(100), "took \(elapsed)")
        #expect((out["omitted"]?.intValue ?? 0) + (out["omitted_chars"]?.intValue ?? 0) > 0)
        #expect(out.value(at: "object.kind")?.stringValue == "ConfigMap")
    }

    @Test func aProviderCannotLeakThroughKeyNames() async {
        struct LeakyProvider: ToolboxExtensionProviding {
            var tools: Set<ReadTool> { [.helmRelease] }
            func call(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue, redactor: Redactor) async throws -> JSONValue {
                ["values": ["db": ["password": "ProvLeak1", "port": 5432, "token": 12345, "secretName": "db-creds"]]]
            }
        }
        let source = FakeToolboxSource([testCluster("dev")])
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")), extensions: [LeakyProvider()])
        let out = await toolbox.call(.helmRelease, input: sampleInput(.helmRelease, cluster: "dev"))
        #expect(!out.text.contains("ProvLeak1") && !out.text.contains("12345"))
        #expect(out.json.value(at: "values.db.port")?.intValue == 5432)
        #expect(out.json.value(at: "values.db.secretName")?.stringValue == "db-creds")
    }

    @Test func theToolboxsOwnOutputKeysNeverLookLikeSecrets() async {
        func keys(_ v: JSONValue, into set: inout Set<String>) {
            switch v {
            case .object(let o): for (k, c) in o { set.insert(k); keys(c, into: &set) }
            case .array(let a): a.forEach { keys($0, into: &set) }
            default: break
            }
        }
        let source = FakeToolboxSource([testCluster("dev"), testCluster("prod", env: .production)])
        let toolbox = ClusterToolbox(source: source, policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        var found = Set<String>()
        for tool in ReadTool.allCases where tool.isOffered(to: .firstMate(conversation: "c")) {
            let out = await toolbox.call(tool, input: tool == .getResource ? ["cluster": "dev", "kind": "secret", "name": "s", "namespace": "apps"] : sampleInput(tool, cluster: "dev"))
            // get_resource's `object` carries the cluster's own field names; every other key is ours.
            var json = out.json
            if tool == .getResource { json["object"] = nil }
            keys(json, into: &found)
        }
        let denied = await toolbox.call(.getResource, input: sampleInput(.getResource, cluster: "prod"))
        keys(denied.json, into: &found)
        keys(Redactor().secretSummary(["kind": "Secret", "type": "Opaque", "metadata": ["name": "s"], "data": ["a": "YQ=="]]), into: &found)
        found.remove("a")   // a Secret's own data key name, not ours
        #expect(!found.isEmpty)
        for key in found { #expect(!Redactor.isSecretFieldName(key), Comment(rawValue: key)) }
    }

    @Test func escapeHeavyStringsAreStillCappedAndFlagged() {
        let json = (0..<1_200).map { "{\"id\": \($0), \"name\": \"item-\($0)\", \"tags\": [\"a\", \"b\"]}" }.joined(separator: ",\n")
        let cases: [(String, String)] = [
            ("43 KB JSON file", String(json.prefix(43_000))),
            ("40 KB of quotes", String(repeating: "\"", count: 40_000)),
            ("30 KB of control characters", String(repeating: "\u{01}", count: 30_000)),
            ("backslashes and newlines", String(repeating: "\\\n", count: 20_000)),
        ]
        for (name, text) in cases {
            let value: JSONValue = ["cluster": "dev", "object": ["kind": "ConfigMap", "data": ["file": .string(text), "small": "keep"]]]
            let out = ToolResultLimiter.limit(value)
            #expect(out["error"] == nil, Comment(rawValue: name))
            #expect(out.jsonString().utf8.count <= ToolResultLimiter.maxBytes, Comment(rawValue: "\(name): \(out.jsonString().utf8.count) bytes"))
            #expect(out["truncated"]?.boolValue == true, Comment(rawValue: name))
        }
    }

    @Test func aProviderCannotLeakThroughEnvPairsOrNestedValues() async {
        struct P: ToolboxExtensionProviding {
            var tools: Set<ReadTool> { [.helmRelease] }
            func call(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue, redactor: Redactor) async throws -> JSONValue {
                ["items": [["name": "DB_PASSWORD", "value": "EnvLeak1"], ["name": "REGION", "value": "eu"]],
                 "a": ["password": ["value": "NestLeak1"], "apiKey": ["nested": ["deep": "NestLeak2"]], "secretName": "keep-me"]]
            }
        }
        let toolbox = ClusterToolbox(source: FakeToolboxSource([testCluster("dev")]), policy: ToolboxPolicy(caller: .firstMate(conversation: "c")), extensions: [P()])
        let out = await toolbox.call(.helmRelease, input: sampleInput(.helmRelease, cluster: "dev"))
        for leak in ["EnvLeak1", "NestLeak1", "NestLeak2"] { #expect(!out.text.contains(leak), Comment(rawValue: leak)) }
        #expect(out.json.value(at: "a.secretName")?.stringValue == "keep-me")
        #expect(out.json["items"]?[1]?["value"]?.stringValue == "eu")
    }

    @Test func sizesAreExemptOnlyInsideTheToolboxsOwnSecretSummary() {
        let r = Redactor()
        let own = r.secretSummary(["kind": "Secret", "metadata": ["name": "s"], "data": ["password": "aHVudGVyMg=="]])
        #expect(r.scrubOutput(own).value(at: "sizes.password")?.intValue == 7)
        let imposter: JSONValue = ["kind": "Other", "sizes": ["password": 1234]]
        #expect(r.scrubOutput(imposter).value(at: "sizes.password")?.stringValue == "‹redacted: field password›")
    }

    @Test func catalogIsStableSortedAndStrict() {
        let first = ToolCatalog.definitions(for: .firstMate(conversation: "a"))
        let second = ToolCatalog.definitions(for: .firstMate(conversation: "b"))
        #expect(first == second)
        #expect(first.map(\.name) == first.map(\.name).sorted())
        #expect(first.map(\.name).count == Set(first.map(\.name)).count)
        for tool in first {
            #expect(tool.inputSchema["additionalProperties"]?.boolValue == false, "\(tool.name)")
            #expect(tool.inputSchema["required"]?.arrayValue != nil, "\(tool.name)")
            #expect(tool.inputSchema["type"]?.stringValue == "object", "\(tool.name)")
            let required = tool.inputSchema["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
            #expect(required == required.sorted())
            let properties = Set(tool.inputSchema["properties"]?.objectValue?.keys.map { $0 } ?? [])
            #expect(Set(required).isSubset(of: properties), "\(tool.name)")
        }
        #expect(ToolCatalog.definitions(for: .beacon(client: "x")).allSatisfy { !$0.isProposal })
        let expected = ["describe_owner_chain", "explain_field", "get_events", "get_logs", "get_metrics", "get_resource", "gitops_status", "helm_release",
                        "list_clusters", "list_resources", "propose_command", "propose_gitops_action", "propose_helm_upgrade", "propose_manifest",
                        "propose_patch", "rbac_can_i", "search", "survey_findings"]
        #expect(first.map(\.name) == expected)
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func record(_ q: ReadOnlyKubeAccess.AccessQuestion) { record("\(q.verb)/\(q.resource)") }
    func record(_ s: String) { lock.lock(); storage.append(s); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return storage }
    var count: Int { values.count }
}
