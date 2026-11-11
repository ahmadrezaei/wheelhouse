import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// One row of the transcript. The list is a `LazyVStack`, so only the rows on screen are built (ARCHITECTURE-MAC section 12.3).
struct TranscriptRow: View {
    let item: TranscriptItem
    let session: FirstMateSession
    let showTools: Bool
    let review: (String) -> Void

    var body: some View {
        switch item.kind {
        case .user(let text): UserBubble(text: text)
        case .assistant(let text): AssistantText(text: text)
        case .thinking(let text):
            DisclosureGroup("Thinking…") { Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                .font(.caption).foregroundStyle(.secondary)
        case .tool(let row):
            if showTools { ToolCallRow(row: row) }
        case .proposal(let id):
            ProposalCard(proposalID: id, coordinator: session.coordinator, review: review, decline: { session.coordinator.markDeclined(id) })
        case .notice(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct UserBubble: View {
    let text: String
    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.tint.opacity(0.16), in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("You: \(text)")
    }
}

/// Markdown rendered natively (no WebView).
struct AssistantText: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("First Mate: \(text)")
    }
}

/// "Read previous logs of payments-api · 18 KB", collapsed; the input is one click away.
struct ToolCallRow: View {
    let row: ToolRow
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            Text(row.input).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if !row.finished { ProgressView().controlSize(.mini) }
                else { Image(systemName: row.isError ? "exclamationmark.triangle" : "doc.text.magnifyingglass").foregroundStyle(row.isError ? Palette.warningText : .secondary) }
                Text(row.title).lineLimit(1).truncationMode(.middle)
                if let bytes = row.resultBytes {
                    Text("· \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tool call: \(row.title)")
    }
}

/// The answer as it streams. The session publishes it at most four times a second; this view only reads it.
struct LiveRow: View {
    let session: FirstMateSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.liveThinking.isEmpty {
                Text(session.liveThinking.suffix(240)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
            if !session.liveText.isEmpty {
                Text(session.liveText).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(statusText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(statusText)
    }

    private var statusText: String {
        if case .runningTools(let count) = session.state { return "Reading \(count) \(count == 1 ? "thing" : "things")…" }
        return session.liveText.isEmpty ? "Thinking…" : "Writing…"
    }
}
