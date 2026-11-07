import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S13 — interactive shell in a pod container. Named `ExecTerminalView` to avoid clashing with SwiftTerm's `TerminalView`.
struct ExecTerminalView: View {
    let pod: ResourceRef
    var container: String?

    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @State private var model: ShellModel?
    @State private var confirm: ConfirmRequest?
    @State private var customShell = ""
    @State private var showCustomShell = false
    @State private var copied = false
    private let hub = SessionsHub.shared

    private var session: ClusterSession? { registry.session(for: pod.clusterID) }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                EmptyState(.empty(title: "Cluster Not Found", systemImage: "server.rack", hint: "This cluster was removed. Pick another from the Fleet."))
            }
        }
        .navigationTitle(model?.title ?? "Shell")
        .whInlineNavigationTitle()
        .whToolbarColorSchemeDark()
        .whToolbarBackground(Palette.terminalBackground)
        .confirmSheet($confirm)
        .alert("Custom Command", isPresented: $showCustomShell) {
            TextField("/bin/zsh -l", text: $customShell).whNoAutocapitalization().autocorrectionDisabled()
            Button("Run") { let c = customShell.trimmingCharacters(in: .whitespaces); if !c.isEmpty { model?.setShell(.custom(c)) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Runs instead of the shell. Arguments are split on spaces; use quotes for spaces inside one argument.") }
        .task(id: pod) { await start() }
    }

    // MARK: Start

    private func start() async {
        guard let session else { return }
        if let existing = hub.existingShell(for: pod, container: container) { model = existing; return }
        let m = ShellModel(pod: pod, container: container, session: session)
        hub.register(m)
        model = m
        // Never auto-connect: opening this screen (including from a deep link) only shows the "Connect to…" card.
        m.awaitConfirmation()
    }

    /// The Connect button. Production clusters show the confirmation sheet (warning, facts, access review) with a plain button.
    private func connectTapped(_ m: ShellModel, session: ClusterSession) {
        if session.config.isProduction && !session.config.isDemo {
            requestProductionConfirmation(m, session: session)
        } else {
            Task { await m.prepareAndConnect() }
        }
    }

    /// Production: dry-run is an access review for `pods/exec`; confirmation is a button, not typing.
    private func requestProductionConfirmation(_ m: ShellModel, session: ClusterSession) {
        let ns = pod.namespace ?? "default"
        m.awaitConfirmation()
        confirm = ConfirmRequest(
            title: "Open Shell",
            message: "You are about to open an interactive shell inside a container on a production cluster. Commands you run affect live workloads.",
            verb: "Open Shell",
            cluster: session.config,
            namespace: ns,
            resource: "pod/\(pod.name)",
            confirmationText: pod.name,
            facts: [.init("Container", container ?? "default"), .init("Shell", m.shell.title)],
            isDisruptive: true,
            typeToConfirmOnProduction: false,
            dryRun: {
                switch await SessionAccessCheck.canCreate(session.client, namespace: ns, pod: pod.name, subresource: "exec") {
                case .allowed: return .passed("Access review: you can create pods/exec here.")
                case .denied(let why): return .failed(why)
                case .unknown(let why): return .passed("Could not verify access (\(why)); the API server decides on connect.")
                }
            },
            action: { await m.prepareAndConnect() }
        )
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ session: ClusterSession) -> some View {
        if let model {
            ZStack {
                Palette.terminalBackground.ignoresSafeArea()
                VStack(spacing: 0) {
                    ContextLine(cluster: session.config, namespace: pod.namespace, kind: "pod/\(pod.name)")
                        .padding(.horizontal, Spacing.l).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                        .environment(\.colorScheme, .dark)
                    switch model.phase {
                    case .unavailable(let reason):
                        unavailable(reason, model: model).environment(\.colorScheme, .dark)
                    case .awaitingConfirmation:
                        connectPrompt(model, session: session)
                    default:
                        TerminalSurfaceHost(surface: model.surface)
                            .accessibilityLabel("Terminal for \(pod.name)")
                    }
                }
                overlay(model)
            }
            .toolbar { toolbar(model) }
            .onChange(of: model.phase) { _, phase in if phase == .connected { model.surface.focus() } }
            .onDisappear { model.surface.blur() }
            .environment(\.colorScheme, .dark)
            .background { shortcuts(model) }
        } else {
            ZStack { Palette.terminalBackground.ignoresSafeArea(); ProgressView().tint(.white) }
        }
    }

    @ViewBuilder
    private func overlay(_ model: ShellModel) -> some View {
        switch model.phase {
        case .awaitingConfirmation:
            EmptyView()
        case .preparing:
            VStack { Spacer(); statusCard("Checking container…", symbol: "magnifyingglass", spinner: true, actions: {}) }
        case .connecting:
            VStack { Spacer(); statusCard("Connecting to \(model.container ?? "container")…", symbol: "bolt.horizontal", spinner: true, actions: {}) }
        case .ended(let exit, let message):
            VStack { Spacer(); statusCard(exit.map { "Session ended (exit \($0))" } ?? (message ?? "Session ended"), symbol: "xmark.circle", spinner: false, actions: {
                Button("Reconnect") { model.reconnect() }.buttonStyle(.glassProminent)
                Button("Close", role: .cancel) { hub.close(model) }.buttonStyle(.glass)
            }) }
        case .disconnected(let reason):
            VStack { Spacer(); statusCard(reason ?? "Disconnected. iOS suspends network connections when Wheelhouse is in the background.", symbol: "wifi.slash", spinner: false, actions: {
                Button("Reconnect") { model.reconnect() }.buttonStyle(.glassProminent)
                Button("Close", role: .cancel) { hub.close(model) }.buttonStyle(.glass)
            }) }
        case .connected, .unavailable:
            EmptyView()
        }
    }

    /// Shown instead of the terminal until the user explicitly connects.
    private func connectPrompt(_ model: ShellModel, session: ClusterSession) -> some View {
        let name = model.container ?? container
        let isProduction = session.config.isProduction && !session.config.isDemo
        return ScrollView {
            VStack(spacing: Spacing.l) {
                Image(systemName: "apple.terminal").font(.system(size: 44)).foregroundStyle(.secondary).accessibilityHidden(true)
                Text("Connect to \(name ?? "the default container") in \(pod.name) on \(session.config.name)")
                    .font(.headline).multilineTextAlignment(.center)
                ContextLine(cluster: session.config, namespace: pod.namespace, kind: "pod/\(pod.name)")
                Text(isProduction
                     ? "This opens an interactive shell on a production cluster. You will be asked to confirm before connecting."
                     : "This opens an interactive shell inside the container. Commands you run affect the running workload.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button { connectTapped(model, session: session) } label: {
                    Text(isProduction ? "Connect…" : "Connect").frame(maxWidth: 280)
                }
                .buttonStyle(.glassProminent).controlSize(.large)
                .accessibilityIdentifier("shell-connect")
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity)
        }
    }

    private func statusCard<A: View>(_ text: String, symbol: String, spinner: Bool, @ViewBuilder actions: () -> A) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if spinner { ProgressView() } else { Image(systemName: symbol).foregroundStyle(.secondary) }
                Text(text).font(.subheadline).multilineTextAlignment(.leading)
            }
            HStack(spacing: 10) { actions() }
        }
        .padding(Spacing.l)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .padding(Spacing.l)
        .accessibilityElement(children: .contain)
    }

    // MARK: Unavailable

    @ViewBuilder
    private func unavailable(_ reason: ShellModel.Unavailable, model: ShellModel) -> some View {
        switch reason {
        case .demo:
            EmptyState(.empty(title: "Shells Need a Live Cluster", systemImage: "apple.terminal",
                              hint: "Demo mode uses sample data, so there is no container to attach to. Add a real cluster to open a shell; logs work in Demo mode."))
        case .readOnly:
            EmptyState(.empty(title: "Shell Blocked on Read-Only Cluster", systemImage: "lock.fill",
                              hint: "A shell can change anything inside the container, so read-only clusters refuse it. Turn on “Allow exec and port-forward in read-only” in the cluster’s settings to override.")) {
                EmptyView()
            }
        case .forbidden(let message):
            EmptyState(.forbidden(verb: "create", resource: "pods/exec", namespace: pod.namespace, message: message))
        case .failed(let message):
            EmptyState(.error(message: message)) { Button("Try Again") { Task { await model.prepareAndConnect() } } }
        case .notRunning(let name, let state, let siblings):
            EmptyState(.empty(title: "Can’t Open a Shell", systemImage: "exclamationmark.triangle",
                              hint: "Container “\(name)” is \(state). A shell needs a running container.\(siblings.isEmpty ? "" : " Another replica is ready.")")) {
                VStack(spacing: 8) {
                    if let sibling = siblings.first {
                        Button("Open Shell in \(sibling)") { router.push(.shell(model.openSibling(sibling), container: nil)) }.buttonStyle(.glassProminent)
                    }
                    Button("Check Again") { Task { await model.prepareAndConnect() } }.buttonStyle(.glass)
                }
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(_ model: ShellModel) -> some ToolbarContent {
        ToolbarItem(placement: .whTrailing) {
            Button {
                if model.surface.hasFocus { model.surface.blur() } else { model.surface.focus() }
            } label: { Image(systemName: "keyboard") }
            .accessibilityLabel("Toggle keyboard")
        }
        ToolbarItem(placement: .whTrailing) {
            Menu {
                Section("Shell") {
                    ForEach(ShellChoice.standard) { choice in
                        Button { model.setShell(choice) } label: { Label(choice.title, systemImage: model.shell == choice ? "checkmark" : "") }
                    }
                    Button { showCustomShell = true } label: { Label("Custom command…", systemImage: "text.cursor") }
                }
                if model.containers.count > 1 {
                    Section("Container") {
                        ForEach(model.containers, id: \.self) { name in
                            Button { model.setContainer(name) } label: { Label(name, systemImage: model.container == name ? "checkmark" : "") }
                        }
                    }
                }
                Section {
                    Button { Pasteboard.copy(model.surface.allText()); copied = true } label: { Label("Copy All Output", systemImage: "doc.on.doc") }
                    Menu("Font Size", systemImage: "textformat.size") {
                        Button("Larger", systemImage: "plus") { model.surface.fontSize += 1 }
                        Button("Smaller", systemImage: "minus") { model.surface.fontSize -= 1 }
                    }
                    Button { model.surface.clearScreen() } label: { Label("Clear Screen", systemImage: "eraser") }
                    Button { model.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
                    Button { newSession(model) } label: { Label("New Session in This Container", systemImage: "plus.rectangle.on.rectangle") }
                }
                Section {
                    Button(role: .destructive) { hub.close(model); self.model = nil; popIfPossible() } label: { Label("Close Session", systemImage: "xmark.circle") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Shell options")
        }
    }

    private func popIfPossible() {
        if router.isCompact {
            if router.selectedTab == .sessions, !router.sessionsPath.isEmpty { router.sessionsPath.removeLast() }
            else if router.selectedTab == .fleet, !router.fleetPath.isEmpty { router.fleetPath.removeLast() }
            else if router.selectedTab == .cluster, !router.clusterPath.isEmpty { router.clusterPath.removeLast() }
            else if router.selectedTab == .resources, !router.resourcesPath.isEmpty { router.resourcesPath.removeLast() }
            else if router.selectedTab == .search, !router.searchPath.isEmpty { router.searchPath.removeLast() }
        } else if !router.detailPath.isEmpty { router.detailPath.removeLast() }
    }

    private func newSession(_ current: ShellModel) {
        guard let session else { return }
        let m = ShellModel(pod: pod, container: current.container, session: session)
        m.shell = current.shell
        hub.register(m)
        model = m
        connectTapped(m, session: session)
    }

    /// iPad keyboard shortcuts that are not terminal input: ⌘K clear is on the surface; ⌘W closes the session.
    @ViewBuilder
    private func shortcuts(_ model: ShellModel) -> some View {
        Button("Close Session") { hub.close(model); self.model = nil; popIfPossible() }
            .keyboardShortcut("w", modifiers: .command).hidden()
    }
}
