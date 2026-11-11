#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private final class Clock: @unchecked Sendable {
    private let t = Mutex(Date(timeIntervalSince1970: 1_000_000))
    var now: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}

private func cluster() -> ClusterConfig {
    ClusterConfig(id: "prod1", name: "prod-eu", server: URL(string: "https://prod.test:6443")!, environment: .production)
}

private func session(scope: GangwayScope = .standard, binding: PeerBinding, registry: SessionRegistry? = nil) throws -> GangwaySession {
    let r = registry ?? SessionRegistry(gate: { DevSafetyPolicy(isActive: false) })
    return try r.create(cluster: cluster(), origin: .terminal(paneID: "p1"), scope: scope, binding: binding).session
}

private func mutation(_ path: String = "/apis/apps/v1/namespaces/shop/deployments/web", method: String = "PATCH", hold: UUID? = nil, kind: GangwayClass = .mutation, created: CreatedName? = nil) throws -> GrantRequest {
    GrantRequest(holdID: hold, kind: kind, shape: RequestClassifier.shape(of: try RequestClassifier.canonicalSegments(of: path)), method: method, createdName: created)
}

@Suite("Command eligibility")
struct CommandEligibilityTests {
    @Test("eligible single commands", arguments: [
        "kubectl rollout restart deployment/web", "kubectl -n shop delete pod web-1", "kubectl apply -f deploy.yaml", "/usr/local/bin/kubectl scale deploy web --replicas=3",
        "helm upgrade web ./chart", "flux reconcile kustomization apps", "kubectl --context prod -n x patch cm a -p '{\"a\":1}'",
        "kubectl label pod web 'tier=a b'",
    ])
    func eligible(line: String) { #expect(CommandEligibility.isEligible(line), Comment(rawValue: line)) }

    @Test("everything a shell could turn into something else is not eligible", arguments: [
        "kubectl get pods; kubectl delete pod x", "kubectl get pods && kubectl delete pod x", "kubectl get pods || true", "kubectl get pods | xargs kubectl delete",
        "kubectl get pods &", "kubectl delete $(kubectl get pods -o name)", "kubectl delete `echo pod`", "kubectl diff -f <(cat x.yaml)", "kubectl get pods\nkubectl delete pod x",
        "xargs kubectl delete", "eval kubectl delete pod x", "exec kubectl delete pod x", "watch kubectl get pods", "sh -c 'kubectl delete pod x'", "bash -c 'kubectl get pods'",
        "zsh -c 'kubectl get pods'", "for p in a b; do kubectl delete pod $p; done", "while true; do kubectl get pods; done", "if true; then kubectl get pods; fi",
        "FOO=1 kubectl delete pod x", "KUBECONFIG=/tmp/x kubectl get pods", "kubectl --kubeconfig /tmp/x get pods", "kubectl --kubeconfig=/tmp/x get pods",
        "kubectl --server https://x get pods", "kubectl -s https://x get pods", "kubectl --token abc get pods", "kubectl --token=abc get pods", "kubectl get pods -o name | head",
        "k delete pod x", "k9s", "tmux", "kubectl proxy", "kubectl port-forward pod/web 8080:80", "kubectl exec -it web -- sh", "kubectl attach web", "kubectl cp web:/a ./a",
        "kubectl debug web -it --image=busybox", "kubectl neat get pods", "kubectl krew install x", "", "kubectl", "kubectl 'unterminated", "helm  --kubeconfig x list",
        "kubectl -n shop", "./kubectl delete pod x", "kubectl-foo get",
        // an editor's shell escape would inherit the grant
        "kubectl edit deploy web", "kubectl -n shop edit cm a", "kubectl create -f x.yaml --edit", "kubectl apply edit-last-applied deploy/web",
        // the short server flag in its attached forms
        "kubectl -shttps://evil get pods", "kubectl -s=https://evil get pods", "kubectl get pods -shttps://evil",
    ])
    func notEligible(line: String) { #expect(!CommandEligibility.isEligible(line), Comment(rawValue: line)) }

    @Test("the tokenizer does no expansion")
    func tokenizer() {
        #expect(CommandEligibility.tokenize("a 'b c' \"d e\" f\\ g") == ["a", "b c", "d e", "f g"])
        #expect(CommandEligibility.tokenize("a '") == nil)
        #expect(CommandEligibility.tokenize("echo $HOME") == ["echo", "$HOME"])
    }
}

@Suite("Grant scope")
struct GrantScopeTests {
    private func rig() -> (GrantStore, Clock) {
        let clock = Clock()
        return (GrantStore(now: { clock.now }), clock)
    }

    private let shell = ReportedCommand(id: "c1", line: "kubectl rollout restart deployment/web")

    /// A session whose shell currently reports `shell` (a command grant applies only while its command is the running one).
    private func shellSession(foreground: pid_t = 700) throws -> GangwaySession {
        let s = try session(binding: .pty(device: 0, session: 500, foreground: { foreground }))
        s.reportedCommand = shell
        return s
    }

    @Test("a command grant covers mutations from the bound foreground job until its OSC 133 D")
    func commandGrantUntilEnd() throws {
        let (grants, _) = rig()
        let s = try shellSession()
        let job = PeerProcess(pid: 701, session: 500, group: 700)
        #expect(!grants.covers(try mutation(), session: s, peer: job))
        #expect(grants.grantCommand(session: s, command: shell))
        #expect(grants.covers(try mutation(), session: s, peer: job))
        #expect(grants.covers(try mutation("/api/v1/namespaces/shop/configmaps/a", method: "DELETE"), session: s, peer: job))
        grants.endCommand(session: s, commandID: "c1")
        #expect(!grants.covers(try mutation(), session: s, peer: job))
    }

    @Test("the end of another command does not end the grant, and the grant never moves to the next command")
    func endOfOtherCommand() throws {
        let (grants, _) = rig()
        let s = try shellSession()
        let job = PeerProcess(pid: 701, session: 500, group: 700)
        grants.grantCommand(session: s, command: shell)
        grants.endCommand(session: s, commandID: "other")
        #expect(grants.covers(try mutation(), session: s, peer: job))
        grants.endCommand(session: s, commandID: "c1")
        grants.grantCommand(session: s, command: ReportedCommand(id: "c2", line: "kubectl get pods"))
        grants.endCommand(session: s, commandID: "c2")
        #expect(!grants.covers(try mutation(), session: s, peer: job))
    }

    @Test("a command grant expires after 10 minutes, whatever the command is doing")
    func tenMinuteCap() throws {
        let (grants, clock) = rig()
        let s = try shellSession()
        let job = PeerProcess(pid: 701, session: 500, group: 700)
        grants.grantCommand(session: s, command: shell)
        clock.advance(599)
        #expect(grants.covers(try mutation(), session: s, peer: job))
        clock.advance(2)
        #expect(!grants.covers(try mutation(), session: s, peer: job))
        #expect(!grants.hasCommandGrant(session: s))
    }

    @Test("a command that is not eligible gets no grant")
    func ineligible() throws {
        let (grants, _) = rig()
        let s = try session(binding: .pty(device: 0, session: 500, foreground: { 700 }))
        #expect(!grants.grantCommand(session: s, command: ReportedCommand(id: "x", line: "kubectl get pods; kubectl delete pod a")))
        #expect(!grants.grantCommand(session: s, command: ReportedCommand(id: "x", line: "k9s")))
        #expect(!grants.hasCommandGrant(session: s))
    }

    @Test("PTY binding: the peer must exist, be in the shell's session and be the foreground job")
    func ptyBinding() throws {
        let (grants, _) = rig()
        let foreground = Mutex<pid_t>(700)
        let s = try session(binding: .pty(device: 0, session: 500, foreground: { foreground.withLock { $0 } }))
        s.reportedCommand = shell
        grants.grantCommand(session: s, command: shell)
        #expect(!grants.covers(try mutation(), session: s, peer: nil))                                                           // no peer found
        #expect(!grants.covers(try mutation(), session: s, peer: PeerProcess(pid: 9, session: 501, group: 700)))                // another session
        #expect(!grants.covers(try mutation(), session: s, peer: PeerProcess(pid: 9, session: 500, group: 800)))                // background job
        #expect(grants.covers(try mutation(), session: s, peer: PeerProcess(pid: 9, session: 500, group: 700)))
        foreground.withLock { $0 = 900 }                                                                                         // the job moved to the background
        #expect(!grants.covers(try mutation(), session: s, peer: PeerProcess(pid: 9, session: 500, group: 700)))
    }

    @Test("a command grant never covers streams, proxy requests or another session")
    func notStreams() throws {
        let (grants, _) = rig()
        let s = try shellSession()
        let other = try shellSession()
        let job = PeerProcess(pid: 701, session: 500, group: 700)
        grants.grantCommand(session: s, command: shell)
        #expect(!grants.covers(try mutation("/api/v1/namespaces/shop/pods/web/exec", method: "POST", kind: .stream(.exec(interactive: false))), session: s, peer: job))
        #expect(!grants.covers(try mutation("/api/v1/namespaces/shop/pods/web/proxy", method: "POST", kind: .proxy(method: "POST")), session: s, peer: job))
        #expect(!grants.covers(try mutation(), session: other, peer: job))
    }

    @Test("a command grant ends when the shell reports another command (or none), even if its D mark was never seen")
    func grantFollowsTheRunningCommand() throws {
        let (grants, _) = rig()
        let s = try shellSession()
        let job = PeerProcess(pid: 701, session: 500, group: 700)
        grants.grantCommand(session: s, command: shell)
        #expect(grants.covers(try mutation(), session: s, peer: job))
        s.reportedCommand = ReportedCommand(id: "c2", line: "kubectl delete ns prod")
        #expect(!grants.covers(try mutation(), session: s, peer: job))
        s.reportedCommand = nil
        #expect(!grants.covers(try mutation(), session: s, peer: job))
    }

    @Test("a batch approval covers exactly the listed requests, once")
    func batchExact() throws {
        let (grants, _) = rig()
        let s = try session(binding: .none)
        let a = UUID(), b = UUID(), later = UUID()
        grants.approveBatch(session: s, holdIDs: [a, b])
        #expect(!grants.covers(try mutation(hold: later), session: s, peer: nil))
        #expect(grants.covers(try mutation(hold: a), session: s, peer: nil))
        #expect(!grants.covers(try mutation(hold: a), session: s, peer: nil), "an approval is spent once")
        #expect(grants.covers(try mutation(hold: b), session: s, peer: nil))
        #expect(!grants.covers(try mutation(hold: nil), session: s, peer: nil))
    }

    @Test("a batch approval expires and ends with the session's grants")
    func batchExpiry() throws {
        let (grants, clock) = rig()
        let s = try session(binding: .none)
        let a = UUID(), b = UUID()
        grants.approveBatch(session: s, holdIDs: [a, b])
        clock.advance(GrantStore.batchLifetime + 1)
        #expect(!grants.covers(try mutation(hold: a), session: s, peer: nil))
        grants.approveBatch(session: s, holdIDs: [b])
        grants.revoke(session: s)
        #expect(!grants.covers(try mutation(hold: b), session: s, peer: nil))
    }

    @Test("an approval of one session does not cover another")
    func batchSessions() throws {
        let (grants, _) = rig()
        let s1 = try session(binding: .none), s2 = try session(binding: .none)
        let a = UUID()
        grants.approveBatch(session: s1, holdIDs: [a])
        #expect(!grants.covers(try mutation(hold: a), session: s2, peer: nil))
    }

    @Test("Helm object grants cover the listed objects and refuse the rest")
    func objectGrants() throws {
        let (grants, clock) = rig()
        let s = try session(scope: .objects, binding: .processGroup(4242))
        grants.setObjects(session: s, objects: [
            GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web"),
            GrantedObject(resource: "configmaps", namespace: "shop", name: "base", createAnyName: true),
            GrantedObject(resource: "secrets", namespace: "shop", namePrefix: "sh.helm.release.v1.web.v"),
        ])
        func covers(_ path: String, _ method: String) throws -> Bool { grants.coversObject(try mutation(path, method: method), session: s) }
        #expect(try covers("/apis/apps/v1/namespaces/shop/deployments/web", "PATCH"))
        #expect(try !covers("/apis/apps/v1/namespaces/shop/deployments/other", "PATCH"))
        #expect(try !covers("/apis/apps/v1/namespaces/other/deployments/web", "PATCH"))
        #expect(try !covers("/apis/apps/v1/namespaces/shop/statefulsets/web", "PATCH"))
        #expect(try covers("/api/v1/namespaces/shop/configmaps", "POST"))
        #expect(try covers("/api/v1/namespaces/shop/configmaps/base", "DELETE"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/anything", "DELETE"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/anything", "PATCH"))
        #expect(try covers("/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v3", "PUT"))
        #expect(try !covers("/api/v1/namespaces/shop/secrets/other", "PUT"))
        #expect(try covers("/api/v1/namespaces/shop/secrets/sh.helm.release.v1.web.v3/status", "PUT"))
        #expect(try !covers("/api/v1/namespaces/kube-system/secrets/sh.helm.release.v1.web.v3", "PUT"))
        #expect(try !covers("/api/v1/namespaces/shop/pods/web/exec", "POST"))
        #expect(try !covers("/apis/rbac.authorization.k8s.io/v1/clusterroles/admin", "DELETE"))
        clock.advance(3601)
        #expect(try !covers("/apis/apps/v1/namespaces/shop/deployments/web", "PATCH"))
        grants.revoke(session: s)
    }

    @Test("an item without a name is not a wildcard: deletecollection, PUT, PATCH and DELETE by any name are refused, and a create needs the explicit flag")
    func noWildcards() throws {
        let (grants, _) = rig()
        let s = try session(scope: .objects, binding: .processGroup(4242))
        grants.setObjects(session: s, objects: [GrantedObject(resource: "configmaps", namespace: "shop")])
        func covers(_ path: String, _ method: String) throws -> Bool { grants.coversObject(try mutation(path, method: method), session: s) }
        #expect(try !covers("/api/v1/namespaces/shop/configmaps", "DELETE"))               // deletecollection
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/x", "DELETE"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/x", "PUT"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/x", "PATCH"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps", "POST"), "a create with no usable body name is refused")
        grants.setObjects(session: s, objects: [GrantedObject(resource: "configmaps", namespace: "shop", createAnyName: true)])
        #expect(try covers("/api/v1/namespaces/shop/configmaps", "POST"))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps", "DELETE"))
    }

    @Test("a create is matched by the name in its body, as bytes, against exact names, prefixes and generateName prefixes")
    func createByBodyName() throws {
        let (grants, _) = rig()
        let s = try session(scope: .objects, binding: .isolatedGroup(4242))
        grants.setObjects(session: s, objects: [
            GrantedObject(resource: "configmaps", namespace: "shop", name: "listed"),
            GrantedObject(resource: "secrets", namespace: "shop", namePrefix: "sh.helm.release.v1.web.v"),
            GrantedObject(group: "batch", resource: "jobs", namespace: "shop", generateNamePrefix: "hook-"),
        ])
        func creates(_ path: String, _ name: CreatedName?) throws -> Bool { grants.coversObject(try mutation(path, method: "POST", created: name), session: s) }
        #expect(try creates("/api/v1/namespaces/shop/configmaps", .name("listed")))
        #expect(try !creates("/api/v1/namespaces/shop/configmaps", .name("unlisted")))
        #expect(try !creates("/api/v1/namespaces/shop/configmaps", nil))
        #expect(try !creates("/api/v1/namespaces/other/configmaps", .name("listed")))
        #expect(try !creates("/api/v1/namespaces/shop/secrets", .name("sh.helm.release.v1.other.v1")))
        #expect(try creates("/api/v1/namespaces/shop/secrets", .name("sh.helm.release.v1.web.v7")))
        #expect(try creates("/apis/batch/v1/namespaces/shop/jobs", .generateName("hook-")))
        #expect(try !creates("/apis/batch/v1/namespaces/shop/jobs", .generateName("hook-x")))
        #expect(try !creates("/apis/batch/v1/namespaces/shop/jobs", .name("hook-1")), "a name needs an exact or prefix item, not a generateName one")
        // canonically equivalent Unicode is not the same name
        #expect(try !creates("/api/v1/namespaces/shop/configmaps", .name("liste\u{0301}d")))
        let accented = GrantedObject(resource: "configmaps", namespace: "shop", name: "caf\u{00E9}")
        grants.setObjects(session: s, objects: [accented])
        #expect(try creates("/api/v1/namespaces/shop/configmaps", .name("caf\u{00E9}")))
        #expect(try !creates("/api/v1/namespaces/shop/configmaps", .name("cafe\u{0301}")))
    }

    @Test("an object grant covers only the process it was opened for")
    func objectGrantPeer() throws {
        let (grants, clock) = rig()
        let s = try session(scope: .objects, binding: .isolatedGroup(4242))
        grants.setObjects(session: s, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let request = try mutation()
        #expect(grants.covers(request, session: s, peer: PeerProcess(pid: 4242, session: 4242, group: 4242)))
        #expect(!grants.covers(request, session: s, peer: nil))
        #expect(!grants.covers(request, session: s, peer: PeerProcess(pid: 9, session: 4242, group: 4243)), "another process group")
        #expect(!grants.covers(request, session: s, peer: PeerProcess(pid: 9, session: 1, group: 4242)), "joined the group from outside its session")
        let other = try session(scope: .objects, binding: .isolatedGroup(4242))
        #expect(!grants.covers(request, session: other, peer: PeerProcess(pid: 4242, session: 4242, group: 4242)), "another session has no grant")
        clock.advance(601)
        #expect(!grants.covers(request, session: s, peer: PeerProcess(pid: 4242, session: 4242, group: 4242)), "expired")
    }

    @Test("a session binds to its helm process once, and only an object session")
    func bindOnce() throws {
        let s = try session(scope: .objects, binding: .none)
        let grants = GrantStore()
        grants.setObjects(session: s, objects: [GrantedObject(group: "apps", resource: "deployments", namespace: "shop", name: "web")])
        let peer = PeerProcess(pid: 4242, session: 4242, group: 4242)
        #expect(!grants.covers(try mutation(), session: s, peer: peer), "unbound covers nothing")
        #expect(!s.bindIsolatedGroup(1) && !s.bindIsolatedGroup(0))
        #expect(s.bindIsolatedGroup(4242))
        #expect(!s.bindIsolatedGroup(4243), "a second bind is refused")
        #expect(grants.covers(try mutation(), session: s, peer: peer))
        #expect(try !session(binding: .none).bindIsolatedGroup(4242), "a standard session never binds")
        let revoked = try session(scope: .objects, binding: .none)
        revoked.revoke(reason: "x")
        #expect(!revoked.bindIsolatedGroup(4242))
    }

    @Test("the body of a create is read strictly")
    func bodyParsing() {
        func name(_ json: String, type: String = "application/json", extra: [HTTPRequestHead.Header] = [], ns: String? = "shop") -> CreatedName? {
            GrantBody.createdName(body: Data(json.utf8), headers: [.init(name: "Content-Type", value: type)] + extra, pathNamespace: ns)
        }
        #expect(name(#"{"metadata":{"name":"a"}}"#) == .name("a"))
        #expect(name(#"{"metadata":{"name":"a","namespace":"shop"}}"#) == .name("a"))
        #expect(name(#"{"metadata":{"name":"a","namespace":"other"}}"#) == nil)
        #expect(name(#"{"metadata":{"name":"a","namespace":"other"}}"#, ns: nil) == .name("a"), "a cluster-scoped create has no path namespace")
        #expect(name(#"{"metadata":{"name":"","generateName":"g-"}}"#) == .generateName("g-"))
        #expect(name(#"{"metadata":{"name":"a","generateName":"g-"}}"#) == .name("a"))
        #expect(name(#"{"metadata":{"generateName":""}}"#) == nil)
        #expect(name(#"{"metadata":{}}"#) == nil)
        #expect(name(#"{"metadata":{"name":"a","name":"b"}}"#) == nil)
        #expect(name(#"{"metadata":{"name":"a","Name":"b"}}"#) == nil)
        #expect(name(#"{"metadata":{"name":"a"},"Metadata":{"name":"b"}}"#) == nil)
        #expect(name(#"{"Metadata":{"name":"a"}}"#) == nil)
        #expect(name(#"{"metadata":{"name":"a\ud800\nb"}}"#) == .name("a\u{FFFD}\nb"), "a lone high surrogate before another escape is U+FFFD first")
        #expect(name(#"{"metadata":{"name":1}}"#) == nil)
        #expect(name(#"{"metadata":{"name":null,"generateName":"g-"}}"#) == nil)
        #expect(name(#"{"metadata":"x"}"#) == nil)
        #expect(name("[1]") == nil)
        #expect(name("not json") == nil)
        #expect(name(#"{"metadata":{"name":"a"}}"#, type: "application/yaml") == nil)
        #expect(name(#"{"metadata":{"name":"a"}}"#, type: "application/json; charset=utf-8") == .name("a"))
        #expect(name(#"{"metadata":{"name":"a"}}"#, extra: [.init(name: "Content-Encoding", value: "gzip")]) == nil)
        #expect(GrantBody.createdName(body: Data(#"{"metadata":{"name":"a"}}"#.utf8), headers: [], pathNamespace: nil) == nil, "no content type")
        #expect(GrantBody.createdName(body: nil, headers: [], pathNamespace: nil) == nil)
        let big = Data(repeating: 0x20, count: GrantBody.maxCreateBody) + Data(#"{"metadata":{"name":"a"}}"#.utf8)
        #expect(GrantBody.createdName(body: big, headers: [.init(name: "Content-Type", value: "application/json")], pathNamespace: nil) == nil)
    }

    @Test("an object grant never covers a stream or proxy class")
    func objectGrantClass() throws {
        let (grants, _) = rig()
        let s = try session(scope: .objects, binding: .processGroup(4242))
        grants.setObjects(session: s, objects: [GrantedObject(resource: "pods", namespace: "shop", name: "a")])
        #expect(!grants.coversObject(try mutation("/api/v1/namespaces/shop/pods/a", method: "POST", kind: .stream(.otherUpgrade)), session: s))
        #expect(grants.coversObject(try mutation("/api/v1/namespaces/shop/pods/a", method: "DELETE"), session: s))
    }

    @Test("a Helm or flux run's requests must come from its spawned process group")
    func processGroupBinding() {
        #expect(GrantStore.peerIsBound(PeerProcess(pid: 5, session: 1, group: 4242), to: .processGroup(4242)))
        #expect(!GrantStore.peerIsBound(PeerProcess(pid: 5, session: 1, group: 4243), to: .processGroup(4242)))
        #expect(!GrantStore.peerIsBound(nil, to: .processGroup(4242)))
        #expect(!GrantStore.peerIsBound(PeerProcess(pid: 5, session: 1, group: 4242), to: .none))
        #expect(GrantStore.peerIsBound(PeerProcess(pid: 5, session: 4242, group: 4242), to: .isolatedGroup(4242)))
        #expect(!GrantStore.peerIsBound(PeerProcess(pid: 5, session: 1, group: 4242), to: .isolatedGroup(4242)))
    }

    @Test("a session scope of dry-run-only exists on the session")
    func scopes() throws {
        let s = try session(scope: .dryRunOnly, binding: .none)
        #expect(s.scope == .dryRunOnly)
    }
}
#endif
