import Testing
import Foundation
import Darwin
@testable import WheelhouseKit
@testable import WheelhouseUI

@Suite("Port-forward plan")
struct PortForwardPlanTests {
    private let service: JSONValue = [
        "spec": ["ports": [
            ["name": "mysql", "port": 3306, "protocol": "TCP", "targetPort": 3306],
            ["name": "metrics", "port": 9104, "targetPort": "exporter"],
            ["name": "dns", "port": 53, "protocol": "UDP"],
        ]]
    ]

    private func config(_ env: ClusterEnvironment = .development, readOnly: Bool = false, allowExec: Bool = false, demo: Bool = false) -> ClusterConfig {
        var c = ClusterConfig(id: "c1", name: "c1", server: URL(string: "https://c1.example")!, environment: env)
        c.readOnly = readOnly
        c.allowExecInReadOnly = allowExec
        c.isDemo = demo
        return c
    }

    private func info(_ target: PortForwardTarget, local: Int, state: PortForwardState = .active, cluster: ClusterID = "c1") -> PortForwardInfo {
        PortForwardInfo(id: UUID(), clusterID: cluster, clusterName: "c1", target: target, localPort: local, state: state, startedAt: Date(),
                        bytesDown: 0, bytesUp: 0, openConnections: 0, totalConnections: 0)
    }

    // MARK: Ports

    @Test func servicePortsAreTCPOnlyWithNames() {
        let ports = ForwardablePorts.ports(kind: .service, raw: service)
        #expect(ports.map(\.port) == [3306, 9104])
        #expect(ports[0].title == "3306 · mysql")
        #expect(ports[1].detail == "target port exporter")
    }

    @Test func aUDPOnlyServiceHasNothingToForward() {
        let raw: JSONValue = ["spec": ["ports": [["port": 53, "protocol": "UDP"]]]]
        #expect(ForwardablePorts.ports(kind: .service, raw: raw).isEmpty)
    }

    @Test func podPortsAreDeduplicatedAcrossContainers() {
        let raw: JSONValue = ["spec": ["containers": [
            ["name": "a", "ports": [["containerPort": 8080, "name": "http"], ["containerPort": 9090, "protocol": "UDP"]]],
            ["name": "b", "ports": [["containerPort": 8080], ["containerPort": 9100]]],
        ]]]
        let ports = ForwardablePorts.ports(kind: .pod, raw: raw)
        #expect(ports.map(\.port) == [8080, 9100])
        #expect(ports[0].detail == "container a")
        #expect(ports[0].isHTTP)
    }

    @Test func otherKindsHaveNoPorts() {
        #expect(ForwardablePorts.ports(kind: .configMap, raw: service).isEmpty)
    }

    // MARK: Local port

    @Test func sameNumberWhenAvailableAndAtLeast1024() {
        #expect(ForwardPlanner.localPort(remote: 3306, used: [], isAvailable: { _ in true }) == 3306)
    }

    @Test func nextFreePortWhenTheSameNumberIsTaken() {
        #expect(ForwardPlanner.localPort(remote: 3306, used: [3306], isAvailable: { _ in true }) == 3307)
        #expect(ForwardPlanner.localPort(remote: 3306, used: [], isAvailable: { $0 != 3306 && $0 != 3307 }) == 3308)
    }

    @Test func privilegedRemotePortsStartAt8000Plus() {
        #expect(ForwardPlanner.localPort(remote: 80, used: [], isAvailable: { _ in true }) == 8080)
        #expect(ForwardPlanner.localPort(remote: 443, used: [], isAvailable: { _ in true }) == 8443)
    }

    @Test func nothingAvailableGivesNil() {
        #expect(ForwardPlanner.localPort(remote: 3306, used: [], isAvailable: { _ in false }) == nil)
    }

    @Test func aWildcardListenerOnTheSameNumberIsNotAvailable() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: 0)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(bound == 0)
        try #require(listen(fd, 128) == 0)   // probes queue in the backlog; a real server accepts them
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        try #require(named == 0)
        let port = Int(UInt16(bigEndian: addr.sin_port))
        #expect(!LocalPort.isAvailable(port))
        let chosen = try #require(ForwardPlanner.localPort(remote: port, used: []))
        #expect(chosen != port)
    }

    @Test func aPortInTimeWaitAfterAStoppedForwardIsAvailableAgain() throws {
        // Listener and client on a fixed loopback port, server closes first: the port sits in TIME_WAIT.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        try #require(listener >= 0)
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        try #require(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        try #require(listen(listener, 1) == 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        let client = socket(AF_INET, SOCK_STREAM, 0)
        try #require(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } == 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        close(accepted); close(client); close(listener)    // server side closes first: TIME_WAIT on `port`
        #expect(LocalPort.isAvailable(port))
    }

    // MARK: Confirmation

    @Test func aDefaultConfirmationOnAReadOnlyClusterThatAllowsExecIsStillRefused() {
        let request = ConfirmRequest(title: "t", message: "m", verb: "v", cluster: config(.production, readOnly: true, allowExec: true), resource: "r",
                                     confirmationText: "r", action: {})
        #expect(request.refusal(live: config(.production, readOnly: true, allowExec: true)) == MutationPolicy.readOnlyReason)
        #expect(request.requiresTyping)
    }

    @Test func thePortForwardFactoryIsAButtonConfirmationAllowedByExecInReadOnly() {
        let c = config(.production, readOnly: true, allowExec: true)
        let request = ConfirmRequest.portForward(title: "t", message: "m", verb: "Forward", cluster: c, namespace: "db", resource: "svc/x:1", confirmationText: "x", action: {})
        #expect(request.requestClass == .portForward)
        #expect(!request.requiresTyping)
        #expect(request.refusal(live: c) == nil)
        #expect(request.refusal(live: config(.production, readOnly: true)) == MutationPolicy.readOnlyReason)
    }

    // MARK: Index

    @Test func theIndexFindsLiveForwardsOfAnObjectOnly() {
        let svc = PortForwardTarget(kind: .service, namespace: "db", name: "mariadb", remotePort: 3306)
        let other = PortForwardTarget(kind: .service, namespace: "db", name: "redis", remotePort: 6379)
        let pod = PortForwardTarget(kind: .pod, namespace: "db", name: "mariadb", remotePort: 3306)
        let index = ForwardIndex([info(svc, local: 3306), info(other, local: 6379), info(pod, local: 3307, state: .stopped), info(svc, local: 9999, cluster: "c2")])
        let ref = ResourceRef(clusterID: "c1", kind: .service, namespace: "db", name: "mariadb")
        #expect(index.entries(for: ref).map(\.localPort) == [3306])
        #expect(index.isForwarding(ref, remotePort: 3306))
        #expect(!index.isForwarding(ref, remotePort: 80))
        #expect(index.entries(for: ResourceRef(clusterID: "c1", kind: .pod, namespace: "db", name: "mariadb")).isEmpty)
        #expect(index.entries(for: ResourceRef(clusterID: "c1", kind: .configMap, namespace: "db", name: "mariadb")).isEmpty)
    }

    @Test func theIndexIgnoresByteCounters() {
        let target = PortForwardTarget(kind: .service, namespace: "db", name: "mariadb", remotePort: 3306)
        let a = info(target, local: 3306)
        var b = a
        b.bytesDown = 4096
        b.openConnections = 2
        #expect(ForwardIndex([a]) == ForwardIndex([b]))
        b.state = .stopped
        #expect(ForwardIndex([a]) != ForwardIndex([b]))
    }

    // MARK: Gate

    @Test func developmentIsAllowedWithoutConfirmation() {
        #expect(PortForwardGate.decide(config(.development)) == .allowed(confirmation: false))
    }

    @Test func productionAsksForAButtonConfirmation() {
        #expect(PortForwardGate.decide(config(.production)) == .allowed(confirmation: true))
    }

    @Test func readOnlyIsRefusedUnlessExecIsAllowed() {
        #expect(PortForwardGate.decide(config(.production, readOnly: true)) == .refused(MutationPolicy.readOnlyReason))
        #expect(PortForwardGate.decide(config(.production, readOnly: true, allowExec: true)) == .allowed(confirmation: true))
        #expect(PortForwardGate.decide(config(.development, readOnly: true, allowExec: true)) == .allowed(confirmation: false))
    }

    @Test func demoClustersAreRefusedFirst() {
        guard case .refused = PortForwardGate.decide(config(.production, demo: true)) else { Issue.record("demo must be refused"); return }
    }

    // MARK: Form

    @Test func theFormDefaultsToTheFirstPortAndAutomaticLocal() {
        var form = PortForwardFormState()
        form.load(ForwardablePorts.ports(kind: .service, raw: service))
        #expect(form.effectiveRemote == 3306)
        #expect(form.resolvedLocal(used: [], isAvailable: { _ in true }) == 3306)
        #expect(form.canForward(used: [], isAvailable: { _ in true }))
    }

    @Test func noDeclaredPortsAsksForOne() {
        var form = PortForwardFormState()
        form.load([])
        #expect(form.useCustomRemote)
        #expect(form.effectiveRemote == nil)
        form.customRemote = " 8080 "
        #expect(form.effectiveRemote == 8080)
        form.customRemote = "70000"
        #expect(form.effectiveRemote == nil)
    }

    @Test func localPortValidation() {
        var form = PortForwardFormState()
        form.load([ForwardablePort(port: 80)])
        form.localText = "80"
        #expect(form.localProblem(used: [], isAvailable: { _ in true }) != nil)
        form.localText = "abc"
        #expect(form.localProblem(used: [], isAvailable: { _ in true }) != nil)
        form.localText = "8081"
        #expect(form.localProblem(used: [8081], isAvailable: { _ in true }) == "Another forward already uses this port.")
        #expect(form.localProblem(used: [], isAvailable: { _ in false }) == "Port 8081 is in use on this Mac.")
        #expect(form.localProblem(used: [], isAvailable: { _ in true }) == nil)
        #expect(form.resolvedLocal(used: [], isAvailable: { _ in true }) == 8081)
        #expect(!form.canForward(used: [8081], isAvailable: { _ in true }))
    }
}
