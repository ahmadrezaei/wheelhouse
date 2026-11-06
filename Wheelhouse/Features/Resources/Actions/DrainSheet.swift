import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S18: cordon + drain a node with PDB pre-check, options and per-pod progress.
struct DrainSheet: View {
    let host: ActionHost
    let target: ResourceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var options = DrainOptions()
    @State private var graceCustom = false
    @State private var graceSeconds = 30
    @State private var pods: [Pod] = []
    @State private var budgets: [PodDisruptionBudget] = []
    @State private var loadError: KubeError?
    @State private var isLoaded = false
    @State private var confirm: ConfirmRequest?
    @State private var runner: DrainRunner?

    private var plan: DrainPlan { DrainPlanner.plan(node: target.name, pods: pods, budgets: budgets, options: effectiveOptions) }
    private var effectiveOptions: DrainOptions { var o = options; o.gracePeriodSeconds = graceCustom ? graceSeconds : nil; return o }

    var body: some View {
        NavigationStack {
            Group {
                if let runner { DrainProgressView(runner: runner, node: target.name) }
                else if let loadError { EmptyState(EmptyStateKind(error: loadError, clusterName: host.cluster.name)) }
                else if !isLoaded { EmptyState(.loading) }
                else { form }
            }
            .navigationTitle(runner == nil ? "Drain \(target.name)" : "Draining")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ContextLine(cluster: host.cluster, kind: "Node \(target.name)", showsNamespace: false).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(runner?.phase.isRunning == true ? "Cancel Drain" : (runner == nil ? "Cancel" : "Done")) {
                        if runner?.phase.isRunning == true { runner?.cancel() } else { dismiss() }
                    }
                }
                if runner == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Cordon & Drain") { confirm = request() }
                            .buttonStyle(.glassProminent).tint(Palette.critical).disabled(!isLoaded || !plan.canProceed)
                    }
                }
            }
        }
        .confirmSheet($confirm)
        .interactiveDismissDisabled(runner?.phase.isRunning == true)
        .presentationDetents([.large])
        .task { await load() }
        .onDisappear { runner?.cancel() }
    }

    private var form: some View {
        Form {
            Section {
                Text("The node is cordoned first, then each pod is evicted through the Eviction API, which respects PodDisruptionBudgets. Draining continues only while Wheelhouse is open.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Options") {
                Toggle("Ignore DaemonSet pods", isOn: $options.ignoreDaemonSets)
                Toggle("Delete emptyDir data", isOn: $options.deleteEmptyDirData)
                Toggle("Force unmanaged pods", isOn: $options.forceUnmanaged)
                Toggle("Custom grace period", isOn: $graceCustom)
                if graceCustom { Stepper("\(graceSeconds) seconds", value: $graceSeconds, in: 0...600, step: 5) }
                Picker("Timeout", selection: $options.timeout) {
                    Text("2 min").tag(TimeInterval(120)); Text("5 min").tag(TimeInterval(300)); Text("10 min").tag(TimeInterval(600)); Text("30 min").tag(TimeInterval(1800))
                }
            }
            if !plan.blockers.isEmpty {
                Section {
                    ForEach(plan.blockers) { p in
                        Label { VStack(alignment: .leading) { Text(p.name).font(.whCode); Text(blockerText(p)).font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.critical) }
                    }
                } header: { Text("Blocked — adjust options") } footer: { Text("These pods would stop the drain. Enable the matching option above to include them.") }
            }
            let budgetsWaiting = plan.pdbWaiting
            if !budgetsWaiting.isEmpty {
                Section {
                    ForEach(budgetsWaiting) { p in
                        Label { VStack(alignment: .leading) { Text(p.name).font(.whCode); Text("PDB \(p.blockingBudgets.joined(separator: ", ")) allows 0 disruptions — will wait").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "shield.lefthalf.filled").foregroundStyle(Palette.warning) }
                    }
                } header: { Text("PodDisruptionBudget pre-check") }
            }
            Section("Will be evicted (\(plan.toEvict.count))") {
                if plan.toEvict.isEmpty { Text("No pods to evict.").foregroundStyle(.secondary) }
                ForEach(plan.toEvict) { p in
                    VStack(alignment: .leading) {
                        Text(p.name).font(.whCode).lineLimit(1).truncationMode(.middle)
                        Text([p.namespace, p.controller ?? "unmanaged", p.usesEmptyDir ? "emptyDir" : nil].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !plan.terminating.isEmpty {
                Section {
                    ForEach(plan.terminating) { p in
                        Label { VStack(alignment: .leading) { Text(p.name).font(.whCode).lineLimit(1).truncationMode(.middle); Text("\(p.namespace) · already terminating").font(.caption).foregroundStyle(.secondary) } } icon: { Image(systemName: "hourglass").foregroundStyle(Palette.warning) }
                    }
                } header: { Text("Terminating (\(plan.terminating.count))") } footer: { Text("The drain waits for these pods to disappear.") }
            }
            if !plan.skipped.isEmpty {
                Section("Skipped (\(plan.skipped.count))") {
                    ForEach(plan.skipped) { p in
                        VStack(alignment: .leading) {
                            Text(p.name).font(.whCode).lineLimit(1).truncationMode(.middle)
                            Text("\(p.namespace) · \(p.disposition == .skipMirror ? "static / mirror pod" : "DaemonSet pod")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func blockerText(_ p: DrainPodPlan) -> String {
        switch p.disposition {
        case .blockedEmptyDir: "Uses emptyDir — enable “Delete emptyDir data”"
        case .blockedUnmanaged: "Not managed by a controller — enable “Force unmanaged pods”"
        case .blockedDaemonSet: "DaemonSet pod — enable “Ignore DaemonSet pods”"
        default: ""
        }
    }

    private func request() -> ConfirmRequest {
        let c = host.client, name = target.name, p = plan, opts = effectiveOptions, cluster = host.cluster
        let probes = Array(p.toEvict.prefix(50))
        return ConfirmRequest(
            title: "Drain \(name)?", message: "Cordons the node and evicts \(p.toEvict.count) pod\(p.toEvict.count == 1 ? "" : "s"). Workloads are rescheduled onto other nodes.",
            verb: "Cordon & Drain", isDestructive: true, cluster: cluster, resource: "node/\(name)", confirmationText: name,
            facts: [.init("Pods to evict", "\(p.toEvict.count)"), .init("Skipped", "\(p.skipped.count)"), .init("Timeout", "\(Int(opts.timeout / 60)) min")],
            dryRun: {
                do {
                    _ = try await c.setNodeUnschedulable(name: name, unschedulable: true, options: MutationOptions(dryRun: true))
                    // Dry-run EVERY eviction (up to 50), not just the first pod.
                    var waiting = 0
                    for pod in probes {
                        do { try await c.evict(pod: pod.name, namespace: pod.namespace, gracePeriodSeconds: opts.gracePeriodSeconds, dryRun: true) }
                        catch KubeError.server(let status) where status.code == 429 { waiting += 1 }
                        catch KubeError.notFound { continue }
                        catch { return .failed("\(pod.namespace)/\(pod.name): \((error as? KubeError)?.summary ?? error.localizedDescription)") }
                    }
                    if waiting > 0 { return .passed("Cordon accepted; \(waiting) eviction\(waiting == 1 ? "" : "s") will wait for a PodDisruptionBudget") }
                    return .passed("Cordon and \(probes.count) eviction\(probes.count == 1 ? "" : "s") accepted by the server")
                } catch { return .failed((error as? KubeError)?.summary ?? error.localizedDescription) }
            },
            action: { [self] in
                let r = DrainRunner(client: c, plan: p, options: opts)
                runner = r
                r.start()
            })
    }

    private func load() async {
        let c = host.client
        do {
            let list = try await c.list(Pod.self, options: ListOptions(fieldSelector: "spec.nodeName=\(target.name)"))
            pods = list.items
            budgets = (try? await c.list(PodDisruptionBudget.self).items) ?? []
            isLoaded = true
        } catch let e as KubeError { loadError = e } catch { loadError = .unreachable(cause: error.localizedDescription) }
    }
}

private struct DrainProgressView: View {
    let runner: DrainRunner
    let node: String

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: headerSymbol).foregroundStyle(headerTone.color)
                        Text(headerText).font(.headline)
                        Spacer()
                        Text("\(runner.finishedCount)/\(runner.pods.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ProgressView(value: runner.progress).tint(headerTone.color)
                    if runner.phase == .completed { Text("Drained · Uncordon later from the node screen.").font(.footnote).foregroundStyle(.secondary) }
                    if runner.phase == .cancelled { Text("Drain stopped. The node stays cordoned.").font(.footnote).foregroundStyle(.secondary) }
                    if runner.phase == .timedOut { Text("Timed out. Remaining pods were not evicted; the node stays cordoned.").font(.footnote).foregroundStyle(Palette.warningText) }
                    if case .failed(let m) = runner.phase { Text(m).font(.footnote).foregroundStyle(Palette.criticalText) }
                }
            }
            Section("Pods") {
                ForEach(runner.pods) { p in
                    HStack(spacing: 10) {
                        stateIcon(p.state)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.name).font(.whCode).lineLimit(1).truncationMode(.middle)
                            Text("\(p.namespace) · \(label(p.state))").font(.caption).foregroundStyle(tone(p.state).textColor)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var headerText: String {
        switch runner.phase {
        case .idle: "Starting"
        case .cordoning: "Cordoning \(node)…"
        case .draining: "Evicting pods…"
        case .completed: "Drained"
        case .cancelled: "Cancelled"
        case .timedOut: "Timed out"
        case .failed: "Drain failed"
        }
    }
    private var headerSymbol: String {
        switch runner.phase {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled, .timedOut: "exclamationmark.triangle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }
    private var headerTone: StatusTone {
        switch runner.phase { case .completed: .healthy; case .failed: .critical; case .cancelled, .timedOut: .warning; default: .info }
    }

    @ViewBuilder private func stateIcon(_ s: DrainPodState) -> some View {
        switch s {
        case .pending: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .evicting, .terminating: ProgressView().controlSize(.small)
        case .gone: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy)
        case .blocked: Image(systemName: "shield.lefthalf.filled").foregroundStyle(Palette.warning)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.critical)
        }
    }
    private func label(_ s: DrainPodState) -> String {
        switch s {
        case .pending: "Waiting"
        case .evicting: "Evicting"
        case .terminating: "Terminating"
        case .gone: "Gone"
        case .blocked(let m), .failed(let m): m
        }
    }
    private func tone(_ s: DrainPodState) -> StatusTone {
        switch s { case .gone: .healthy; case .blocked: .warning; case .failed: .critical; default: .unknown }
    }
}
