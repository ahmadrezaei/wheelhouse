import SwiftUI
import WheelhouseKit
import WheelhouseUI

// MARK: - Scale

struct ScaleSheet: View {
    let host: ActionHost
    let target: ResourceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var replicas: Int

    init(host: ActionHost, target: ResourceTarget) {
        self.host = host
        self.target = target
        _replicas = State(initialValue: target.replicas ?? 1)
    }

    private var current: Int { target.replicas ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $replicas, in: 0...1000) {
                        HStack {
                            Text("Replicas")
                            Spacer()
                            Text("\(replicas)").font(.whKPI).contentTransition(.numericText())
                        }
                    }
                    .accessibilityValue("\(replicas)")
                    HStack(spacing: 8) {
                        ForEach(quickValues, id: \.self) { v in
                            Button("\(v)") { replicas = v }.buttonStyle(.bordered).controlSize(.small).tint(v == replicas ? Palette.tint : .secondary)
                        }
                    }
                } header: { Text(target.resource) } footer: {
                    if replicas == 0 { Text("Scaling to 0 stops every pod of this workload.").foregroundStyle(Palette.warningText) }
                    else if replicas != current { Text("Currently \(current) → \(replicas). You’ll confirm on the next step.") }
                }
            }
            .navigationTitle("Scale \(target.name)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ContextLine(cluster: host.cluster, namespace: target.namespace, kind: target.kind.kind).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Review") {
                        host.queue(host.scaleRequest(target, to: replicas))
                    }
                    .buttonStyle(.glassProminent).disabled(replicas == current)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var quickValues: [Int] { Array(Set([0, 1, max(current - 1, 0), current, current + 1, 3].filter { $0 >= 0 })).sorted() }
}

// MARK: - Delete options

struct DeleteOptionsSheet: View {
    let host: ActionHost
    let target: ResourceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var propagation: PropagationPolicy = .background

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Dependents", selection: $propagation) {
                        ForEach([PropagationPolicy.background, .foreground, .orphan], id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                } header: { Text("Delete dependents") } footer: { Text(propagation.explanation) }
            }
            .navigationTitle("Delete \(target.name)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ContextLine(cluster: host.cluster, namespace: target.namespace, kind: target.kind.kind).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { host.queue(host.deleteRequest(target, propagation: propagation)) }.buttonStyle(.glassProminent)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Rollback

struct RollbackSheet: View {
    let host: ActionHost
    let target: ResourceTarget
    @Environment(\.dismiss) private var dismiss
    @State private var revisions: [RolloutRevision] = []
    @State private var phase: Phase = .loading
    enum Phase { case loading, loaded, failed(KubeError) }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading: EmptyState(.loading)
                case .failed(let e): EmptyState(EmptyStateKind(error: e, clusterName: host.cluster.name))
                case .loaded:
                    if revisions.count < 2 && !(revisions.first.map { !$0.isCurrent } ?? false) {
                        EmptyState(.empty(title: "No Earlier Revisions", systemImage: "clock.arrow.circlepath", hint: "This Deployment has no previous ReplicaSet to roll back to."))
                    } else {
                        List {
                            if let blocker = RolloutHistory.rollbackBlocker(deployment: target.object) {
                                Section { Label(blocker, systemImage: "pause.circle").foregroundStyle(Palette.warningText) }
                            }
                            Section {
                                ForEach(revisions) { rev in revisionRow(rev) }
                            } header: { Text("Revisions") } footer: { Text("Rolling back restores the pod template of the chosen ReplicaSet.") }
                        }
                    }
                }
            }
            .navigationTitle("Roll Back \(target.name)")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                ContextLine(cluster: host.cluster, namespace: target.namespace, kind: target.kind.kind).padding(.horizontal, Spacing.l).padding(.bottom, 6)
            }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func revisionRow(_ rev: RolloutRevision) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Revision \(rev.revision)").font(.headline)
                if rev.isCurrent { StatusPill(tone: .info, text: "Current", symbol: "checkmark") }
                Spacer()
                Text(Format.age(from: rev.created)).font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(rev.images, id: \.self) { Text($0).font(.whCodeSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle) }
            if let cause = rev.changeCause { Text(cause).font(.footnote) }
            HStack {
                Text(rev.replicaSetName).font(.whCodeSmall).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if !rev.isCurrent {
                    Button("Roll Back") {
                        let current = revisions.first(where: \.isCurrent)
                        if let req = host.rollbackRequest(target, to: rev, from: current) { host.queue(req) }
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(Palette.warning)
                    .disabled(rev.template == nil || RolloutHistory.rollbackBlocker(deployment: target.object) != nil
                              || RolloutHistory.matchesCurrentTemplate(rev, deployment: target.object))
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func load() async {
        let selector = LabelSelectorSyntax.query(from: target.object.raw.value(at: "spec.selector.matchLabels")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
        do {
            let raw = try await host.client.listRaw(.replicaSet, namespace: target.namespace, options: ListOptions(labelSelector: selector.isEmpty ? nil : selector))
            let sets = (raw["items"]?.arrayValue ?? []).map { Unstructured(raw: $0) }
            revisions = RolloutHistory.revisions(deployment: target.object, replicaSets: sets)
            phase = .loaded
        } catch let e as KubeError { phase = .failed(e) } catch { phase = .failed(.unreachable(cause: error.localizedDescription)) }
    }
}
