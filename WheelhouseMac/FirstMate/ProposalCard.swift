import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// A proposal as a card (DESIGN-MAC section 6.12): what would change, where (with the environment badge), why, and **Review…** and
/// **Copy**. The card holds no client and no way to run anything; Review… opens the diff and then the normal confirmation sheet.
struct ProposalCard: View {
    let proposalID: String
    let coordinator: ProposalCoordinator
    let review: (String) -> Void
    let decline: () -> Void
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        if let change = coordinator.proposal(proposalID) {
            card(change)
        } else {
            // A proposal from an earlier run: its review state is gone.
            Label("Proposal \(proposalID) from an earlier session", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func card(_ change: ProposedChange) -> some View {
        let cluster = env.registry.config(for: change.cluster)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.badge.gearshape").accessibilityHidden(true)
                Text("Proposal · \(change.payload.label)").font(.subheadline.weight(.semibold))
                Spacer()
                if let cluster { Text(cluster.name).font(.caption).foregroundStyle(.secondary); EnvBadge(cluster.environment) }
                StateChip(state: change.state)
            }
            Text(ProposalText.summary(change.payload)).font(.system(.callout, design: .monospaced)).lineLimit(8).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !change.reason.isEmpty { Text(change.reason).font(.callout).foregroundStyle(.secondary) }
            if let note = ProposalText.reviewNote(change.payload) { Text(note).font(.caption).foregroundStyle(.secondary) }
            if change.state.isOpen {
                HStack {
                    Button("Review…") { review(change.id) }
                        .disabled(!coordinator.canBeginReview(change.id) || !ProposalText.canReview(change.payload))
                        .help(reviewHelp(change))
                        .accessibilityIdentifier("firstmate.proposal.review")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ProposalText.copyText(change.payload), forType: .string)
                    }
                    .accessibilityIdentifier("firstmate.proposal.copy")
                    Spacer()
                    Button("Decline", role: .destructive) { decline(); env.firstMate.recordDecline(change) }
                        .accessibilityIdentifier("firstmate.proposal.decline")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposal \(change.id), \(change.payload.label), \(change.state.words)")
        .accessibilityAction(named: "Review") { if coordinator.canBeginReview(change.id) { review(change.id) } }
        .accessibilityAction(named: "Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(ProposalText.copyText(change.payload), forType: .string)
        }
    }

    private func reviewHelp(_ change: ProposedChange) -> String {
        if !ProposalText.canReview(change.payload) { return ProposalText.reviewNote(change.payload) ?? "" }
        return coordinator.canBeginReview(change.id) ? "Review the change" : "Another proposal of this conversation is being reviewed."
    }
}

private struct StateChip: View {
    let state: ProposalState
    var body: some View {
        Text(state.words).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
    private var color: Color {
        switch state {
        case .pending, .inReview: Palette.infoText
        case .applied: Palette.healthyText
        case .declined: Palette.unknownText
        case .failed: Palette.criticalText
        }
    }
}

extension ProposalState {
    var words: String {
        switch self {
        case .pending: "Waiting for review"
        case .inReview: "In review"
        case .applied: "Applied"
        case .declined: "Declined"
        case .failed: "Failed"
        }
    }
}

/// Words for a proposal's payload. Everything shown has passed the redactor already (the card shows what the model wrote).
enum ProposalText {
    static func summary(_ payload: ProposalPayload) -> String {
        switch payload {
        case .patch(let kind, let name, let namespace, let type, let body):
            "\(kind.kind) \(namespace.map { "\($0)/" } ?? "")\(name)\n\(type) patch: \(Redactor().redact(body.jsonString(pretty: true)))"
        case .manifest(let yaml, let documents):
            "\(documents.count) \(documents.count == 1 ? "object" : "objects")\n\(Redactor().redact(yaml))"
        case .command(let text): Redactor().redact(text)
        case .helmUpgrade(let release, let namespace, let chart, let version, let values):
            "helm upgrade \(release) \(chart) -n \(namespace)\(version.map { " --version \($0)" } ?? "")\(values == nil ? "" : "\n(with values)")"
        case .gitopsAction(let controller, let action, let kind, let name, let namespace):
            "\(controller) \(action) \(kind) \(namespace)/\(name)"
        }
    }

    static func copyText(_ payload: ProposalPayload) -> String {
        switch payload {
        case .command(let text): Redactor().redact(text)
        case .manifest(let yaml, _): Redactor().redact(yaml)
        case .patch(_, _, _, _, let body): Redactor().redact(body.jsonString(pretty: true))
        case .helmUpgrade(_, _, _, _, let values): Redactor().redact(values ?? summary(payload))
        case .gitopsAction: summary(payload)
        }
    }

    /// Patches and manifests have a review flow in this milestone. A command needs the Deck Terminal's input line (M5b), a Helm
    /// upgrade needs Chart Room's upgrade sheet (M6b) and a GitOps action needs Tides; until those provide a review entry, the card
    /// offers Copy and Decline.
    static func canReview(_ payload: ProposalPayload) -> Bool {
        switch payload {
        case .patch, .manifest: true
        case .command, .helmUpgrade, .gitopsAction: false
        }
    }

    static func reviewNote(_ payload: ProposalPayload) -> String? {
        switch payload {
        case .patch, .manifest: nil
        case .command: "Inserting into the Deck Terminal's input line arrives with the terminal. Copy it and run it yourself for now."
        case .helmUpgrade: "Reviewing a Helm upgrade arrives with Chart Room's upgrade sheet. Copy the values for now."
        case .gitopsAction: "Reviewing a GitOps action from here is not available yet. Use Tides."
        }
    }
}
