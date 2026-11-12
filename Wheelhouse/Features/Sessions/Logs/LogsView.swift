import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S12 — live and previous container logs. `container == nil` → default/first container.
struct LogsView: View {
    let pod: ResourceRef
    var container: String?
    var previous = false

    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.paneIsVisible) private var paneIsVisible
    @State private var model: LogsModel?
    /// What this screen last told its model about its pane's visibility (nil: nothing reported).
    @State private var reportedVisible: Bool?
    @State private var detail: LogLine?
    @State private var shareURL: ShareItem?
    @FocusState private var searchFocused: Bool
    private let hub = SessionsHub.shared

    private var session: ClusterSession? { registry.session(for: pod.clusterID) }

    var body: some View {
        Group {
            if let session, let model {
                content(session: session, model: model)
            } else if session == nil {
                EmptyState(.empty(title: "Cluster Not Found", systemImage: "server.rack", hint: "This cluster was removed."))
            } else {
                EmptyState(.loading)
            }
        }
        .navigationTitle("Logs")
        .whInlineNavigationTitle()
        .task(id: pod) { await start() }
        // A follow request holds an inotify watcher on the node: close it when the screen is left (unless pinned).
        .onAppear {
            if let model { reportVisibility(to: model); model.screenDidAppear() }
        }
        .onDisappear {
            model?.screenDidDisappear()
            withdrawVisibility()
        }
        // A Mac pane that cannot be seen (hidden tab, covered window) keeps its stream filling but stops syncing and drawing.
        .onChange(of: paneIsVisible) { _, _ in if let model { reportVisibility(to: model) } }
    }

    /// Tells the model whether this screen's pane can be seen (one model can be on several screens, so it counts them).
    private func reportVisibility(to model: LogsModel) {
        model.paneVisibilityChanged(paneIsVisible, previous: reportedVisible)
        reportedVisible = paneIsVisible
    }

    private func withdrawVisibility() {
        if let reportedVisible { model?.paneVisibilityWithdrawn(reportedVisible) }
        reportedVisible = nil
    }

    private func start() async {
        guard let session else { return }
        if let old = model { if let reportedVisible { old.paneVisibilityWithdrawn(reportedVisible) }; reportedVisible = nil }
        if let existing = hub.existingLogs(for: pod, container: container, previous: previous) {
            model = existing
            reportVisibility(to: existing)
            existing.screenDidAppear()   // `.onAppear` ran before `model` was set
            return
        }
        let m = LogsModel(pod: pod, container: container, previous: previous, session: session,
                          maxLines: preferences.logMaxLines, fontSize: preferences.logFontSize)
        hub.register(m)
        model = m
        reportVisibility(to: m)
        m.screenDidAppear()
        await m.load()
    }

    // MARK: Content

    /// Everything read here re-renders the whole screen (chips, toolbar, banners), so nothing here may read what changes with every
    /// flush of new lines: the lines, the footer and the stream sync are child views with their own observation (`LogsLinesPane`,
    /// `LogsFooter`, `LogsStreamSync`), and the toolbar reads `hasLines`.
    @ViewBuilder
    private func content(session: ClusterSession, model: LogsModel) -> some View {
        VStack(spacing: 0) {
            ContextLine(cluster: session.config, namespace: pod.namespace, kind: "pod/\(pod.name)")
                .padding(.horizontal, Spacing.l).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            chips(model)
            if model.isSearching { searchBar(model) }
            if model.suggestPrevious { suggestionBanner(model) }
            if model.stream.problem != nil { watcherBanner(model) }
            LogsLinesPane(model: model, session: session) { detail = $0 }
            LogsFooter(model: model)
        }
        .background(Color.whSystemBackground)
        .paneToolbar { toolbar(model) }
        #if os(macOS)
        // The Mac keeps SwiftUI off the per-flush path entirely: the model syncs itself and the table follows the model. Keyed to the
        // model, so a screen reused for another pod stops the old model's sync and starts the new one's. Only while the pane can be seen:
        // a hidden pane's stream keeps filling and the next visible moment catches up in one sync (ARCHITECTURE-MAC section 12.3.3).
        .background { if paneIsVisible { MacLogsStreamSync(model: model).id(model.id) } }
        #else
        .background { LogsStreamSync(model: model) }
        #endif
        .sheet(item: $detail) { LogLineDetailSheet(line: $0) }
        .sheet(item: $shareURL) { ShareSheet(url: $0.url) }
        .background { shortcuts(model) }
    }

    // MARK: Chips

    private func chips(_ model: LogsModel) -> some View {
        @Bindable var model = model
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if model.containers.count > 1 {
                    Menu {
                        ForEach(model.containers, id: \.self) { name in
                            Button { model.setContainer(name) } label: { Label(name, systemImage: (!model.allContainers && model.container == name) ? "checkmark" : "") }
                        }
                        Divider()
                        Button { model.setContainer(nil) } label: { Label("All containers", systemImage: model.allContainers ? "checkmark" : "") }
                    } label: { chip(model.title, symbol: "shippingbox", selected: false, chevron: true) }
                } else {
                    chip(model.title, symbol: "shippingbox", selected: false)
                }
                Button { model.follow ? (model.follow = false) : model.jumpToLive() } label: { chip("Follow", symbol: model.isLive ? "dot.radiowaves.left.and.right" : "arrow.down.to.line", selected: model.follow) }
                    .disabled(model.previous)
                Button { model.setPrevious(!model.previous) } label: { chip("Previous", symbol: "clock.arrow.circlepath", selected: model.previous) }
                Button { model.timestamps.toggle() } label: { chip("Timestamps", symbol: "clock", selected: model.timestamps) }
                Button { model.wrap.toggle() } label: { chip("Wrap", symbol: "text.word.spacing", selected: model.wrap) }
                Menu {
                    Picker("Since", selection: $model.since) { ForEach(LogSince.allCases) { Text($0.title).tag($0) } }
                } label: { chip("Since: \(model.since.title)", symbol: "calendar.badge.clock", selected: model.since != .all, chevron: true) }
                    .onChange(of: model.since) { _, _ in model.reload() }
                Menu {
                    Picker("Lines", selection: $model.tail) { ForEach(LogTail.allCases) { Text($0.title).tag($0) } }
                } label: { chip(model.tail.title, symbol: "list.number", selected: false, chevron: true) }
                    .onChange(of: model.tail) { _, _ in model.reload() }
            }
            .padding(.horizontal, Spacing.l)
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, symbol: String, selected: Bool, chevron: Bool = false) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .foregroundStyle(selected ? Palette.onTint : Color.primary)
        .background(selected ? AnyShapeStyle(Palette.tint) : AnyShapeStyle(Palette.fieldFill), in: Capsule())
        .frame(minHeight: Spacing.minHit - 8)
        .contentShape(Capsule())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Search

    private func searchBar(_ model: LogsModel) -> some View {
        @Bindable var model = model
        return HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(model.useRegex ? "Regex" : "Search logs", text: $model.query)
                    .whNoAutocapitalization().autocorrectionDisabled().focused($searchFocused)
                    .font(.whCode).submitLabel(.search).onSubmit { model.nextMatch() }
                if !model.query.isEmpty {
                    Text(model.matchIDs.isEmpty ? "0" : "\((model.currentMatch ?? 0) + 1)/\(model.matchIDs.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(model.matchIDs.isEmpty ? Palette.criticalText : Color.secondary)
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            Button { model.previousMatch() } label: { Image(systemName: "chevron.up") }.disabled(model.matchIDs.isEmpty).accessibilityLabel("Previous match")
            Button { model.nextMatch() } label: { Image(systemName: "chevron.down") }.disabled(model.matchIDs.isEmpty).accessibilityLabel("Next match")
            Menu {
                Toggle("Regular expression", isOn: $model.useRegex)
                Toggle("Show matching lines only", isOn: $model.matchesOnly)
            } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Search options")
        }
        .padding(.horizontal, Spacing.l).padding(.bottom, 6)
        .onAppear { searchFocused = true }
    }

    private func suggestionBanner(_ model: LogsModel) -> some View {
        StateBanner(.custom(tone: .warning, symbol: "arrow.triangle.2.circlepath", title: "Container is crash-looping",
                            message: "The previous instance usually holds the error that killed it.")) {
            Button("Show Previous Logs") { model.setPrevious(true) }.font(.footnote.weight(.semibold)).padding(.top, 2)
        }
        .padding(.horizontal, Spacing.l).padding(.bottom, 6)
    }

    /// Shown when the kubelet reported that it could not create a log watcher (node out of inotify instances).
    private func watcherBanner(_ model: LogsModel) -> some View {
        StateBanner(.custom(tone: .warning, symbol: "exclamationmark.triangle.fill", title: LogStreamProblem.nodeWatchLimit(detail: "").title,
                            message: "The node ran out of file watchers (inotify). Kubernetes can't stream live logs from this node until it's fixed.")) {
            VStack(alignment: .leading, spacing: 6) {
                if let node = model.nodeName { Text("Node: \(node)").font(.footnote.weight(.semibold)) }
                Text("Showing new lines by polling every few seconds instead.").font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("How to fix it") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(LogStreamProblem.fullFix).font(.whCode).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8).background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
                        HStack {
                            Button { Pasteboard.copy(LogStreamProblem.sysctlCommands) } label: { Label("Copy sysctl", systemImage: "doc.on.doc") }
                            Button { Pasteboard.copy(LogStreamProblem.fullFix) } label: { Label("Copy all", systemImage: "doc.on.doc.fill") }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.top, 4)
                }
                .font(.footnote)
                if case .nodeWatchLimit(let detail)? = model.stream.problem, !detail.isEmpty {
                    Text("Kubelet said: \(detail)").font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Spacing.l).padding(.bottom, 6)
    }

    // MARK: Toolbar & shortcuts

    @ToolbarContentBuilder
    private func toolbar(_ model: LogsModel) -> some ToolbarContent {
        @Bindable var model = model
        ToolbarItem(placement: .whTrailing) {
            Button { model.isSearching.toggle(); if !model.isSearching { model.query = "" } } label: { Image(systemName: model.isSearching ? "magnifyingglass.circle.fill" : "magnifyingglass") }
                .accessibilityLabel("Search")
        }
        ToolbarItem(placement: .whTrailing) {
            Button { if let url = model.exportFileURL() { shareURL = ShareItem(url: url) } } label: { Image(systemName: "square.and.arrow.up") }
                .accessibilityLabel("Share logs").disabled(!model.hasLines)
        }
        ToolbarItem(placement: .whTrailing) {
            Menu {
                Menu("Font Size", systemImage: "textformat.size") {
                    Button("Larger", systemImage: "plus") { model.fontSize = min(model.fontSize + 1, 22) }
                    Button("Smaller", systemImage: "minus") { model.fontSize = max(model.fontSize - 1, 9) }
                }
                Toggle(isOn: $model.pinned) { Label("Keep Streaming When Leaving", systemImage: "pin") }
                Button { model.clear() } label: { Label("Clear", systemImage: "trash") }
                Button { model.reload() } label: { Label("Reload", systemImage: "arrow.clockwise") }
                Button { Pasteboard.copy(model.exportText()) } label: { Label("Copy All Lines", systemImage: "doc.on.doc") }
                Divider()
                Button(role: .destructive) { hub.close(model); self.model = nil } label: { Label("Stop Stream", systemImage: "stop.circle") }
            } label: { Image(systemName: "ellipsis.circle") }
            .accessibilityLabel("Log options")
        }
    }

    /// iPad: ⌘F search, ⌘K clear, ⌘↓ jump to live, ⌘+ / ⌘- font size.
    @ViewBuilder
    private func shortcuts(_ model: LogsModel) -> some View {
        Group {
            Button("Search") { model.isSearching.toggle() }.keyboardShortcut("f", modifiers: .command)
            #if os(macOS)
            // ⌘K is Compass on the Mac (DESIGN-MAC section 8): Clear is ⌥⌘K there.
            Button("Clear") { model.clear() }.keyboardShortcut("k", modifiers: [.command, .option])
            #else
            Button("Clear") { model.clear() }.keyboardShortcut("k", modifiers: .command)
            #endif
            Button("Jump to Live") { model.jumpToLive() }.keyboardShortcut(.downArrow, modifiers: .command).disabled(model.previous)
            Button("Larger") { model.fontSize = min(model.fontSize + 1, 22) }.keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { model.fontSize = max(model.fontSize - 1, 9) }.keyboardShortcut("-", modifiers: .command)
        }
        .hidden()
    }
}

private extension LogStream.State {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

// MARK: - Per-flush parts
//
// New lines arrive several times a second. Each part below observes only what it shows, so a flush re-renders the list (and, at most
// once a second on the Mac, the footer) instead of the whole screen with its chips, menus and toolbar.

#if os(macOS)
/// Holds the model's own stream sync while it is on screen (see `LogsModel.startStreamSync()`). Observes nothing.
private struct MacLogsStreamSync: View {
    let model: LogsModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { model.startStreamSync() }
            .onDisappear { model.stopStreamSync() }
    }
}
#else
/// Moves new lines from the stream into the model. Its own view, so only it observes `stream.revision`.
private struct LogsStreamSync: View {
    let model: LogsModel

    var body: some View {
        Color.clear
            .onChange(of: model.stream.revision) { _, _ in model.syncFromStream() }
            .onChange(of: model.stream.state) { _, _ in model.syncFromStream() }
    }
}
#endif

/// The lines (or the empty, loading and error states) and the Jump to Live button.
private struct LogsLinesPane: View {
    let model: LogsModel
    let session: ClusterSession
    var onSelect: (LogLine) -> Void
    #if os(macOS)
    @Environment(\.paneIsVisible) private var paneIsVisible
    #endif

    var body: some View {
        ZStack(alignment: .bottom) {
            list
            if !model.follow && !model.previous && model.hasLines { jumpToLive }
        }
    }

    @ViewBuilder
    private var list: some View {
        if let error = model.podError, !model.hasLines, model.stream.state != .streaming {
            EmptyState(EmptyStateKind(error: error, clusterName: session.config.name)) { Button("Retry") { Task { await model.load() } } }
        } else if case .failed(let error) = model.stream.state, !model.hasLines {
            EmptyState(EmptyStateKind(error: error, clusterName: session.config.name)) { Button("Retry") { model.reload() } }
        } else if !model.hasLines {
            if model.stream.state == .connecting || model.stream.state == .idle {
                EmptyState(.loading)
            } else if model.matchesOnly, model.matcher != nil {
                EmptyState(.filteredEmpty(filter: model.query))
            } else {
                EmptyState(.empty(title: model.previous ? "No Previous Logs" : "No Log Output",
                                  systemImage: "text.alignleft",
                                  hint: model.previous ? "This container has not been restarted, so there is no previous instance." : "This container has not written anything yet\(model.since == .all ? "" : " in the selected time range").")) {
                    if model.previous { Button("Show Current Logs") { model.setPrevious(false) } }
                }
            }
        } else {
            // The Mac table follows the model's lines itself (no SwiftUI update per flush); iOS passes them by value.
            #if os(macOS)
            LogsTableView(
                source: model,
                isPaneVisible: paneIsVisible,
                settings: LogsDisplaySettings(wrap: model.wrap, timestamps: model.timestamps, fontSize: model.fontSize, query: model.query,
                                              useRegex: model.useRegex, currentLineID: model.currentLineID),
                matcher: model.matcher, follow: model.follow, scrollTarget: model.scrollTarget,
                onUserScrolledAway: { model.userScrolledAway() }, onReachedBottom: { model.userReachedBottom() },
                onSelect: onSelect
            )
            .accessibilityLabel("Log lines")
            #else
            LogsTableView(
                lines: model.visible,
                settings: LogsDisplaySettings(wrap: model.wrap, timestamps: model.timestamps, fontSize: model.fontSize, query: model.query,
                                              useRegex: model.useRegex, currentLineID: model.currentLineID),
                matcher: model.matcher, follow: model.follow, scrollTarget: model.scrollTarget,
                onUserScrolledAway: { model.userScrolledAway() }, onReachedBottom: { model.userReachedBottom() },
                onSelect: onSelect
            )
            .accessibilityLabel("Log lines")
            #endif
        }
    }

    private var jumpToLive: some View {
        Button { model.jumpToLive() } label: {
            Label(model.newLinesWhileAway > 0 ? "Jump to Live · \(model.newLinesWhileAway) new" : "Jump to Live", systemImage: "arrow.down.to.line")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.bottom, 12)
        .transition(.scale.combined(with: .opacity))
        .accessibilityLabel("Jump to live, \(model.newLinesWhileAway) new lines")
    }
}

/// Stream state and the line counts (the throttled status values of the model).
private struct LogsFooter: View {
    let model: LogsModel

    var body: some View {
        HStack(spacing: 8) {
            switch model.stream.state {
            case .streaming where model.isPolling:
                Label("Polling (live streaming unavailable on this node)", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(Palette.warningText).lineLimit(2)
            case .streaming: HStack(spacing: 4) { LiveDot(); Text("Live").foregroundStyle(Palette.healthyText) }
            case .connecting: HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Connecting") }
            case .finished: Label(model.previous ? "Previous instance" : "Stream ended", systemImage: "checkmark.circle")
            case .paused:
                switch model.stream.pauseReason {
                case .background: Label("Paused in background", systemImage: "pause.circle")
                case .preempted: Label("Stopped: another stream took over", systemImage: "pause.circle")
                default: Label("Paused", systemImage: "pause.circle")
                }
            case .failed(let e): Label(e.summary, systemImage: "exclamationmark.triangle").foregroundStyle(Palette.criticalText)
            case .idle: EmptyView()
            }
            Spacer()
            if model.statusDroppedCount > 0 { Text("\(model.statusDroppedCount.formatted()) older dropped").foregroundStyle(Palette.warningText) }
            Text("\(model.statusLineCount.formatted()) lines").monospacedDigit()
            // A previous instance is not live: nothing to resume unless loading it failed (then it is a retry).
            if !model.previous ? (model.stream.state == .finished || model.stream.state == .paused || model.stream.state.isFailed) : model.stream.state.isFailed {
                Button("Resume") { model.stream.resume() }.font(.caption.weight(.semibold))
            }
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.l).padding(.vertical, 6)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

struct ShareItem: Identifiable { let id = UUID(); let url: URL }

#if os(iOS)
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#else
/// macOS: the system share picker through `ShareLink`. (Save to File… is added with the Mac log toolbar.)
struct ShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: Spacing.l) {
            Text(url.lastPathComponent).font(.headline)
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.xl)
        .frame(minWidth: 320)
    }
}
#endif

/// Detail of one log line: pretty-printed JSON when the line is JSON.
private struct LogLineDetailSheet: View {
    let line: LogLine
    @Environment(\.dismiss) private var dismiss

    private var pretty: String? {
        guard line.message.hasPrefix("{") || line.message.hasPrefix("["), let data = line.message.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return nil }
        return String(decoding: out, as: UTF8.self)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    if let ts = line.timestamp { LabeledContent("Time", value: ts).font(.footnote.monospaced()) }
                    if line.level != .none { LabeledContent("Level", value: line.level.label).font(.footnote) }
                    if let source = line.source { LabeledContent("Container", value: source).font(.footnote) }
                    Text(pretty ?? line.message)
                        .font(.whCode).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.m)
                        .background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code, style: .continuous))
                }
                .padding(Spacing.l)
            }
            .navigationTitle(pretty == nil ? "Log Line" : "JSON Line")
            .whInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Copy") { Pasteboard.copy(pretty ?? line.message) } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
