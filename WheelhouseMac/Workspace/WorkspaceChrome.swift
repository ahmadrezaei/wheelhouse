import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

// MARK: Tab bar

/// The tab bar (DESIGN-MAC section 3.1): 30 pt, one tab per pane tree, a 2 pt stripe in the environment colour (a split stripe when
/// the tab spans several clusters), close button, + button, drag to reorder.
struct TabBar: View {
    @Environment(MacAppEnvironment.self) private var env
    let model: WorkspaceWindowModel

    var body: some View {
        let state = model.state
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(state.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabButton(model: model, tab: tab, index: index, isSelected: tab.id == state.selectedTab, canClose: state.tabs.count > 1)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button { model.newTab() } label: { Image(systemName: "plus") }
                .buttonStyle(.plain).padding(.horizontal, 10).help("New Tab").accessibilityLabel("New tab").accessibilityIdentifier("tabbar.new")
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tabbar")
    }
}

private struct TabButton: View {
    @Environment(MacAppEnvironment.self) private var env
    let model: WorkspaceWindowModel
    let tab: TabState
    let index: Int
    let isSelected: Bool
    let canClose: Bool
    @State private var hovering = false

    private var title: String { tab.focused?.title(registry: env.registry) ?? "Tab" }

    private var stripe: some View {
        let colors = tab.clusterIDs.compactMap { env.registry.config(for: $0)?.environment }.map(Self.color)
        return Group {
            if colors.isEmpty { Color.clear }
            else if colors.count == 1 { colors[0] }
            else { LinearGradient(stops: colors.enumerated().flatMap { i, c in [.init(color: c, location: Double(i) / Double(colors.count)), .init(color: c, location: Double(i + 1) / Double(colors.count))] }, startPoint: .leading, endPoint: .trailing) }
        }
        .frame(height: 2)
    }

    private static func color(_ e: ClusterEnvironment) -> Color {
        switch e {
        case .production: Palette.envProduction
        case .staging: Palette.envStaging
        case .development: Palette.tint
        case .personal: Palette.unknown
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let top = tab.focused?.top { Image(systemName: top.symbol).imageScale(.small).foregroundStyle(.secondary) }
            Text(title).font(.system(size: 12, weight: isSelected ? .semibold : .regular)).lineLimit(1).frame(maxWidth: 180)
            if canClose {
                Button { model.closeTab(tab.id) } label: { Image(systemName: "xmark").imageScale(.small) }
                    .buttonStyle(.plain).opacity(hovering || isSelected ? 1 : 0).accessibilityLabel("Close tab").help("Close Tab")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isSelected ? Color.primary.opacity(0.10) : (hovering ? Color.primary.opacity(0.05) : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(alignment: .top) { stripe.clipShape(RoundedRectangle(cornerRadius: 1)) }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.select(tab: tab.id) }
        .draggable(tab.id.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let moved = items.first.map(TabID.init(rawValue:)), model.state.tabs.contains(where: { $0.id == moved }) else { return false }
            model.moveTab(moved, to: index)
            return true
        }
        .contextMenu {
            Button("Close Tab") { model.closeTab(tab.id) }.disabled(!canClose)
            Button("Move Tab to New Window") { model.moveTabToNewWindow(tab.id) }.disabled(!canClose)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("tab.\(index)")
    }
}

// MARK: Status bar

/// The status bar (24 pt): connection dot, cluster, server version and latency, the context's source, whether changes are allowed
/// and the energy throttle. Gangway state, watches, port-forwards and Beacon join with their milestones.
struct StatusBar: View {
    @Environment(MacAppEnvironment.self) private var env
    let model: WorkspaceWindowModel

    var body: some View {
        let registry = env.registry
        let cluster = model.focusedPane?.context.clusterID.flatMap { registry.config(for: $0) }
        HStack(spacing: 14) {
            if let cluster {
                let health = registry.health(for: cluster.id)
                HStack(spacing: 5) {
                    Circle().fill(dot(health)).frame(width: 7, height: 7)
                    Text(cluster.name)
                    if let health { Text(health.isReachable ? health.issueSummary : "Unreachable").foregroundStyle(.secondary).lineLimit(1) }
                }
                .accessibilityElement(children: .combine)
                Text(cluster.readOnly ? "Read-only" : "Changes allowed").foregroundStyle(.secondary)
                if cluster.isDemo { Text("Demo").foregroundStyle(.secondary) } else if let origin = cluster.origin { Text(Self.source(origin)).foregroundStyle(.secondary).lineLimit(1) }
            } else {
                Text("No cluster in this pane").foregroundStyle(.secondary)
            }
            Spacer()
            if EnergyPolicy.current.isConstrained { Label("Energy saver", systemImage: "leaf").foregroundStyle(.secondary) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statusbar")
    }

    private func dot(_ health: ClusterHealth?) -> Color {
        guard let health, health.isReachable else { return Palette.unknown }
        switch health.status {
        case .critical: return Palette.critical
        case .warning: return Palette.warning
        case .healthy: return Palette.healthy
        default: return Palette.unknown
        }
    }

    /// Where the context came from, as the status bar words it.
    static func source(_ origin: ClusterOrigin) -> String {
        switch origin {
        case .kubeconfig(let path, let context, _): "\((path as NSString).abbreviatingWithTildeInPath) · \(context)"
        case .landfall(let provider, let account, _): "Landfall · \(provider) \(account)"
        }
    }

}

// MARK: Inspector

/// The trailing inspector (⌥⌘0): Details, Events and First Mate for the selection, which is the focused pane's top route. The
/// Events segment builds (and fetches) only while it is selected.
struct InspectorView: View {
    @Environment(MacAppEnvironment.self) private var env
    let model: WorkspaceWindowModel

    private var segment: InspectorState.Segment {
        if case .window(let id) = model.scope { model.store.state(for: id).inspector.segment } else { .details }
    }

    private var ref: ResourceRef? {
        switch model.focusedPane?.top {
        case .route(.resourceDetail(let r)), .route(.yaml(let r)), .route(.logs(let r, _, _)), .route(.shell(let r, _)), .route(.portForward(let r)): r
        case .gitopsApp(let r): r
        default: nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: Binding(get: { segment }, set: { value in model.mutate { $0.inspector.segment = value } })) {
                Text("Details").tag(InspectorState.Segment.details)
                Text("Events").tag(InspectorState.Segment.events)
                Text("First Mate").tag(InspectorState.Segment.firstMate)
            }
            .pickerStyle(.segmented).labelsHidden().padding(10)
            .accessibilityIdentifier("inspector.segments")
            Divider()
            Group {
                switch segment {
                case .details: InspectorDetails(ref: ref, cluster: model.focusedPane?.context.clusterID)
                case .events: InspectorEvents(ref: ref)
                case .firstMate: FeatureRegistry.view(for: .firstMate("inspector")) ?? AnyView(EmptyState(.empty(title: "First Mate", systemImage: "sparkles", hint: "Not available in this build.")))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector")
    }
}

private struct InspectorDetails: View {
    @Environment(ClusterRegistry.self) private var registry
    let ref: ResourceRef?
    let cluster: ClusterID?

    var body: some View {
        if let ref {
            Form {
                LabeledContent("Kind", value: ref.kind.displayName)
                LabeledContent("Name", value: ref.name)
                if let ns = ref.namespace { LabeledContent("Namespace", value: ns) }
                LabeledContent("Cluster", value: registry.config(for: ref.clusterID)?.name ?? ref.clusterID)
                if let health = registry.health(for: ref.clusterID) { LabeledContent("Cluster health", value: health.issueSummary) }
            }
            .formStyle(.grouped)
        } else if let cluster, let health = registry.health(for: cluster) {
            Form {
                LabeledContent("Cluster", value: registry.config(for: cluster)?.name ?? cluster)
                LabeledContent("Health", value: health.issueSummary)
            }
            .formStyle(.grouped)
        } else {
            EmptyState(.empty(title: "Nothing selected", systemImage: "info.circle", hint: "Open a resource to see its details here."))
        }
    }
}

private struct InspectorEvents: View {
    @Environment(ClusterRegistry.self) private var registry
    let ref: ResourceRef?
    @State private var events: [KubeEvent] = []
    @State private var loaded = false

    var body: some View {
        Group {
            if ref == nil {
                EmptyState(.empty(title: "No events", systemImage: "bolt", hint: "Open a resource to see its events."))
            } else if !loaded {
                ProgressView().controlSize(.small).padding()
            } else if events.isEmpty {
                Text("No events recorded for this object.").foregroundStyle(.secondary).padding()
            } else {
                List(events.prefix(100)) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.reason ?? "Event").font(.subheadline.weight(.medium)).foregroundStyle(e.isWarning ? Palette.warningText : .primary)
                        if let m = e.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .task(id: ref?.id) {
            loaded = false
            guard let ref, let session = registry.session(for: ref.clusterID) else { events = []; loaded = true; return }
            let field = "involvedObject.name=\(ref.name)"
            let list = try? await session.client.list(KubeEvent.self, namespace: ref.kind.namespaced ? ref.namespace : nil, options: ListOptions(fieldSelector: field))
            events = (list?.items ?? []).filter { $0.involvedObject.kind == nil || $0.involvedObject.kind == ref.kind.kind }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            loaded = true
        }
    }
}
