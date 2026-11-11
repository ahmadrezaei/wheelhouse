import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The First Mate panel: setup card without a key, otherwise the conversation. Used by the inspector segment and the full pane.
struct FirstMatePanel: View {
    let slot: String
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        let hub = env.firstMate
        let _ = hub.slotRevision      // follow New Conversation and Open
        Group {
            if hub.hasKey {
                ConversationView(hub: hub, session: hub.session(for: slot), slot: slot)
                    .id(hub.session(for: slot).id)
            } else {
                FirstMateSetupCard()
            }
        }
        .accessibilityIdentifier("firstmate.panel")
    }
}

/// What First Mate does, what is sent and where (the privacy disclosure of ARCHITECTURE-MAC section 9.4), and Add API Key….
struct FirstMateSetupCard: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("First Mate", systemImage: "sparkles").font(.title3.weight(.semibold))
                Text("An assistant that reads what is running in your clusters, explains failures and proposes changes. It never changes anything itself: every proposal opens the normal review and confirmation.")
                FirstMateDisclosure()
                Button("Add API Key…") { openSettings() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("firstmate.addKey")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("firstmate.setup")
    }
}

/// The privacy disclosure, shown in the setup card and in Settings → First Mate.
struct FirstMateDisclosure: View {
    static let lines = [
        "Your question and redacted cluster data that First Mate reads with your permissions go directly from this Mac to Anthropic's API (api.anthropic.com), using your own API key, under your agreement with Anthropic.",
        "Nothing goes to a Wheelhouse server. There is none.",
        "Secret values are never sent.",
        "You can see exactly what was sent, for every message.",
        "Conversations are stored only on this Mac, encrypted, and deleted after 30 days by default.",
        "Production clusters ask before First Mate reads them.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What is sent").font(.headline)
            ForEach(Self.lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.circle").foregroundStyle(Palette.tintText).accessibilityHidden(true)
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Conversation

private struct ConversationView: View {
    let hub: FirstMateHub
    let session: FirstMateSession
    let slot: String
    @Environment(MacAppEnvironment.self) private var env
    @State private var draft = ""
    @State private var attachContext = true
    @State private var showInfo = false
    @State private var showSent = false
    @State private var reviewing: String?
    @State private var lastReviewed: String?
    @State private var pendingProfile: AIModelChoice?
    @FocusState private var composerFocused: Bool

    private var context: FirstMateContext? { attachContext ? FirstMateContextReader.current(env: env) : nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            banners
            composer
        }
        .sheet(isPresented: $showSent) { WhatWasSentView(session: session) }
        .sheet(item: Binding(get: { reviewing.map(ReviewTarget.init) }, set: { reviewing = $0?.id }), onDismiss: {
            if let id = lastReviewed { session.coordinator.reviewDismissed(id) }
            lastReviewed = nil
        }) { target in
            ProposalReviewSheet(proposalID: target.id, coordinator: session.coordinator, hub: hub)
        }
        .confirmationDialog("Switch model?", isPresented: Binding(get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } }), presenting: pendingProfile) { choice in
            Button("Switch to \(choice.label)") { session.setProfile(choice) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The prompt cache restarts and earlier reasoning is dropped, because it belongs to the model that wrote it.")
        }
        .onChange(of: session.draftToRestore) { _, restored in
            if let restored { draft = restored; session.consumeDraftRestore() }
        }
        .task { await hub.refreshList() }
    }

    private struct ReviewTarget: Identifiable { var id: String }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Palette.tintText).accessibilityHidden(true)
            Text(session.title).font(.headline).lineLimit(1).truncationMode(.tail)
            Spacer()
            Menu {
                modelItem(.standard, "Opus 5.5 · effort medium")
                modelItem(.quick, "Quick · Sonnet 5.5 · effort low")
            } label: { Text(session.profile.label).font(.caption) }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("firstmate.model")
                .help("Model. Investigate (⌥↩) uses effort high.")
            Menu {
                Button("New Conversation") { hub.newConversation(in: slot) }
                Divider()
                ForEach(hub.recent.prefix(12)) { item in
                    Button(item.title) { Task { await hub.open(item.id, in: slot) } }
                }
                Divider()
                Button("Delete This Conversation", role: .destructive) { Task { await hub.delete(session.id); hub.newConversation(in: slot) } }
            } label: { Image(systemName: "text.bubble") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Conversations")
            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Usage and cost")
                .popover(isPresented: $showInfo) { InfoPopover(session: session, hub: hub, showSent: { showInfo = false; showSent = true }) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private func modelItem(_ choice: AIModelChoice, _ title: String) -> some View {
        Button {
            if session.snapshot.messages.isEmpty { session.setProfile(choice) } else { pendingProfile = choice }
        } label: {
            if session.profile == choice { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    // MARK: Transcript (lazy)

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.items.isEmpty, session.pendingUserText == nil, !session.isBusy { EmptyHint() }
                    ForEach(session.items) { item in
                        TranscriptRow(item: item, session: session, showTools: hub.preferences.showToolCalls, review: begin).equatable()
                    }
                    if let pending = session.pendingUserText { UserBubble(text: pending) }
                    if session.isBusy { LiveRow(session: session, follow: { proxy.scrollTo("bottom", anchor: .bottom) }) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.items.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: session.state) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .accessibilityIdentifier("firstmate.transcript")
    }

    /// Review… opens the sheet only when no other proposal of this conversation is in one (the coordinator enforces it).
    private func begin(_ id: String) {
        guard session.coordinator.beginReview(id) else { return }
        lastReviewed = id
        reviewing = id
    }

    // MARK: Banners

    @ViewBuilder private var banners: some View {
        VStack(spacing: 6) {
            if let cluster = session.pendingPermission {
                Banner(symbol: "lock.shield", tint: Palette.infoText) {
                    Text("Let First Mate read \(env.registry.config(for: cluster)?.name ?? cluster) for this conversation?")
                } actions: {
                    Button("Allow for This Conversation") {
                        session.allow(cluster)
                        session.context = context
                        session.send("You may read it now. Please continue.")
                    }.accessibilityIdentifier("firstmate.allow")
                    Button("Not Now") { session.dismissPermissionPrompt() }
                }
            }
            switch session.state {
            case .blocked(.conversationCapReached(let spent, let cap)):
                Banner(symbol: "dollarsign.circle", tint: Palette.warningText) {
                    Text("This conversation reached its cost cap (\(Money.text(spent)) of \(Money.text(cap))).")
                } actions: {
                    Button("Continue (+$2)") { session.raiseCap() }.accessibilityIdentifier("firstmate.continueCap")
                }
            case .blocked(.dailyCapReached(let spent, let cap)):
                Banner(symbol: "dollarsign.circle", tint: Palette.warningText) {
                    Text("Today's cap is reached (\(Money.text(spent)) of \(Money.text(cap))). Change it in Settings → First Mate.")
                } actions: { EmptyView() }
            case .failed(let message):
                Banner(symbol: "exclamationmark.triangle", tint: Palette.criticalText) { Text(message) } actions: {
                    if session.canRetry { Button("Retry") { session.retry() } }
                    Button("Rephrase") { session.abandonTurn() }
                }
            case .refused(let category, let explanation):
                Banner(symbol: "hand.raised", tint: Palette.warningText) {
                    Text("The model declined this request\(category.map { " (\($0))" } ?? ""). \(explanation)")
                } actions: {
                    Button("Retry") { session.retry() }.accessibilityIdentifier("firstmate.retry")
                    Button("Rephrase") { session.abandonTurn() }.accessibilityIdentifier("firstmate.rephrase")
                }
            case .cutOff:
                Banner(symbol: "scissors", tint: Palette.warningText) { Text("The answer was cut off.") } actions: {
                    Button("Continue") { session.context = context; session.send("Please continue.") }
                }
            default: EmptyView()
            }
            if let problem = session.storageProblem {
                Text(problem).font(.caption).foregroundStyle(Palette.criticalText).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let context = FirstMateContextReader.current(env: env) {
                HStack(spacing: 6) {
                    Image(systemName: attachContext ? "paperclip" : "paperclip.badge.ellipsis").accessibilityHidden(true)
                    Text(context.description).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Toggle("Attached", isOn: $attachContext).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                        .accessibilityLabel("Attach selection")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Ask First Mate…", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .disabled(session.isBusy)
                    .onSubmit { send(investigate: false) }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.option) { send(investigate: true); return .handled }
                        return .ignored
                    }
                    .accessibilityIdentifier("firstmate.input")
                if session.isBusy {
                    Button { session.stop() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.borderless).keyboardShortcut(".", modifiers: .command)
                        .help("Stop (⌘.)").accessibilityLabel("Stop")
                        .accessibilityIdentifier("firstmate.stop")
                } else {
                    Menu {
                        Button("Send as Investigate (⌥↩)") { send(investigate: true) }
                    } label: { Image(systemName: "arrow.up.circle.fill") } primaryAction: { send(investigate: false) }
                        .menuStyle(.borderlessButton).fixedSize()
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (↩). Investigate (⌥↩) thinks harder.")
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("firstmate.send")
                }
            }
        }
        .padding(12)
    }

    private func send(investigate: Bool) {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !session.isBusy else { return }
        session.context = context
        draft = ""
        session.send(text, investigate: investigate)
    }
}

enum Money {
    static func text(_ dollars: Double) -> String { dollars.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about what you are looking at.").font(.callout)
            Text("First Mate reads with your permissions, explains what it finds and proposes changes for you to review.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 24)
    }
}

private struct Banner<Content: View, Actions: View>: View {
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    init(symbol: String, tint: Color, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) {
        self.symbol = symbol
        self.tint = tint
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            content.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
            actions.controlSize(.small)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Info

private struct InfoPopover: View {
    let session: FirstMateSession
    let hub: FirstMateHub
    let showSent: () -> Void

    var body: some View {
        let usage = session.usage
        VStack(alignment: .leading, spacing: 8) {
            Text("Usage").font(.headline)
            LabeledContent("This conversation", value: "\(Money.text(session.spentDollars)) of \(Money.text(session.capDollars))")
            LabeledContent("Today", value: "\(Money.text(hub.daily.today)) of \(Money.text(hub.preferences.dailyCap))")
            Divider()
            LabeledContent("Input", value: usage.inputTokens.formatted())
            LabeledContent("Output", value: usage.outputTokens.formatted())
            LabeledContent("Cache read", value: usage.cacheReadTokens.formatted())
            LabeledContent("Cache write", value: usage.cacheCreationTokens.formatted())
            Text("Estimated from the price list that ships with the app.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("What Was Sent…", action: showSent).accessibilityIdentifier("firstmate.whatWasSent")
                Spacer()
                Button("Continue (+$2)") { session.raiseCap() }
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 320)
    }
}
