import Foundation
import Observation

/// What a proposal asks for. Validated when the proposal tool is called; reviewed by the user later.
public enum ProposalPayload: Sendable, Equatable {
    /// `patchType` is one of `json`, `merge`, `strategic`, `apply`.
    case patch(kind: ResourceKind, name: String, namespace: String?, patchType: String, body: JSONValue)
    case manifest(yaml: String, documents: [JSONValue])
    /// Inserted into the terminal by the Mac app (M5b); never run.
    case command(String)
    case helmUpgrade(release: String, namespace: String, chart: String, version: String?, valuesYAML: String?)
    case gitopsAction(controller: String, action: String, kind: String, name: String, namespace: String)

    public var label: String {
        switch self {
        case .patch: "Patch"
        case .manifest: "Manifest"
        case .command: "Command"
        case .helmUpgrade: "Helm upgrade"
        case .gitopsAction: "GitOps action"
        }
    }
}

public enum ProposalState: Sendable, Equatable {
    /// Waiting for the user to press Review.
    case pending
    /// In a review sheet or editor right now.
    case inReview
    case applied
    case declined
    case failed(String)

    public var isOpen: Bool { self == .pending || self == .inReview }
}

/// A change First Mate proposed. It is a record, not an action: nothing here can reach a cluster.
public struct ProposedChange: Identifiable, Sendable, Equatable {
    public let id: String
    public let conversation: String
    public let cluster: ClusterID
    public let payload: ProposalPayload
    public let reason: String
    public let createdAt: Date
    public internal(set) var state: ProposalState

    /// The origin its confirmation carries.
    public var origin: ChangeOrigin { .firstMate(conversation: conversation) }
}

/// Keeps First Mate's proposals and nothing else (ARCHITECTURE-MAC section 9.2).
///
/// **Proposals reach a cluster only through the normal ConfirmSheet.** This type has no client, no executor and no way to run a
/// closure: "Review…" builds a `ConfirmRequest(origin: .firstMate(conversationID))` (in `WheelhouseUI`, `ProposalConfirmation`),
/// and only that sheet's action can mutate. The coordinator learns the outcome and queues a system note for the conversation.
@MainActor @Observable
public final class ProposalCoordinator {
    public static let maxOpenPerConversation = 20

    public private(set) var proposals: [ProposedChange] = []
    @ObservationIgnored private var nextNumber = 1
    @ObservationIgnored private var outcomeNotes: [String: [String]] = [:]
    @ObservationIgnored private var lastAttemptError: [String: String] = [:]

    public init() {}

    public enum SubmitError: Error, Equatable { case tooManyOpen }

    /// Creates a pending proposal. Validation of the payload is the proposal tool's job.
    @discardableResult
    public func submit(conversation: String, cluster: ClusterID, payload: ProposalPayload, reason: String) throws -> ProposedChange {
        guard openProposals(in: conversation).count < Self.maxOpenPerConversation else { throw SubmitError.tooManyOpen }
        let change = ProposedChange(id: "p-\(nextNumber)", conversation: conversation, cluster: cluster, payload: payload,
                                    reason: reason, createdAt: Date(), state: .pending)
        nextNumber += 1
        proposals.append(change)
        return change
    }

    public func proposal(_ id: String) -> ProposedChange? { proposals.first { $0.id == id } }
    public func proposals(in conversation: String) -> [ProposedChange] { proposals.filter { $0.conversation == conversation } }
    public func openProposals(in conversation: String) -> [ProposedChange] { proposals(in: conversation).filter { $0.state.isOpen } }

    /// At most one proposal per conversation is in a sheet at a time; Review… is disabled for the others meanwhile.
    public func canBeginReview(_ id: String) -> Bool {
        guard let change = proposal(id), change.state == .pending else { return false }
        return !proposals(in: change.conversation).contains { $0.state == .inReview }
    }

    @discardableResult
    public func beginReview(_ id: String) -> Bool {
        guard canBeginReview(id), let index = proposals.firstIndex(where: { $0.id == id }) else { return false }
        proposals[index].state = .inReview
        return true
    }

    /// The sheet or editor closed without a decision (for example the window closed): back to pending.
    public func cancelReview(_ id: String) {
        guard let index = proposals.firstIndex(where: { $0.id == id }), proposals[index].state == .inReview else { return }
        proposals[index].state = .pending
    }

    public func markApplied(_ id: String) { finish(id, .applied, "Proposal \(id) was applied by the user.") }
    /// The person pressed Decline (the presenter calls this; see ``reviewDismissed(_:)`` for a sheet that is simply closed).
    public func markDeclined(_ id: String) { finish(id, .declined, "Proposal \(id) was declined by the user.") }

    /// The apply was approved but failed. The message goes to the model in a note, so it is redacted and shortened first.
    public func markFailed(_ id: String, message: String) {
        let safe = Redactor().redact(String(message.prefix(500)))
        finish(id, .failed(safe), "Proposal \(id) was approved by the user but failed: \(safe)")
    }

    /// The sheet's action threw. The sheet stays open and the person may retry, so the proposal is not failed yet.
    public func recordAttemptFailure(_ id: String, message: String) { lastAttemptError[id] = message }

    /// **Presenter contract (M11b).** Call ``beginReview(_:)`` when the review sheet or editor opens, call this from
    /// `.sheet(onDismiss:)`, and call ``markDeclined(_:)`` from an explicit Decline button. A dismissal after a success does
    /// nothing; after only failed attempts it fails the proposal; otherwise the proposal returns to pending.
    public func reviewDismissed(_ id: String) {
        guard let change = proposal(id), change.state == .inReview else { lastAttemptError[id] = nil; return }
        if let error = lastAttemptError[id] { markFailed(id, message: error) } else { cancelReview(id) }
        lastAttemptError[id] = nil
    }

    private func finish(_ id: String, _ state: ProposalState, _ note: String) {
        guard let index = proposals.firstIndex(where: { $0.id == id }), proposals[index].state.isOpen else { return }
        proposals[index].state = state
        lastAttemptError[id] = nil
        outcomeNotes[proposals[index].conversation, default: []].append(note)
    }

    /// Outcome notes for a conversation, oldest first. The AI session queues them as `role: "system"` notes and appends them after
    /// the next user message (the ordering rule of section 9.1); history is never edited. Taking them clears them.
    public func takeOutcomeNotes(for conversation: String) -> [String] {
        defer { outcomeNotes[conversation] = nil }
        return outcomeNotes[conversation] ?? []
    }
}
