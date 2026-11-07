import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S9–S11, S17, S19–S23: detail for any object — header, actions, kind-specific sections, owners, labels, events.
struct ResourceDetailView: View {
    @Environment(ClusterRegistry.self) private var registry
    let ref: ResourceRef

    var body: some View {
        if let key = registry.screenKey(for: ref.clusterID), let session = registry.session(for: ref.clusterID) {
            DetailScreen(session: session, ref: ref).id("\(ref.id)|\(key)")
        } else {
            EmptyState(.empty(title: "Cluster Not Found", systemImage: "server.rack"))
        }
    }
}

private struct DetailScreen: View {
    let session: ClusterSession
    let ref: ResourceRef
    @Environment(AppRouter.self) private var router
    @State private var host: ActionHost
    @State private var fetched: Unstructured?
    @State private var loadError: KubeError?
    @State private var notFound = false

    init(session: ClusterSession, ref: ResourceRef) {
        self.session = session
        self.ref = ref
        _host = State(initialValue: ActionHost(session: session))
    }

    /// Secrets never go through a namespace-wide watch (their values would be cached for the whole list).
    private var usesStore: Bool { ref.kind != .secret }
    /// Watches only this object (`metadata.name=…`), not the whole kind/namespace.
    private var store: ResourceStore<Unstructured> {
        session.unstructuredStore(kind: ref.kind, namespace: ref.kind.namespaced ? ref.namespace : nil, fieldSelector: "metadata.name=\(ref.name)")
    }
    private var object: Unstructured? {
        if usesStore, let hit = store.items.first(where: { $0.metadata.name == ref.name && (!ref.kind.namespaced || $0.metadata.namespace == ref.namespace) }) { return hit }
        return fetched
    }

    var body: some View {
        Group {
            if let object { content(object) }
            else if let loadError { EmptyState(EmptyStateKind(error: loadError, clusterName: session.config.name)) { Button("Retry") { Task { await fetch() } }.buttonStyle(.borderedProminent) } }
            else if notFound { EmptyState(.empty(title: "\(ref.kind.kind) Not Found", systemImage: ref.kind.symbol, hint: "\(ref.name) may have been deleted.")) }
            else { ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .navigationTitle(ref.kind.kind)
        .whInlineNavigationTitle()
        .toolbar { if let object { toolbar(object) } }
        .task(id: ref.id) { if usesStore { await store.run() } }
        .task(id: ref.id) { await fetch() }
        .onChange(of: store.lastUpdated) { checkDeleted() }
        .refreshable { if usesStore { await store.refresh() }; await fetch() }
        .actionHost(host)
    }

    // MARK: Content

    private func content(_ object: Unstructured) -> some View {
        let ctx = DetailContext(session: session, ref: ref, object: object, host: host)
        let summary = ctx.summary
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                ContextLine(cluster: session.config, namespace: ref.kind.namespaced ? ref.namespace : nil, kind: ref.kind.kind, showsNamespace: ref.kind.namespaced)
                header(ctx, summary)
                GlassActionRow(actions(ctx))
                if let e = loadError { StateBanner(.custom(tone: .warning, symbol: "exclamationmark.triangle.fill", title: "Couldn’t refresh", message: e.summary)) }
                if object.metadata.deletionTimestamp != nil {
                    StateBanner(.custom(tone: .warning, symbol: "trash", title: "Terminating", message: "This object is being deleted\(object.metadata.finalizers.isEmpty ? "." : " and is waiting for finalizers: \(object.metadata.finalizers.joined(separator: ", ")).")"))
                }
                if ref.kind == .pod, let pod = try? object.raw.decode(Pod.self), let d = PodDiagnoser.diagnose(pod) {
                    DiagnosisBanner(d, actionTitle: d.suggestsPreviousLogs ? "Previous logs" : nil) {
                        router.push(.logs(ref, container: d.containerName, previous: true))
                    }
                }
                sections(ctx)
                OwnersCard(ctx: ctx)
                LabelsCard("Labels", pairs: object.metadata.labels)
                LabelsCard("Annotations", pairs: object.metadata.annotations.filter { $0.key != "kubectl.kubernetes.io/last-applied-configuration" }, collapsed: true)
                if ref.kind != .event, ref.kind != .secret || true { EventsCard(ctx: ctx) }
            }
            .padding(Spacing.l)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.groupedBackground)
    }

    private func header(_ ctx: DetailContext, _ s: ResourceSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ref.name).font(ref.kind == .pod ? .system(.title2, design: .monospaced).bold() : .title2.bold()).textSelection(.enabled)
            ViewThatFits(in: .horizontal) {
                badges(ctx, s)
                ScrollView(.horizontal, showsIndicators: false) { badges(ctx, s) }
            }
        }
    }

    private func badges(_ ctx: DetailContext, _ s: ResourceSummary) -> some View {
        HStack(spacing: 8) {
            if !s.statusText.isEmpty { StatusPill(s.status, text: s.statusText) }
            if let r = s.ready, let d = s.desired { Text("\(r)/\(d) ready").font(.footnote.monospacedDigit()).foregroundStyle(.secondary) }
            if s.restarts > 0 { Label("\(s.restarts)", systemImage: "arrow.counterclockwise").font(.footnote).foregroundStyle(Palette.warningText) }
            if let rev = ctx.object.metadata.annotations["deployment.kubernetes.io/revision"] { Text("rev \(rev)").font(.footnote).foregroundStyle(.secondary) }
            if s.isCordoned { FlagBadge("CORDONED", tone: .warning) }
            if ctx.object.bool("spec.paused") == true { FlagBadge("PAUSED", tone: .warning) }
            Text(Format.age(from: ctx.object.metadata.creationTimestamp)).font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func sections(_ ctx: DetailContext) -> some View {
        switch ref.kind.kind {
        case "Pod" where ref.kind.group.isEmpty: PodSections(ctx: ctx)
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet": WorkloadSections(ctx: ctx)
        case "Job": JobSections(ctx: ctx)
        case "CronJob": CronJobSections(ctx: ctx)
        case "Service": ServiceSections(ctx: ctx)
        case "Ingress": IngressSections(ctx: ctx)
        case "NetworkPolicy": NetworkPolicySections(ctx: ctx)
        case "Node": NodeSections(ctx: ctx)
        case "ConfigMap": ConfigMapSections(ctx: ctx)
        case "Secret": SecretSections(ctx: ctx)
        case "PersistentVolumeClaim": PVCSections(ctx: ctx)
        case "PersistentVolume": PVSections(ctx: ctx)
        case "Role", "ClusterRole": RoleSections(ctx: ctx)
        case "RoleBinding", "ClusterRoleBinding": BindingSections(ctx: ctx)
        default: GenericSections(ctx: ctx)
        }
    }

    // MARK: Actions

    private func actions(_ ctx: DetailContext) -> [GlassAction] {
        let t = ctx.target
        var a: [GlassAction] = []
        let mutable = host.canMutate
        func yaml() -> GlassAction { GlassAction("YAML", symbol: "curlybraces") { router.push(.yaml(ref)) } }
        func logs() -> GlassAction { GlassAction("Logs", symbol: "text.alignleft") { openWorkloadLogs(ctx) } }
        switch ref.kind.kind {
        case "Pod" where ref.kind.group.isEmpty:
            a.append(logs())
            let running = ctx.summary.status == .healthy && !ctx.summary.isCordoned && (ctx.summary.statusText == "Running")
            if !session.config.readOnly || session.config.allowExecInReadOnly { a.append(GlassAction("Shell", symbol: "apple.terminal", isEnabled: running) { router.push(.shell(ref, container: nil)) }) }
            if !session.config.readOnly || session.config.allowExecInReadOnly { a.append(GlassAction("Forward", symbol: "arrow.left.arrow.right") { router.push(.portForward(ref)) }) }
            a.append(yaml())
            if mutable { a.append(GlassAction("Delete", symbol: "trash", role: .destructive) { host.delete(t) }) }
        case "Deployment":
            if mutable { a += [GlassAction("Scale", symbol: "plusminus") { host.scale(t) }, GlassAction("Restart", symbol: "arrow.triangle.2.circlepath") { host.restart(t) }, GlassAction("Rollback", symbol: "arrow.uturn.backward") { host.rollback(t) }] }
            a += [logs(), yaml()]
        case "StatefulSet":
            if mutable { a += [GlassAction("Scale", symbol: "plusminus") { host.scale(t) }, GlassAction("Restart", symbol: "arrow.triangle.2.circlepath") { host.restart(t) }] }
            a += [logs(), yaml()]
        case "DaemonSet":
            if mutable { a.append(GlassAction("Restart", symbol: "arrow.triangle.2.circlepath") { host.restart(t) }) }
            a += [logs(), yaml()]
        case "ReplicaSet":
            if mutable { a.append(GlassAction("Scale", symbol: "plusminus") { host.scale(t) }) }
            a += [logs(), yaml()]
        case "Job":
            a += [logs(), yaml()]
            if mutable { a.append(GlassAction("Delete", symbol: "trash", role: .destructive) { host.delete(t) }) }
        case "CronJob":
            if mutable {
                a += [GlassAction(t.isSuspended ? "Resume" : "Suspend", symbol: t.isSuspended ? "play.circle" : "pause.circle") { host.suspend(t) },
                      GlassAction("Trigger now", symbol: "play.fill") { host.trigger(t) }]
            }
            a.append(yaml())
        case "Node":
            if mutable { a += [GlassAction(t.isCordoned ? "Uncordon" : "Cordon", symbol: t.isCordoned ? "play.circle" : "nosign") { host.cordon(t) }, GlassAction("Drain", symbol: "arrow.down.to.line") { host.drain(t) }] }
            a.append(yaml())
        case "Service":
            if !session.config.readOnly || session.config.allowExecInReadOnly { a.append(GlassAction("Forward", symbol: "arrow.left.arrow.right") { router.push(.portForward(ref)) }) }
            a.append(yaml())
        default:
            a.append(yaml())
            if mutable, ref.kind != .event { a.append(GlassAction("Delete", symbol: "trash", role: .destructive) { host.delete(t) }) }
        }
        return a
    }

    @ToolbarContentBuilder private func toolbar(_ object: Unstructured) -> some ToolbarContent {
        ToolbarItem(placement: .whTrailing) {
            Menu {
                Button { Pasteboard.copy(ref.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
                if ref.kind != .secret { Button { Pasteboard.copy(ResourceExport.yaml(object.raw)) } label: { Label("Copy YAML", systemImage: "doc.on.clipboard") } }
                Button { router.push(.yaml(ref)) } label: { Label("View YAML", systemImage: "curlybraces") }
                if ref.kind.kind == "Deployment", host.canMutate {
                    let t = ResourceTarget(kind: ref.kind, object: object)
                    Button { host.pauseRollout(t) } label: { Label(t.isPaused ? "Resume Rollout" : "Pause Rollout", systemImage: t.isPaused ? "play.circle" : "pause.circle") }
                }
                if ref.kind == .service || ref.kind == .pod, !session.config.readOnly || session.config.allowExecInReadOnly {
                    Button { router.push(.portForward(ref)) } label: { Label("Port-forward…", systemImage: "arrow.left.arrow.right") }
                }
                if host.canMutate, ref.kind != .event {
                    Divider()
                    Button(role: .destructive) { host.delete(ResourceTarget(kind: ref.kind, object: object)) } label: { Label("Delete…", systemImage: "trash") }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("More actions")
        }
    }

    /// Logs for a workload: the most interesting pod (not ready first), via the pod logs route.
    private func openWorkloadLogs(_ ctx: DetailContext) {
        // A pod has no selector of its own: open its own logs rather than picking another pod from the namespace.
        if ref.kind == .pod { router.push(.logs(ref, container: nil, previous: false)); return }
        let sel = LabelSelectorSyntax.query(from: ctx.object.raw.value(at: "spec.selector.matchLabels")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
        let pods = session.store(for: Pod.self, namespace: ref.namespace, labelSelector: sel.isEmpty ? nil : sel).items
        let pick = pods.first { !$0.stateSummary().isReady } ?? pods.first
        if let pick { router.push(.logs(ctx.ref(.pod, pick.metadata.name, namespace: pick.metadata.namespace), container: nil, previous: false)) }
        else { host.show(ActionToast(message: "No pods to show logs for.", symbol: "info.circle.fill", tone: .info)) }
    }

    // MARK: Data

    private func fetch() async {
        do {
            fetched = try await session.client.getRaw(ref.kind, name: ref.name, namespace: ref.kind.namespaced ? ref.namespace : nil).asUnstructured
            loadError = nil; notFound = false
        } catch KubeError.notFound {
            notFound = true
            if usesStore, store.items.first(where: { $0.metadata.name == ref.name }) == nil { fetched = nil }
        } catch let e as KubeError {
            if object == nil { loadError = e }
        } catch {}
    }

    private func checkDeleted() {
        guard usesStore, store.phase == .loaded, fetched != nil, store.items.first(where: { $0.metadata.name == ref.name }) == nil else { return }
        Task { await fetch() }
    }
}

private extension JSONValue {
    var asUnstructured: Unstructured { Unstructured(raw: self) }
}
