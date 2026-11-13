import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Starts port-forwards on the Mac with one click (DESIGN-MAC section 9). One launcher per pane: it owns the pane's confirmation
/// and the brief "Forwarding …" banner, and every entry point (detail buttons, row menus, Compass, the advanced sheet) goes through it.
///
/// Safety is unchanged from the sheet it replaces: a cluster that refuses port-forward still refuses, and Production still asks for a
/// button confirmation (never a typed name, like the pod shell). Only the configuration step is gone.
@MainActor @Observable
final class PortForwardLauncher {
    struct Banner: Identifiable, Equatable {
        let id = UUID()
        var message: String
        /// The forward this banner is about; the banner disappears when it stops.
        var forwardID: UUID?
        var address: String?
        var isError = false
    }

    enum Outcome: Equatable {
        case started(UUID)
        case alreadyForwarding(UUID)
        /// A confirmation was handed to the presenter; nothing started yet.
        case confirming
        /// The advanced form was requested.
        case advanced
        case refused(String)
        case failed(String)
        case busy
    }

    /// Everything the launcher needs from the outside, so tests run it without a cluster.
    struct Seams {
        var session: @MainActor (ClusterID) -> ClusterSession?
        /// The forwardable ports of the object, nil when they can't be read.
        var fetchPorts: @MainActor (ClusterSession, ResourceRef) async -> [ForwardablePort]?
        var start: @MainActor (ClusterSession, PortForwardTarget, Int) async throws -> PortForwardInfo
        var stop: @MainActor (UUID) -> Void
        var liveForwards: @MainActor () -> [PortForwardInfo]
        var isAvailable: @MainActor (Int) -> Bool
        var presentAdvanced: @MainActor (ResourceRef) -> Void
        var openBrowser: @MainActor (URL) -> Void
        /// App Lock is engaged: nothing may be presented or started.
        var isLocked: @MainActor () -> Bool = { false }
    }

    /// Pane-level confirmation (one-click starts on Production).
    var confirm: ConfirmRequest?
    var banner: Banner?
    @ObservationIgnored let seams: Seams
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var bannerTask: Task<Void, Never>?

    init(seams: Seams) { self.seams = seams }

    /// The launcher of a workspace pane.
    static func live(registry: ClusterRegistry, hub: SessionsHub = .shared, isLocked: @escaping @MainActor () -> Bool = { false }, presentAdvanced: @escaping @MainActor (ResourceRef) -> Void) -> PortForwardLauncher {
        PortForwardLauncher(seams: Seams(
            session: { registry.session(for: $0) },
            fetchPorts: { session, ref in
                guard let raw = try? await session.client.getRaw(ref.kind, name: ref.name, namespace: ref.namespace) else { return nil }
                return ForwardablePorts.ports(kind: ref.kind, raw: raw)
            },
            start: { session, target, local in try await hub.startForward(session: session, target: target, localPort: local) },
            stop: { hub.stopForward($0) },
            liveForwards: { hub.forwards },
            isAvailable: { LocalPort.isAvailable($0) },
            presentAdvanced: presentAdvanced,
            openBrowser: { NSWorkspace.shared.open($0) },
            isLocked: isLocked))
    }

    // MARK: Entry point

    /// One click. `port` nil asks the object for its ports: exactly one starts at once, otherwise the advanced form chooses.
    @discardableResult
    func forward(_ ref: ResourceRef, port: Int?, configure: Bool) async -> Outcome {
        guard ref.kind == .service || ref.kind == .pod, let namespace = ref.namespace, let session = seams.session(ref.clusterID) else {
            return fail("This object can’t be forwarded.")
        }
        if case .refused(let reason) = PortForwardGate.decide(session.config) { return fail(reason, refused: true) }
        if configure { seams.presentAdvanced(ref); return .advanced }
        var remote = port
        if remote == nil {
            let ports = await seams.fetchPorts(session, ref) ?? []
            guard !seams.isLocked() else { return .busy }   // the app locked during the request: present nothing
            guard ports.count == 1, let only = ports.first else { seams.presentAdvanced(ref); return .advanced }
            remote = only.port
        }
        guard let remote else { seams.presentAdvanced(ref); return .advanced }
        let target = PortForwardTarget(kind: ref.kind == .service ? .service : .pod, namespace: namespace, name: ref.name, remotePort: remote)
        let outcome = await begin(session: session, target: target, local: nil, present: { [weak self] in self?.confirm = $0 })
        if case .failed(let message) = outcome { showError(message) }
        return outcome
    }

    /// Starts the forward, or hands the Production confirmation to `present`. Used by `forward` and by the advanced sheet
    /// (which presents the confirmation from inside itself).
    func begin(session passed: ClusterSession, target: PortForwardTarget, local: Int?, present: @MainActor (ConfirmRequest) -> Void) async -> Outcome {
        // Decide on the cluster as configured now (it may have become Production or read-only since the click).
        guard !seams.isLocked() else { return .busy }
        guard let session = seams.session(passed.id) else { return .failed("This cluster was removed.") }
        // One click on something already forwarded just shows it; the advanced form (an explicit local port) may add another.
        if local == nil, let live = liveForward(session.id, target) {
            showStarted(live)
            return .alreadyForwarding(live.id)
        }
        if let local, usedLocalPorts.contains(local) { return .failed("Another forward already uses this port.") }
        if inFlight.contains(Self.key(session.id, target)) { return .busy }   // a double click, or the menu and the button together
        guard let port = local ?? ForwardPlanner.localPort(remote: target.remotePort, used: usedLocalPorts, isAvailable: seams.isAvailable) else {
            return .failed("No free local port was found.")
        }
        let gate = PortForwardGate.decide(session.config)
        if case .refused(let reason) = gate { return .refused(reason) }
        if gate == .allowed(confirmation: true) {
            present(confirmRequest(session: session, target: target, local: port, explicit: local != nil))
            return .confirming
        }
        do {
            return .started(try await startNow(session: session, target: target, local: port, explicit: local != nil).id)
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    /// Re-checks the live cluster configuration, then starts. Throws so a confirmation sheet can show the reason and stay open.
    @discardableResult
    func startNow(session: ClusterSession, target: PortForwardTarget, local: Int, explicit: Bool = false) async throws -> PortForwardInfo {
        // The cluster may have been edited (read-only, removed) since the click: ask again, with the current session.
        guard let current = seams.session(session.id) else { throw LaunchError.message("This cluster was removed.") }
        if case .refused(let reason) = PortForwardGate.decide(current.config) { throw LaunchError.message(reason) }
        // Two confirmations for the same click (a double click on Production): the second finds the first one's forward.
        if !explicit, let live = liveForward(current.id, target) { showStarted(live); return live }
        let key = Self.key(current.id, target)
        guard inFlight.insert(key).inserted else { throw LaunchError.message("That port is already being forwarded.") }
        defer { inFlight.remove(key) }
        let info = try await seams.start(current, target, local)
        showStarted(info)
        return info
    }

    enum LaunchError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
    }

    private static func key(_ cluster: ClusterID, _ target: PortForwardTarget) -> String {
        "\(cluster)|\(target.kind.rawValue)|\(target.namespace)|\(target.name)|\(target.remotePort)"
    }

    static func message(for error: Error) -> String { (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }

    private func liveForward(_ cluster: ClusterID, _ target: PortForwardTarget) -> PortForwardInfo? {
        seams.liveForwards().first { $0.state.isLive && $0.clusterID == cluster && $0.target == target }
    }

    var usedLocalPorts: Set<Int> { Set(seams.liveForwards().filter { $0.state.isLive }.map(\.localPort)) }

    // MARK: Confirmation

    func confirmRequest(session: ClusterSession, target: PortForwardTarget, local: Int, explicit: Bool = false) -> ConfirmRequest {
        let podName = target.kind == .pod ? target.name : nil
        let client = session.client
        ConfirmRequest.portForward(
            title: "Port Forward",
            message: "This opens a tunnel from this Mac into a production cluster. Anything listening on the remote port becomes reachable at 127.0.0.1:\(local).",
            verb: "Forward", cluster: session.config, namespace: target.namespace, resource: target.title, confirmationText: target.name,
            facts: [.init("Local address", "127.0.0.1:\(local)")],
            dryRun: {
                switch await SessionAccessCheck.canCreate(client, namespace: target.namespace, pod: podName, subresource: "portforward") {
                case .allowed: return .passed("Access review: you can create pods/portforward here.")
                case .denied(let why): return .failed(why)
                case .unknown(let why): return .passed("Could not verify access (\(why)).")
                }
            },
            action: { [weak self] in
                guard let self else { throw LaunchError.message("Port forwarding is no longer available in this window.") }
                try await self.startNow(session: session, target: target, local: local, explicit: explicit)
            })
    }

    // MARK: Banner

    func showStarted(_ info: PortForwardInfo) {
        show(Banner(message: "Forwarding \(info.localAddress) → \(info.target.name):\(info.target.remotePort)", forwardID: info.id, address: info.localAddress))
    }

    func showError(_ message: String) { show(Banner(message: message, isError: true)) }

    private func show(_ banner: Banner) {
        self.banner = banner
        bannerTask?.cancel()
        let id = banner.id
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(banner.isError ? 10 : 8))
            if !Task.isCancelled, self?.banner?.id == id { self?.banner = nil }
        }
    }

    func dismissBanner() { banner = nil }

    /// A forward the banner is about is gone from the index: the banner goes with it.
    func forwardsChanged(old: ForwardIndex, new: ForwardIndex) {
        guard let id = banner?.forwardID, old.entries.contains(where: { $0.id == id }), !new.entries.contains(where: { $0.id == id }) else { return }
        banner = nil
    }

    func stop(_ id: UUID) {
        seams.stop(id)
        if banner?.forwardID == id { banner = nil }
    }

    func copy(_ address: String) { Pasteboard.copy(address, localOnly: true) }

    /// App Lock: nothing of the launcher stays on screen.
    func dismissForLock() {
        confirm = nil
        banner = nil
    }

    private func fail(_ message: String, refused: Bool = false) -> Outcome {
        showError(message)
        return refused ? .refused(message) : .failed(message)
    }
}
