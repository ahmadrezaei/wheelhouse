import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// "Review…" for a First Mate proposal: the change as a diff (live object against the server's dry-run result), then the normal
/// ConfirmSheet with `origin: .firstMate(conversation:)` (ARCHITECTURE-MAC section 9.2).
///
/// **This is the only place in First Mate that holds a cluster client**, and the only path from a proposal to a cluster:
/// `ProposalConfirmation.request` puts the mutation inside the sheet's action, which runs only when the person confirms. The sheet is
/// hardened (no default button, input ignored for a second, typing required on Production, one proposal in a sheet at a time).
///
/// The presenter contract of `ProposalCoordinator` is kept: the caller did `beginReview` before presenting, `.sheet(onDismiss:)` calls
/// `reviewDismissed`, and Decline calls `markDeclined`.
struct ProposalReviewSheet: View {
    let proposalID: String
    let coordinator: ProposalCoordinator
    let hub: FirstMateHub
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var preview: ProposalPreview?
    @State private var confirm: ConfirmRequest?
    @State private var problem: String?

    private var change: ProposedChange? { coordinator.proposal(proposalID) }
    private var cluster: ClusterConfig? { change.flatMap { env.registry.config(for: $0.cluster) } }

    var body: some View {
        NavigationStack {
            Group {
                if let change, let cluster {
                    content(change, cluster)
                } else {
                    ContentUnavailableView("This proposal is no longer available", systemImage: "questionmark.folder")
                }
            }
            .navigationTitle("Review proposal")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.accessibilityIdentifier("firstmate.review.close") }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Decline", role: .destructive) {
                        if let change { coordinator.markDeclined(change.id); hub.recordDecline(change) }
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 480)
        .confirmSheet($confirm)
        .task { await load() }
    }

    @ViewBuilder private func content(_ change: ProposedChange, _ cluster: ClusterConfig) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                OriginBadge(change.origin)
                Text(cluster.name).font(.headline)
                EnvBadge(cluster.environment)
                Spacer()
            }
            if !change.reason.isEmpty { Text(change.reason).foregroundStyle(.secondary) }
            if cluster.environment == .production {
                Label("Production cluster: confirming will ask you to type the name.", systemImage: "exclamationmark.shield").font(.callout).foregroundStyle(Palette.warningText)
            }
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(preview.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                        ForEach(preview.entries) { entry in EntryView(entry: entry) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ProgressView("Asking the server for a dry run…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(Palette.criticalText) }
            HStack {
                Spacer()
                Button("Continue to Confirm…") { present(change, cluster) }
                    .buttonStyle(.glass)
                    .disabled(preview == nil)
                    .accessibilityIdentifier("firstmate.review.continue")
            }
        }
        .padding(16)
    }

    private func load() async {
        guard let change, let cluster, let client = env.registry.session(for: change.cluster)?.client else {
            preview = ProposalPreview(entries: [], notes: ["This cluster is not connected."])
            return
        }
        preview = await ProposalPreview.load(for: change, cluster: cluster, client: client)
    }

    /// Builds the request for the normal confirmation sheet. The client is handed to it here and nowhere else.
    private func present(_ change: ProposedChange, _ cluster: ClusterConfig) {
        guard let client = env.registry.session(for: change.cluster)?.client,
              let request = ProposalConfirmation.request(for: change, cluster: cluster, client: client, coordinator: coordinator) else {
            problem = "This kind of proposal can't be applied from here."
            return
        }
        problem = nil
        confirm = request
    }

    private struct EntryView: View {
        let entry: ProposalPreview.Entry

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.title).font(.subheadline.weight(.semibold))
                    if entry.isNew { Text("new").font(.caption2).padding(.horizontal, 5).background(Palette.healthy.opacity(0.2), in: Capsule()) }
                }
                if let problem = entry.problem {
                    Label(problem, systemImage: "xmark.octagon").font(.callout).foregroundStyle(Palette.criticalText)
                } else if entry.diff.isEmpty || !entry.diff.contains(where: { $0.kind != .context }) {
                    Text("The server reports no change.").font(.callout).foregroundStyle(.secondary)
                } else {
                    DiffView(lines: entry.diff)
                }
            }
        }
    }

    /// A folded diff in monospace. Unchanged runs are folded; the rows are built lazily.
    private struct DiffView: View {
        let lines: [DiffLine]
        var body: some View {
            let rows = LineDiff.fold(lines)
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    switch row {
                    case .line(let line):
                        Text("\(prefix(line.kind)) \(line.text)")
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(line.kind))
                    case .fold(_, let count):
                        Text("⋯ \(count) unchanged lines").font(.caption).foregroundStyle(.secondary).padding(.vertical, 2)
                    }
                }
            }
            .textSelection(.enabled)
        }
        private func prefix(_ kind: DiffLine.Kind) -> String { kind == .added ? "+" : kind == .removed ? "−" : " " }
        private func background(_ kind: DiffLine.Kind) -> Color {
            kind == .added ? Palette.diffAdd.opacity(0.18) : kind == .removed ? Palette.diffDelete.opacity(0.18) : .clear
        }
    }
}
