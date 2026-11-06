import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S24 — tab root: port-forwards, open shells, followed log streams and recent sessions.
struct SessionsView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(\.routeColumn) private var column
    @State private var browserFor: PortForwardInfo?
    @State private var showingNew = false
    @State private var copiedID: UUID?
    private let hub = SessionsHub.shared

    var body: some View {
        List {
            Section {
                StateBanner(.custom(tone: .info, symbol: "moon.zzz", title: "Sessions pause in the background",
                                    message: "iOS suspends apps shortly after you leave. Port-forwards close and re-open when you return, log streams resume where they stopped, and shells ask to reconnect."))
                    .listRowInsets(EdgeInsets(top: 6, leading: Spacing.l, bottom: 6, trailing: Spacing.l)).listRowBackground(Color.clear)
                if registry.isDemoMode {
                    StateBanner(.custom(tone: .warning, symbol: "sparkles", title: "Demo mode",
                                        message: "Logs stream from sample data. Shells and port-forwards need a live cluster."))
                        .listRowInsets(EdgeInsets(top: 0, leading: Spacing.l, bottom: 6, trailing: Spacing.l)).listRowBackground(Color.clear)
                }
            }

            if !hub.hasAnySession && hub.recents.isEmpty {
                Section {
                    EmptyState(.empty(title: "No Active Sessions", systemImage: "apple.terminal.on.rectangle",
                                      hint: "Port-forwards, shells and live logs you start show up here so you can return to them.")) {
                        Button("New Port Forward") { showingNew = true }.buttonStyle(.glassProminent)
                    }
                    .frame(minHeight: 280)
                    .listRowBackground(Color.clear)
                }
            }

            if !hub.forwards.isEmpty {
                Section("Port Forwards") {
                    ForEach(hub.forwards) { forwardRow($0) }
                }
            }
            if !hub.shells.isEmpty {
                Section("Shells") {
                    ForEach(hub.shells) { shellRow($0) }
                }
            }
            if !hub.logModels.isEmpty {
                Section("Log Streams") {
                    ForEach(hub.logModels) { logRow($0) }
                }
            }
            if !hub.recents.isEmpty {
                Section {
                    ForEach(hub.recents) { recentRow($0) }
                } header: {
                    HStack { Text("Recent"); Spacer(); Button("Clear") { hub.clearRecents() }.font(.footnote).textCase(nil) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingNew = true } label: { Image(systemName: "plus") }.accessibilityLabel("New port forward")
            }
        }
        .sheet(isPresented: $showingNew) { NewPortForwardPicker() }
        .sheet(item: $browserFor) { PortForwardBrowserView(forward: $0) }
    }

    // MARK: Rows

    private func forwardRow(_ f: PortForwardInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(f.target.title).font(.body.monospaced().weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text(verbatim: "→ localhost:\(f.localPort)").font(.subheadline.monospaced()).foregroundStyle(Palette.tintText)
                }
                Spacer()
                ForwardStatePill(state: f.state)
            }
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let uptime = Format.age(from: f.startedAt, now: f.endedAt ?? ctx.date)
                Text("\(f.clusterName) · ↓ \(SessionsHub.bytes(f.bytesDown)) ↑ \(SessionsHub.bytes(f.bytesUp)) · up \(uptime) · \(f.openConnections) open")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            if let error = f.lastError, f.state.isLive { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warningText).lineLimit(2) }
            HStack(spacing: 8) {
                if f.url != nil, f.state == .active {
                    Button { browserFor = f } label: { Label("Open", systemImage: "globe") }.buttonStyle(.glass)
                }
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: f.url?.absoluteString ?? "http://127.0.0.1:\(f.localPort)"]], options: [.localOnly: true])
                    copiedID = f.id
                } label: { Label(copiedID == f.id ? "Copied" : "Copy", systemImage: copiedID == f.id ? "checkmark" : "doc.on.doc") }.buttonStyle(.glass)
                Spacer()
                Button(role: .destructive) { hub.stopForward(f.id) } label: { Label("Stop", systemImage: "stop.circle") }.buttonStyle(.glass).tint(Palette.critical)
            }
            .controlSize(.small)
            .labelStyle(.titleAndIcon)
        }
        .padding(.vertical, 4)
        .swipeActions { Button("Stop", role: .destructive) { hub.stopForward(f.id) } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Port forward \(f.target.title) to local port \(f.localPort), \(f.state.title)")
    }

    private func shellRow(_ s: ShellModel) -> some View {
        Button {
            hub.resumeShellID = s.id
            router.push(.shell(s.pod, container: s.container), from: column)
        } label: {
            ResourceRow(title: s.pod.name, subtitle: "\(s.container ?? "container") · \(s.shell.shortName) · \(s.clusterSession.config.name)",
                        lead: .symbol("apple.terminal", shellTone(s)), trailing: shellState(s), trailingTone: shellTone(s), monospacedTitle: true)
        }
        .buttonStyle(.plain)
        .swipeActions { Button("Close", role: .destructive) { hub.close(s) } }
        .contextMenu { Button("Close Session", systemImage: "xmark.circle", role: .destructive) { hub.close(s) } }
    }

    private func shellState(_ s: ShellModel) -> String {
        switch s.phase {
        case .connected: "Live"
        case .connecting, .preparing, .awaitingConfirmation: "Opening"
        case .ended: "Ended"
        case .disconnected: "Dropped"
        case .unavailable: "Unavailable"
        }
    }

    private func shellTone(_ s: ShellModel) -> StatusTone {
        switch s.phase {
        case .connected: .healthy
        case .connecting, .preparing, .awaitingConfirmation: .info
        case .disconnected: .warning
        case .ended, .unavailable: .unknown
        }
    }

    private func logRow(_ m: LogsModel) -> some View {
        Button {
            hub.resumeLogsID = m.id
            router.push(.logs(m.pod, container: m.container, previous: m.previous), from: column)
        } label: {
            ResourceRow(title: m.pod.name, subtitle: "\(m.title)\(m.previous ? " · previous" : "") · \(m.stream.count.formatted()) lines · \(m.clusterSession.config.name)",
                        lead: .symbol("text.alignleft", logTone(m)), trailing: logState(m), trailingTone: logTone(m), monospacedTitle: true)
        }
        .buttonStyle(.plain)
        .swipeActions { Button("Stop", role: .destructive) { hub.close(m) } }
        .contextMenu { Button("Stop Stream", systemImage: "stop.circle", role: .destructive) { hub.close(m) } }
    }

    private func logState(_ m: LogsModel) -> String {
        switch m.stream.state {
        case .streaming: "Live"
        case .connecting: "Connecting"
        case .paused: "Paused"
        case .finished: "Ended"
        case .failed: "Failed"
        case .idle: "Idle"
        }
    }

    private func logTone(_ m: LogsModel) -> StatusTone {
        switch m.stream.state {
        case .streaming: .healthy
        case .connecting: .info
        case .paused: .warning
        case .failed: .critical
        case .finished, .idle: .unknown
        }
    }

    private func recentRow(_ r: RecentSession) -> some View {
        Button {
            if let route = r.route { router.push(route, from: column) }
        } label: {
            ResourceRow(title: r.title, subtitle: r.subtitle,
                        lead: .symbol(r.kind == .shell ? "apple.terminal" : r.kind == .logs ? "text.alignleft" : "arrow.left.arrow.right", .unknown),
                        trailing: Format.age(from: r.endedAt), monospacedTitle: true)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New port-forward picker

/// Pick a service or pod in the current cluster/namespace, then continue to ``PortForwardSetupView``.
struct NewPortForwardPicker: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.services
    @State private var search = ""
    enum Mode: String, CaseIterable, Identifiable { case services = "Services", pods = "Pods"; var id: String { rawValue } }

    private static let wellKnown: [String: Int] = ["grafana": 3000, "prometheus": 9090, "argocd-server": 443, "kiali": 20001]

    var body: some View {
        NavigationStack {
            Group {
                if let session = registry.currentSession {
                    if session.config.isDemo {
                        EmptyState(.empty(title: "Port Forwarding Needs a Live Cluster", systemImage: "arrow.left.arrow.right",
                                          hint: "Demo mode has no real pods to tunnel to. Add a cluster to forward ports."))
                    } else {
                        list(session)
                    }
                } else {
                    EmptyState(.empty(title: "No Cluster", systemImage: "server.rack", hint: "Add a cluster first."))
                }
            }
            .navigationTitle("New Port Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func list(_ session: ClusterSession) -> some View {
        let ns = registry.namespace(for: session.id)
        VStack(spacing: 0) {
            ContextLine(cluster: session.config, namespace: ns).padding(.horizontal, Spacing.l).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
            Picker("Kind", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            if mode == .services { ServiceList(session: session, namespace: ns, search: search, dismiss: { dismiss() }) }
            else { PodList(session: session, namespace: ns, search: search, dismiss: { dismiss() }) }
        }
        .searchable(text: $search, prompt: "Filter by name")
    }

    private struct ServiceList: View {
        let session: ClusterSession; let namespace: String?; let search: String; let dismiss: () -> Void
        var body: some View {
            let store = session.store(for: Service.self, namespace: namespace)
            let items = store.items.filter { search.isEmpty || $0.metadata.name.localizedCaseInsensitiveContains(search) }
                .sorted { ($0.metadata.name) < ($1.metadata.name) }
            let suggested = items.filter { NewPortForwardPicker.wellKnown[$0.metadata.name] != nil }
            List {
                if !suggested.isEmpty {
                    Section("Suggested") { ForEach(suggested, id: \.metadata.name) { row($0) } }
                }
                Section(suggested.isEmpty ? "" : "All Services") { ForEach(items, id: \.metadata.name) { row($0) } }
            }
            .overlay { if store.isLoading && store.items.isEmpty { EmptyState(.loading) } else if let e = store.error, store.items.isEmpty { EmptyState(EmptyStateKind(error: e)) } else if items.isEmpty { EmptyState(.empty(title: "No Services", systemImage: "network", hint: "Nothing to forward to in this namespace.")) } }
            .task { await store.run() }
        }

        private func row(_ svc: Service) -> some View {
            let ref = ResourceRef(clusterID: session.id, kind: .service, namespace: svc.metadata.namespace, name: svc.metadata.name)
            return NavigationLink {
                PortForwardSetupView(target: ref, onDone: dismiss)
            } label: {
                ResourceRow(title: svc.metadata.name, subtitle: "\(svc.metadata.namespace ?? "") · " + svc.spec.ports.map { String($0.port) }.joined(separator: ", "),
                            lead: .symbol("network", .info), monospacedTitle: true, showsChevron: false)
            }
        }
    }

    private struct PodList: View {
        let session: ClusterSession; let namespace: String?; let search: String; let dismiss: () -> Void
        var body: some View {
            let store = session.store(for: Pod.self, namespace: namespace)
            let items = store.items.filter { $0.status?.phase == "Running" && (search.isEmpty || $0.metadata.name.localizedCaseInsensitiveContains(search)) }
                .sorted { $0.metadata.name < $1.metadata.name }
            List(items, id: \.metadata.name) { pod in
                let ref = ResourceRef(clusterID: session.id, kind: .pod, namespace: pod.metadata.namespace, name: pod.metadata.name)
                NavigationLink {
                    PortForwardSetupView(target: ref, onDone: dismiss)
                } label: {
                    ResourceRow(title: pod.metadata.name, subtitle: "\(pod.metadata.namespace ?? "") · " + (pod.spec.containers.flatMap(\.ports).map { String($0.containerPort) }.joined(separator: ", ").nonEmpty ?? "no declared ports"),
                                lead: .symbol("cube", .healthy), monospacedTitle: true, showsChevron: false)
                }
            }
            .overlay { if store.isLoading && store.items.isEmpty { EmptyState(.loading) } else if let e = store.error, store.items.isEmpty { EmptyState(EmptyStateKind(error: e)) } else if items.isEmpty { EmptyState(.empty(title: "No Running Pods", systemImage: "cube", hint: "Only running pods can be forwarded to.")) } }
            .task { await store.run() }
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
