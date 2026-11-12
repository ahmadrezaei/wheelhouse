import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// "What was sent": every request of the conversation, with the messages it added (after redaction) and, on demand, the full request
/// JSON rebuilt from the stored history. The rebuilt body is checked against the hash recorded when it was sent; if this build can no
/// longer produce those bytes (an update changed the prompt or the tools), the view says so instead of presenting it as exact.
struct WhatWasSentView: View {
    let session: FirstMateSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @State private var showFull = false

    private var requests: [SentRequest] { session.sentRequests }

    var body: some View {
        NavigationSplitView {
            List(requests.reversed(), selection: $selected) { request in
                VStack(alignment: .leading, spacing: 2) {
                    Text("Request \(request.id)").font(.callout.weight(.medium))
                    Text("\(request.at.formatted(date: .omitted, time: .standard)) · \(request.model) · \(request.effort) · \(ByteCountFormatter.string(fromByteCount: Int64(request.bytes), countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(request.id)
            }
            .overlay { if requests.isEmpty { ContentUnavailableView("Nothing sent yet", systemImage: "paperplane") } }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let id = selected, let request = requests.first(where: { $0.id == id }) {
                detail(request)
            } else {
                Text("Select a request.").foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        .onAppear { selected = requests.last?.id }
        .accessibilityIdentifier("firstmate.sentSheet")
    }

    private func detail(_ request: SentRequest) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Added by this request (after redaction)").font(.headline)
                ForEach(Array(request.tail.enumerated()), id: \.offset) { _, message in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(message.role.rawValue.capitalized).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(Self.show(message)).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    }
                }
                Text("Earlier messages of the conversation were sent again unchanged (\(request.historyCount) before this request).").font(.caption).foregroundStyle(.secondary)
                Toggle("Show the full request JSON", isOn: $showFull)
                if showFull { full(request) }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func full(_ request: SentRequest) -> some View {
        if let rebuilt = session.snapshot.reconstruct(request) {
            if !rebuilt.matches {
                Label("This build can't reproduce the exact bytes that were sent (the app changed since). Shown as rebuilt.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(Palette.warningText)
            }
            let text = (try? JSONValue.parse(rebuilt.body))?.jsonString(pretty: true) ?? ""
            Text(text.count > 200_000 ? String(text.prefix(200_000)) + "\n… (cut at 200 KB)" : text)
                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
        } else {
            Text("The stored history for this request is not available.").foregroundStyle(.secondary)
        }
    }

    private static func show(_ message: AIMessage) -> String {
        message.role == .system ? message.text : JSONValue.array(message.content).jsonString(pretty: true)
    }
}
