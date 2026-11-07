import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// A selectable remote port.
struct ForwardPortOption: Identifiable, Hashable {
    var port: Int
    var name: String?
    var detail: String?
    var id: Int { port }
    var title: String { [String(port), name].compactMap { $0 }.joined(separator: " · ") }
}

/// S24 "New Port Forward" sheet: pick the remote port and a local port, start, then open the in-app browser or copy the address.
struct PortForwardSetupView: View {
    let target: ResourceRef
    /// Called instead of `router.dismissSheet()` when embedded in another sheet.
    var onDone: (() -> Void)?

    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @State private var options: [ForwardPortOption] = []
    @State private var phase: Phase = .loading
    @State private var remotePort: Int?
    @State private var customRemote = ""
    @State private var useCustomRemote = false
    @State private var manualLocal = false
    @State private var localText = ""
    @State private var backingNote: BackingNote?
    @State private var startError: String?
    @State private var starting = false
    @State private var startedID: UUID?
    @State private var browserFor: PortForwardInfo?
    @State private var confirm: ConfirmRequest?
    @State private var copied = false
    private let hub = SessionsHub.shared

    enum Phase: Equatable { case loading, ready, unsupportedKind, failed(String) }
    struct BackingNote: Equatable { var ok: Bool; var text: String }

    private var session: ClusterSession? { registry.session(for: target.clusterID) }
    private var isService: Bool { target.kind == .service }
    private var effectiveRemote: Int? { useCustomRemote ? Int(customRemote) : remotePort }
    private var suggestedLocal: Int { LocalPort.suggest(preferred: effectiveRemote ?? 8080, excluding: Set(hub.forwards.filter { $0.state.isLive }.map(\.localPort))) }
    private var started: PortForwardInfo? { startedID.flatMap { hub.forward(id: $0) } }

    var body: some View {
        Group {
            if let session { content(session) } else { EmptyState(.empty(title: "Cluster Not Found", systemImage: "server.rack", hint: "This cluster was removed.")) }
        }
        .navigationTitle("Port Forward")
        .whInlineNavigationTitle()
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } } }
        .confirmSheet($confirm)
        .sheet(item: $browserFor) { PortForwardBrowserView(forward: $0) }
        .task(id: target) { await load() }
    }

    private func finish() { if let onDone { onDone() } else { router.dismissSheet() } }

    // MARK: Content

    @ViewBuilder
    private func content(_ session: ClusterSession) -> some View {
        let config = session.config
        if config.isDemo {
            EmptyState(.empty(title: "Port Forwarding Needs a Live Cluster", systemImage: "arrow.left.arrow.right",
                              hint: "Demo mode has no real pods to tunnel to. Add a cluster to forward ports; the in-app browser then opens http://127.0.0.1:<port>."))
        } else if config.readOnly && !config.allowExecInReadOnly {
            EmptyState(.empty(title: "Blocked on Read-Only Cluster", systemImage: "lock.fill",
                              hint: "Port-forwarding can reach anything the pod can. Turn on “Allow exec and port-forward in read-only” in the cluster’s settings to override."))
        } else {
            switch phase {
            case .loading: EmptyState(.loading)
            case .unsupportedKind:
                EmptyState(.empty(title: "Can’t Forward to a \(target.kind.displayName)", systemImage: "arrow.left.arrow.right", hint: "Port-forwards target pods and services. Open one of the workload’s pods instead."))
            case .failed(let message):
                EmptyState(.error(message: message)) { Button("Try Again") { Task { await load() } } }
            case .ready: form(config)
            }
        }
    }

    private func form(_ config: ClusterConfig) -> some View {
        Form {
            Section {
                ContextLine(cluster: config, namespace: target.namespace, kind: "\(target.kind.displayName.lowercased())/\(target.name)")
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets())
            }
            if let started {
                runningSection(started)
            } else {
                Section {
                    if options.isEmpty {
                        Text("No declared ports. Enter the port your app listens on.").font(.footnote).foregroundStyle(.secondary)
                    } else {
                        ForEach(options) { option in
                            Button {
                                useCustomRemote = false
                                remotePort = option.port
                                if !manualLocal { localText = "" }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(option.title).font(.body.monospaced())
                                        if let d = option.detail { Text(d).font(.footnote).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    if !useCustomRemote, remotePort == option.port { Image(systemName: "checkmark").foregroundStyle(Palette.tint) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(!useCustomRemote && remotePort == option.port ? .isSelected : [])
                        }
                    }
                    Toggle("Other port", isOn: $useCustomRemote.animation())
                    if useCustomRemote {
                        TextField("Port number", text: $customRemote).whKeyboard(.number).font(.body.monospaced())
                    }
                } header: { Text(isService ? "Service port" : "Container port") } footer: {
                    if let note = backingNote {
                        Label(note.text, systemImage: note.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(note.ok ? Palette.healthyText : Palette.warningText).font(.footnote)
                    }
                }

                Section {
                    Toggle("Choose local port", isOn: $manualLocal.animation())
                    if manualLocal {
                        TextField("1024–65535", text: $localText).whKeyboard(.number).font(.body.monospaced())
                        if let problem = localPortProblem { Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.criticalText) }
                    } else {
                        LabeledContent("Local port") { Text(verbatim: "\(suggestedLocal) (auto)").font(.body.monospaced()) }
                    }
                } header: { Text("On this device") } footer: {
                    Text("Listens on 127.0.0.1 only; other devices can’t connect. Forwards pause when Wheelhouse is in the background and reconnect when you return.")
                }

                if let startError {
                    Section { Label(startError, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText).font(.footnote) }
                }

                Section {
                    Button {
                        Task { await begin() }
                    } label: {
                        HStack { Spacer(); if starting { ProgressView() } else { Label("Start Forwarding", systemImage: "arrow.left.arrow.right").font(.body.weight(.semibold)) }; Spacer() }
                    }
                    .disabled(!canStart || starting)
                }
            }
        }
    }

    // MARK: Running

    @ViewBuilder
    private func runningSection(_ info: PortForwardInfo) -> some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.target.title).font(.body.monospaced().weight(.semibold))
                    Text("→ \(info.url?.absoluteString ?? info.localAddress)").font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                ForwardStatePill(state: info.state)
            }
            LabeledContent("Traffic") { Text("↓ \(SessionsHub.bytes(info.bytesDown))   ↑ \(SessionsHub.bytes(info.bytesUp))").font(.footnote.monospacedDigit()) }
            if let pod = info.resolvedPod { LabeledContent("Pod") { Text(pod).font(.footnote.monospaced()).lineLimit(1) } }
            if let err = info.lastError { Label(err, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warningText) }
        } header: { Text("Forwarding") }
        Section {
            Button { browserFor = info } label: { Label("Open in Browser", systemImage: "globe") }
            Button {
                Pasteboard.copy(info.url?.absoluteString ?? "http://\(info.localAddress)", localOnly: true)
                copied = true
            } label: { Label(copied ? "Copied" : String("Copy http://127.0.0.1:\(info.localPort)"), systemImage: copied ? "checkmark" : "doc.on.doc") }
            Button(role: .destructive) { hub.stopForward(info.id); startedID = nil } label: { Label("Stop Forwarding", systemImage: "stop.circle") }
        }
    }

    // MARK: Logic

    private var localPortProblem: String? {
        guard manualLocal else { return nil }
        guard let p = Int(localText), (1024...65535).contains(p) else { return localText.isEmpty ? nil : "Enter a port between 1024 and 65535." }
        if hub.forwards.contains(where: { $0.state.isLive && $0.localPort == p }) { return "Another forward already uses this port." }
        if !LocalPort.isFree(p) { return "Port \(p) is in use on this device." }
        return nil
    }

    private var canStart: Bool {
        guard let remote = effectiveRemote, (1...65535).contains(remote) else { return false }
        if manualLocal { return Int(localText) != nil && localPortProblem == nil }
        return true
    }

    private func load() async {
        guard let session else { return }
        phase = .loading
        guard let ns = target.namespace else { phase = .failed("This object has no namespace."); return }
        do {
            switch target.kind {
            case .pod:
                let pod = try await session.client.get(Pod.self, name: target.name, namespace: ns)
                var seen = Set<Int>()
                options = pod.spec.containers.flatMap { c in c.ports.compactMap { p -> ForwardPortOption? in
                    guard (p.protocol ?? "TCP") == "TCP", seen.insert(p.containerPort).inserted else { return nil }
                    return ForwardPortOption(port: p.containerPort, name: p.name, detail: "container \(c.name)")
                } }
                if pod.status?.phase != "Running" { backingNote = BackingNote(ok: false, text: "Pod is \(pod.status?.phase ?? "not running"); the tunnel needs a running container.") }
            case .service:
                let svc = try await session.client.get(Service.self, name: target.name, namespace: ns)
                options = svc.spec.ports.filter { ($0.protocol ?? "TCP") == "TCP" }.map { port in
                    ForwardPortOption(port: port.port, name: port.name, detail: Self.targetPortText(port.targetPort).map { "target port \($0)" })
                }
                do {
                    let ep = try await PortForwardResolver(client: session.client).resolve(
                        PortForwardTarget(kind: .service, namespace: ns, name: target.name, remotePort: options.first?.port ?? 80))
                    backingNote = BackingNote(ok: true, text: "Backed by \(ep.pod). Re-resolves if the pod changes.")
                } catch let e as PortForwardError {
                    backingNote = BackingNote(ok: false, text: e.localizedDescription)
                } catch {}
            default:
                phase = .unsupportedKind; return
            }
            remotePort = options.first?.port
            if options.isEmpty { useCustomRemote = true }
            phase = .ready
        } catch let e as KubeError {
            phase = .failed(e.summary)
        } catch { phase = .failed(error.localizedDescription) }
    }

    private static func targetPortText(_ value: JSONValue?) -> String? {
        switch value {
        case .int(let n)?: "→ \(n)"
        case .string(let s)?: "→ \(s)"
        default: nil
        }
    }

    private func begin() async {
        guard let session, let ns = target.namespace, let remote = effectiveRemote else { return }
        let ft = PortForwardTarget(kind: isService ? .service : .pod, namespace: ns, name: target.name, remotePort: remote)
        let local = manualLocal ? (Int(localText) ?? 0) : suggestedLocal
        if session.config.isProduction {
            confirm = ConfirmRequest(
                title: "Start Port Forward",
                message: "This opens a tunnel from this device into a production cluster. Anything listening on the remote port becomes reachable at 127.0.0.1:\(local).",
                verb: "Start Forwarding", cluster: session.config, namespace: ns, resource: ft.title, confirmationText: target.name,
                facts: [.init("Local address", "127.0.0.1:\(local)")], isDisruptive: true,
                dryRun: {
                    let podName = isService ? nil : target.name
                    switch await SessionAccessCheck.canCreate(session.client, namespace: ns, pod: podName, subresource: "portforward") {
                    case .allowed: return .passed("Access review: you can create pods/portforward here.")
                    case .denied(let why): return .failed(why)
                    case .unknown(let why): return .passed("Could not verify access (\(why)).")
                    }
                },
                action: { try await run(session: session, target: ft, local: local) })
        } else {
            starting = true
            defer { starting = false }
            try? await run(session: session, target: ft, local: local)
        }
    }

    private func run(session: ClusterSession, target: PortForwardTarget, local: Int) async throws {
        startError = nil
        do {
            let info = try await hub.startForward(session: session, target: target, localPort: local)
            startedID = info.id
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            startError = message
            throw error
        }
    }
}

/// Coloured state pill for a forward.
struct ForwardStatePill: View {
    let state: PortForwardState
    var body: some View {
        switch state {
        case .active: StatusPill(tone: .healthy, text: "Active", symbol: "circle.fill")
        case .starting: StatusPill(tone: .info, text: "Starting")
        case .reconnecting: StatusPill(tone: .warning, text: "Reconnecting", symbol: "arrow.triangle.2.circlepath")
        case .suspended: StatusPill(tone: .unknown, text: "Suspended", symbol: "pause.fill")
        case .failed: StatusPill(tone: .critical, text: "Failed", symbol: "exclamationmark.triangle.fill")
        case .stopped: StatusPill(tone: .unknown, text: "Stopped")
        }
    }
}

