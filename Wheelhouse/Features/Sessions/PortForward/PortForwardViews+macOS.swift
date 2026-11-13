import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

extension EnvironmentValues {
    /// The pane's launcher; nil outside a workspace pane.
    @Entry var portForwardLauncher: PortForwardLauncher? = nil
}

/// The Option key is down: "Forward" becomes "Forward…" (the advanced form).
@MainActor
func optionKeyIsDown() -> Bool { NSEvent.modifierFlags.contains(.option) }

// MARK: - Pane presentation

/// Presents a pane's launcher: the Production confirmation and the brief banner. Nothing here is modal except the confirmation.
private struct PortForwardPresentation: ViewModifier {
    @Bindable var launcher: PortForwardLauncher

    func body(content: Content) -> some View {
        content
            .environment(\.portForwardLauncher, launcher)
            .background { Color.clear.confirmSheet($launcher.confirm) }
            .overlay(alignment: .bottom) {
                ZStack {
                    if let banner = launcher.banner {
                        PortForwardBannerView(launcher: launcher, banner: banner)
                            .padding(Spacing.l)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: launcher.banner)
            }
            // A forward stopped anywhere (this banner, a detail, Sessions, a removed cluster) takes its banner with it.
            .onChange(of: SessionsHub.shared.forwardIndex) { old, new in launcher.forwardsChanged(old: old, new: new) }
    }
}

extension View {
    func portForwardPresentation(_ launcher: PortForwardLauncher) -> some View { modifier(PortForwardPresentation(launcher: launcher)) }
}

/// "Forwarding 127.0.0.1:3306 → mariadb:3306" with Copy and Stop.
struct PortForwardBannerView: View {
    let launcher: PortForwardLauncher
    let banner: PortForwardLauncher.Banner

    var body: some View {
        Group {
            HStack(spacing: 10) {
                Image(systemName: banner.isError ? "xmark.octagon.fill" : "arrow.left.arrow.right.circle.fill")
                    .foregroundStyle(banner.isError ? Palette.critical : Palette.healthy)
                Text(banner.message).font(.callout).lineLimit(2).textSelection(.enabled)
                if let address = banner.address, let id = banner.forwardID {
                    Button("Copy") { launcher.copy(address) }.buttonStyle(.borderless)
                    Button("Stop") { launcher.stop(id) }.buttonStyle(.borderless)
                }
                Button { launcher.dismissBanner() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            .shadow(radius: 6, y: 2)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("portforward.banner")
        }
    }
}

extension View {
    /// `PaneHost` attaches the pane's launcher (always present for a live pane router).
    @ViewBuilder func portForwardPane(_ launcher: PortForwardLauncher?) -> some View {
        if let launcher { portForwardPresentation(launcher) } else { self }
    }
}

// MARK: - Detail state

/// The live forwards of a service or pod, on its detail: address, Open in Browser (web ports), Copy Address, Stop.
struct ActiveForwardsCard: View {
    let ref: ResourceRef
    private let hub = SessionsHub.shared

    var body: some View {
        let entries = hub.forwardIndex.entries(for: ref)
        if !entries.isEmpty {
            DetailCard("Port Forwarding", subtitle: "\(entries.count) active") {
                ForEach(entries, id: \.id) { entry in ActiveForwardRow(entry: entry) }
            }
        }
    }
}

private struct ActiveForwardRow: View {
    let entry: ForwardIndex.Entry
    private let hub = SessionsHub.shared
    @Environment(\.portForwardLauncher) private var launcher

    var body: some View {
        let info = hub.forward(id: entry.id)
        let address = "127.0.0.1:\(entry.localPort)"
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(address) → \(entry.remotePort)").font(.whCode).textSelection(.enabled)
                if let pod = info?.resolvedPod { Text("via \(pod)").font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let info { ForwardStatePill(state: info.state) }
            Spacer()
            if ForwardablePort(port: entry.remotePort).isHTTP, let url = info?.url {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }.buttonStyle(.bordered).controlSize(.small)
            }
            Button("Copy Address") { Pasteboard.copy(address, localOnly: true) }.buttonStyle(.bordered).controlSize(.small)
            Button("Stop") { if let launcher { launcher.stop(entry.id) } else { hub.stopForward(entry.id) } }.buttonStyle(.bordered).controlSize(.small)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One service port row's trailing control: a "Forwarding" badge with Stop, or Forward (Option-click opens the advanced form).
struct ServicePortForwardControl: View {
    let ref: ResourceRef
    let port: Int
    let isTCP: Bool
    @Environment(AppRouter.self) private var router
    @Environment(\.portForwardLauncher) private var launcher
    private let hub = SessionsHub.shared

    var body: some View {
        let active = hub.forwardIndex.entries(for: ref).filter { $0.remotePort == port }
        if let entry = active.first {
            HStack(spacing: 8) {
                StatusPill(tone: .healthy, text: "Forwarding", symbol: "arrow.left.arrow.right")
                Button("Stop") { if let launcher { launcher.stop(entry.id) } else { hub.stopForward(entry.id) } }.buttonStyle(.bordered).controlSize(.small)
            }
        } else if isTCP {
            Button("Forward") { router.forward(ref, port: port, configure: optionKeyIsDown()) }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Forward this port. Option-click to choose the local port.")
        }
    }
}

// MARK: - Advanced sheet

/// "Port Forward…": choose the port and the local port. A plain Mac form: standard Cancel and Forward buttons.
struct MacPortForwardSheet: View {
    let target: ResourceRef
    var onDone: (() -> Void)?

    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(\.portForwardLauncher) private var launcher
    @State private var form = PortForwardFormState()
    @State private var phase: Phase = .loading
    @State private var autoLocal: Int?
    @State private var error: String?
    @State private var working = false
    @State private var confirm: ConfirmRequest?
    private let hub = SessionsHub.shared

    enum Phase: Equatable { case loading, ready, failed(String) }

    private var session: ClusterSession? { registry.session(for: target.clusterID) }
    private var used: Set<Int> { Set(hub.forwardIndex.entries.map(\.localPort)) }
    private var kindWord: String { target.kind == .service ? "Service" : "Pod" }

    var body: some View {
        VStack(spacing: 0) {
            Text("Port Forward").font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 16)
            content
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { finish() }.keyboardShortcut(.cancelAction)
                Button { Task { await forward() } } label: { if working { ProgressView().controlSize(.small) } else { Text("Forward") } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canForward)
            }
            .padding(14)
        }
        .frame(width: 440)
        .confirmSheet($confirm)
        .task(id: target) { await load() }
        .onChange(of: form.effectiveRemote) { _, _ in refreshAuto() }
        // Whoever started it (this form, or its confirmation), the form is done once the forward is live.
        .onChange(of: hub.forwardIndex) { _, index in
            if let remote = form.effectiveRemote, index.isForwarding(target, remotePort: remote) { finish() }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, minHeight: 160)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160).padding()
        case .ready:
            form_
        }
    }

    private var form_: some View {
        Form {
            Section {
                if let session { LabeledContent("Cluster") { HStack(spacing: 6) { Text(session.config.name); EnvBadge(session.config.environment) } } }
                if let ns = target.namespace { LabeledContent("Namespace", value: ns) }
                LabeledContent(kindWord) { Text(target.name).font(.whCode).textSelection(.enabled) }
            }
            Section {
                if form.useCustomRemote {
                    TextField("Port", text: $form.customRemote, prompt: Text("Port number"))
                } else {
                    Picker("Port", selection: $form.remotePort) {
                        ForEach(form.options) { Text($0.title).tag(Optional($0.port)) }
                    }
                }
                if !form.options.isEmpty { Toggle("Use another port", isOn: $form.useCustomRemote) }
                TextField("Local port", text: $form.localText, prompt: Text(autoLocal.map { "Automatic (\($0))" } ?? "Automatic"))
                if let problem = form.localProblem(used: used) {
                    Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Palette.criticalText)
                }
            } footer: {
                Text("Listens on 127.0.0.1 only. Other computers can’t connect.")
            }
            if let error {
                Section { Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var canForward: Bool { phase == .ready && !working && form.canForward(used: used) }

    private func finish() { if let onDone { onDone() } else { router.dismissSheet() } }

    private func refreshAuto() {
        autoLocal = form.effectiveRemote.flatMap { ForwardPlanner.localPort(remote: $0, used: used) }
    }

    private func load() async {
        guard let session else { phase = .failed("This cluster was removed."); return }
        if case .refused(let reason) = PortForwardGate.decide(session.config) { phase = .failed(reason); return }
        guard target.kind == .service || target.kind == .pod, target.namespace != nil else { phase = .failed("Port-forwards target pods and services."); return }
        let ports: [ForwardablePort]
        if let launcher, let fetched = await launcher.seams.fetchPorts(session, target) { ports = fetched }
        else if let raw = try? await session.client.getRaw(target.kind, name: target.name, namespace: target.namespace) { ports = ForwardablePorts.ports(kind: target.kind, raw: raw) }
        else { phase = .failed("Couldn’t read this \(kindWord.lowercased()) from the cluster."); return }
        form.load(ports)
        refreshAuto()
        phase = .ready
    }

    private func forward() async {
        guard let launcher else { error = "Port forwarding isn’t available in this window."; return }
        guard let session, let namespace = target.namespace, let remote = form.effectiveRemote,
              let local = form.resolvedLocal(used: used) else { return }
        working = true
        defer { working = false }
        error = nil
        let forwardTarget = PortForwardTarget(kind: target.kind == .service ? .service : .pod, namespace: namespace, name: target.name, remotePort: remote)
        switch await launcher.begin(session: session, target: forwardTarget, local: local, present: { confirm = $0 }) {
        case .started, .alreadyForwarding: finish()
        case .confirming, .advanced, .busy: break
        case .refused(let message), .failed(let message): error = message
        }
    }
}
