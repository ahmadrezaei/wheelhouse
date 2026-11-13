import Testing
import Foundation
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

@MainActor
@Suite("Port-forward launcher")
struct PortForwardLauncherTests {
    /// A launcher over fakes: no cluster, no listener, no window.
    @MainActor final class Harness {
        var config: ClusterConfig
        var ports: [ForwardablePort]? = [ForwardablePort(port: 3306, name: "mysql")]
        var live: [PortForwardInfo] = []
        var started: [(PortForwardTarget, Int)] = []
        var stopped: [UUID] = []
        var advanced: [ResourceRef] = []
        var unavailable: Set<Int> = []
        var failStart: Error?
        var startDelay: Duration = .zero
        var locked = false
        var lockDuringFetch = false
        var onFetch: (() -> Void)?
        var session: ClusterSession?
        private(set) var launcher: PortForwardLauncher!

        init(_ environment: ClusterEnvironment = .development, readOnly: Bool = false, allowExec: Bool = false, demo: Bool = false) {
            var c = ClusterConfig(id: "c1", name: "c1", server: URL(string: "https://c1.example")!, environment: environment)
            c.readOnly = readOnly
            c.allowExecInReadOnly = allowExec
            c.isDemo = demo
            config = c
            session = ClusterSession(config: c, client: DemoKubeClient(config: c))
            launcher = PortForwardLauncher(seams: .init(
                session: { [unowned self] _ in session },
                fetchPorts: { [unowned self] _, _ in if lockDuringFetch { locked = true }; onFetch?(); return ports },
                start: { [unowned self] _, target, local in
                    if startDelay > .zero { try await Task.sleep(for: startDelay) }
                    if let failStart { throw failStart }
                    started.append((target, local))
                    let info = PortForwardInfo(id: UUID(), clusterID: "c1", clusterName: "c1", target: target, localPort: local, state: .active,
                                               startedAt: Date(), bytesDown: 0, bytesUp: 0, openConnections: 0, totalConnections: 0)
                    live.append(info)
                    return info
                },
                stop: { [unowned self] id in stopped.append(id) },
                liveForwards: { [unowned self] in live },
                isAvailable: { [unowned self] in !unavailable.contains($0) },
                presentAdvanced: { [unowned self] in advanced.append($0) },
                openBrowser: { _ in },
                isLocked: { [unowned self] in locked }))
        }

        /// Swaps in a session for the current `config` (a settings edit after the click).
        func reconfigure(_ edit: (inout ClusterConfig) -> Void) {
            edit(&config)
            session = ClusterSession(config: config, client: DemoKubeClient(config: config))
        }
    }

    private func service(_ name: String = "mariadb") -> ResourceRef { ResourceRef(clusterID: "c1", kind: .service, namespace: "db", name: name) }

    // MARK: One click

    @Test func oneClickStartsAtOnceWithTheSameLocalPortAndNoSheet() async {
        let h = Harness()
        let outcome = await h.launcher.forward(service(), port: 3306, configure: false)
        guard case .started = outcome else { Issue.record("expected started, got \(outcome)"); return }
        #expect(h.started.count == 1)
        #expect(h.started[0].0 == PortForwardTarget(kind: .service, namespace: "db", name: "mariadb", remotePort: 3306))
        #expect(h.started[0].1 == 3306)
        #expect(h.advanced.isEmpty)
        #expect(h.launcher.confirm == nil)
        #expect(h.launcher.banner?.message == "Forwarding 127.0.0.1:3306 → mariadb:3306")
        #expect(h.launcher.banner?.isError == false)
    }

    @Test func aTakenLocalPortPicksAFreeOne() async {
        let h = Harness()
        h.unavailable = [3306]
        await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(h.started.first?.1 == 3307)
    }

    @Test func aPrivilegedRemotePortMapsAbove1024() async {
        let h = Harness()
        await h.launcher.forward(service(), port: 80, configure: false)
        #expect(h.started.first?.1 == 8080)
    }

    @Test func noPortGivenAndOneDeclaredStartsAtOnce() async {
        let h = Harness()
        await h.launcher.forward(service(), port: nil, configure: false)
        #expect(h.started.first?.0.remotePort == 3306)
        #expect(h.advanced.isEmpty)
    }

    @Test func severalOrNoPortsGoToTheAdvancedForm() async {
        let h = Harness()
        h.ports = [ForwardablePort(port: 80), ForwardablePort(port: 443)]
        #expect(await h.launcher.forward(service(), port: nil, configure: false) == .advanced)
        h.ports = []
        #expect(await h.launcher.forward(service(), port: nil, configure: false) == .advanced)
        h.ports = nil
        #expect(await h.launcher.forward(service(), port: nil, configure: false) == .advanced)
        #expect(h.advanced.count == 3)
        #expect(h.started.isEmpty)
    }

    @Test func configureAlwaysOpensTheForm() async {
        let h = Harness()
        #expect(await h.launcher.forward(service(), port: 3306, configure: true) == .advanced)
        #expect(h.advanced == [service()])
        #expect(h.started.isEmpty)
    }

    @Test func aSecondClickOnALiveForwardStartsNothing() async {
        let h = Harness()
        await h.launcher.forward(service(), port: 3306, configure: false)
        let outcome = await h.launcher.forward(service(), port: 3306, configure: false)
        guard case .alreadyForwarding = outcome else { Issue.record("expected alreadyForwarding, got \(outcome)"); return }
        #expect(h.started.count == 1)
        #expect(h.launcher.banner?.forwardID == h.live[0].id)
    }

    @Test func twoClicksRacingStartOnce() async {
        let h = Harness()
        h.startDelay = .milliseconds(80)
        async let first = h.launcher.forward(service(), port: 3306, configure: false)
        try? await Task.sleep(for: .milliseconds(20))
        async let second = h.launcher.forward(service(), port: 3306, configure: false)
        _ = await (first, second)
        #expect(h.started.count == 1)
    }

    @Test func aFailedStartShowsAnErrorBannerAndKeepsNothingRunning() async {
        let h = Harness()
        h.failStart = PortForwardError.noReadyPod("No ready pod backs svc/mariadb.")
        let outcome = await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(outcome == .failed("No ready pod backs svc/mariadb."))
        #expect(h.launcher.banner?.isError == true)
        #expect(h.launcher.banner?.message == "No ready pod backs svc/mariadb.")
    }

    @Test func stopRemovesTheBannerAndStopsTheForward() async {
        let h = Harness()
        await h.launcher.forward(service(), port: 3306, configure: false)
        let id = h.live[0].id
        h.launcher.stop(id)
        #expect(h.stopped == [id])
        #expect(h.launcher.banner == nil)
    }

    @Test func objectsThatCannotBeForwardedAreRefused() async {
        let h = Harness()
        let cm = ResourceRef(clusterID: "c1", kind: .configMap, namespace: "db", name: "x")
        guard case .failed = await h.launcher.forward(cm, port: 80, configure: false) else { Issue.record("expected failure"); return }
        #expect(h.started.isEmpty)
    }

    // MARK: Safety

    @Test func productionKeepsABUTTONConfirmationAndStartsOnlyAfterIt() async throws {
        let h = Harness(.production)
        let outcome = await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(outcome == .confirming)
        #expect(h.started.isEmpty)
        let request = try #require(h.launcher.confirm)
        // The owner's bug: it asked for the service name. A port-forward on Production is a button confirmation, never typing.
        #expect(!request.requiresTyping)
        #expect(request.refusal(live: h.config) == nil)
        #expect(request.verb == "Forward")
        #expect(request.facts.contains { $0.value == "127.0.0.1:3306" })
        try await request.action()
        #expect(h.started.count == 1)
        #expect(h.launcher.banner?.message == "Forwarding 127.0.0.1:3306 → mariadb:3306")
    }

    @Test func productionReadOnlyWithExecAllowedIsNotRefusedByTheSheet() async throws {
        let h = Harness(.production, readOnly: true, allowExec: true)
        #expect(await h.launcher.forward(service(), port: 3306, configure: false) == .confirming)
        let request = try #require(h.launcher.confirm)
        #expect(request.refusal(live: h.config) == nil)
        #expect(!request.requiresTyping)
    }

    @Test func aReadOnlyClusterRefusesAndStartsNothing() async {
        let h = Harness(.development, readOnly: true)
        let outcome = await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(outcome == .refused(MutationPolicy.readOnlyReason))
        #expect(h.started.isEmpty)
        #expect(h.launcher.confirm == nil)
        #expect(h.launcher.banner?.isError == true)
    }

    @Test func aDemoClusterRefuses() async {
        let h = Harness(.production, demo: true)
        guard case .refused = await h.launcher.forward(service(), port: 3306, configure: false) else { Issue.record("expected refusal"); return }
        #expect(h.started.isEmpty)
        #expect(h.advanced.isEmpty)
    }

    @Test func theGateIsAskedAgainWhenTheConfirmationIsApproved() async throws {
        let h = Harness(.production)
        await h.launcher.forward(service(), port: 3306, configure: false)
        let request = try #require(h.launcher.confirm)
        h.reconfigure { $0.readOnly = true }          // edited while the sheet was open
        await #expect(throws: (any Error).self) { try await request.action() }
        #expect(h.started.isEmpty)
    }

    @Test func lockingTheAppClearsTheConfirmationAndTheBanner() async {
        let h = Harness(.production)
        await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(h.launcher.confirm != nil)
        h.launcher.showError("x")
        h.launcher.dismissForLock()
        #expect(h.launcher.confirm == nil)
        #expect(h.launcher.banner == nil)
    }

    @Test func lockingDuringTheRequestPresentsAndStartsNothing() async {
        let h = Harness(.production)
        h.ports = [ForwardablePort(port: 80), ForwardablePort(port: 443)]
        h.lockDuringFetch = true
        await h.launcher.forward(service(), port: nil, configure: false)
        #expect(h.advanced.isEmpty && h.started.isEmpty && h.launcher.confirm == nil)
        h.lockDuringFetch = false
        await h.launcher.forward(service(), port: 3306, configure: false)   // still locked
        #expect(h.started.isEmpty && h.launcher.confirm == nil)
    }

    @Test func aClusterRetaggedToProductionAfterTheClickStillAsks() async {
        let h = Harness(.development)
        h.ports = [ForwardablePort(port: 3306)]
        // The click resolved its session; the cluster becomes Production while the ports are being read.
        h.onFetch = { h.reconfigure { $0.environment = .production } }
        await h.launcher.forward(service(), port: nil, configure: false)
        #expect(h.started.isEmpty)
        #expect(h.launcher.confirm != nil)
    }

    @Test func theBannerGoesWhenItsForwardStopsAnywhere() async {
        let h = Harness()
        await h.launcher.forward(service(), port: 3306, configure: false)
        let before = ForwardIndex(h.live)
        h.launcher.forwardsChanged(old: ForwardIndex([]), new: before)      // it appeared: banner stays
        #expect(h.launcher.banner != nil)
        h.live[0].state = .stopped
        h.launcher.forwardsChanged(old: before, new: ForwardIndex(h.live))   // stopped from a detail or Sessions
        #expect(h.launcher.banner == nil)
    }

    @Test func aProductionDoubleClickMakesTwoConfirmationsButExactlyOneStart() async throws {
        let h = Harness(.production)
        await h.launcher.forward(service(), port: 3306, configure: false)
        let first = try #require(h.launcher.confirm)
        await h.launcher.forward(service(), port: 3306, configure: false)
        let second = try #require(h.launcher.confirm)
        #expect(first.id != second.id)
        try await first.action()
        try await second.action()
        #expect(h.started.count == 1)
    }

    // MARK: Advanced form (explicit local port)

    private func target() -> PortForwardTarget { PortForwardTarget(kind: .service, namespace: "db", name: "mariadb", remotePort: 3306) }

    @Test func theAdvancedFormStartsOnTheChosenLocalPort() async throws {
        let h = Harness()
        let outcome = await h.launcher.begin(session: try #require(h.session), target: target(), local: 4406, present: { _ in })
        guard case .started = outcome else { Issue.record("expected started, got \(outcome)"); return }
        #expect(h.started.first?.1 == 4406)
    }

    @Test func theAdvancedFormMayAddASecondLocalPortForAForwardedRemotePort() async throws {
        let h = Harness()
        let session = try #require(h.session)
        await h.launcher.begin(session: session, target: target(), local: 3306, present: { _ in })
        let again = await h.launcher.begin(session: session, target: target(), local: 4406, present: { _ in })
        guard case .started = again else { Issue.record("expected a second forward, got \(again)"); return }
        #expect(h.started.map(\.1) == [3306, 4406])
        // But not on a local port another forward holds.
        let taken = await h.launcher.begin(session: session, target: target(), local: 4406, present: { _ in })
        #expect(taken == .failed("Another forward already uses this port."))
        #expect(h.started.count == 2)
    }

    @Test func theAdvancedFormKeepsTheGateTheLockAndTheProductionConfirmation() async throws {
        let ro = Harness(.development, readOnly: true)
        #expect(await ro.launcher.begin(session: try #require(ro.session), target: target(), local: 4406, present: { _ in }) == .refused(MutationPolicy.readOnlyReason))
        let locked = Harness()
        locked.locked = true
        #expect(await locked.launcher.begin(session: try #require(locked.session), target: target(), local: 4406, present: { _ in }) == .busy)
        let prod = Harness(.production)
        var presented: ConfirmRequest?
        #expect(await prod.launcher.begin(session: try #require(prod.session), target: target(), local: 4406, present: { presented = $0 }) == .confirming)
        #expect(prod.started.isEmpty)
        try await #require(presented).action()
        #expect(prod.started.first?.1 == 4406)
    }

    // MARK: Router hook

    @Test func theRouterGoesThroughTheHookWhenOneIsSetAndThroughTheSheetOtherwise() {
        let router = AppRouter()
        let ref = service()
        var calls: [(Int?, Bool)] = []
        router.forward(ref)
        #expect(router.sheet?.route == .portForward(ref))          // iOS-style: the old sheet
        router.sheet = nil
        router.portForwardStarter = { _, port, configure in calls.append((port, configure)) }
        router.forward(ref, port: 3306)
        router.forward(ref, configure: true)
        #expect(router.sheet == nil)
        #expect(calls.count == 2 && calls[0].0 == 3306 && !calls[0].1 && calls[1].1)
    }

    // MARK: Detail and list state

    @Test func theIndexReflectsAStartedAndAStoppedForwardForAnObject() async {
        let h = Harness()
        await h.launcher.forward(service(), port: 3306, configure: false)
        #expect(ForwardIndex(h.live).isForwarding(service(), remotePort: 3306))
        #expect(ForwardIndex(h.live).entries(for: service("other")).isEmpty)
        h.live[0].state = .stopped
        #expect(!ForwardIndex(h.live).isForwarding(service(), remotePort: 3306))
    }

}
