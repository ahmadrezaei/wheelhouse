import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The menu bar glyph (DESIGN-MAC section 6.15): the helm, with a badge when something needs attention and, optionally, a count.
/// It reads the small `FleetSummary` the monitor publishes only when it changes, never the registry's health, so it costs nothing
/// between checks. It also keeps the window opener fresh: the opener captured by a closed window goes stale, and this label lives as
/// long as the menu bar item does.
struct CrowsNestLabel: View {
    let env: MacAppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let summary = env.fleet.summary
        let badge = env.macPreferences.menuBarBadge
        HStack(spacing: 2) {
            Image(systemName: summary.level == .healthy || badge == .off ? "steeringwheel" : "steeringwheel.badge.exclamationmark")
            if badge == .dotAndCount, summary.attentionCount > 0 { Text("\(summary.attentionCount)") }
        }
        .accessibilityLabel(summary.level == .healthy ? "Crow's Nest, all clear" : "Crow's Nest, \(summary.attentionCount) need attention")
        .onAppear { register() }
    }

    private func register() {
        let open = openWindow
        env.workspace.openWorkspaceWindow = { open(value: $0) }
        env.workspace.openDetachedWindow = { open(value: $0) }
    }
}

/// The panel (360 pt): fleet attention, clusters, Beacon, and the footer actions. While App Lock is on it shows "Locked" and nothing
/// else. It starts no watch and no timer of its own: it shows what the monitor and the registry already know.
struct CrowsNestPanel: View {
    let env: MacAppEnvironment
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if env.lock.isLocked {
                Label("Locked", systemImage: "lock.fill").font(.headline).frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 24)
                    .accessibilityIdentifier("crowsnest.locked")
                Divider()
                Button("Quit Wheelhouse") { NSApp.terminate(nil) }.buttonStyle(.plain)
            } else {
                header
                attention
                clusters
                beacon
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear { env.workspace.openWorkspaceWindow = { [openWindow] in openWindow(value: $0) } }
    }

    private var registry: ClusterRegistry { env.registry }

    private var header: some View {
        let summary = env.fleet.summary
        return HStack {
            VStack(alignment: .leading) {
                Text("Fleet").font(.headline)
                Text(summary.attentionCount == 0 ? "All clear · \(registry.clusters.count) clusters" : "\(summary.attentionCount) need attention · \(registry.clusters.count) clusters")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = env.fleet.lastCheck { Text("Checked \(last.formatted(date: .omitted, time: .shortened))").font(.caption2).foregroundStyle(.tertiary) }
                if env.fleet.isPaused { Text("Checks paused").font(.caption2).foregroundStyle(Palette.warningText) }
            }
            Spacer()
            Button { Task { await env.fleet.tick(force: true) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Check Now").accessibilityLabel("Check now")
        }
    }

    @ViewBuilder private var attention: some View {
        let items = Array(registry.fleetAttention.prefix(5))
        if !items.isEmpty {
            Text("Needs attention").font(.caption).foregroundStyle(.secondary)
            ForEach(items) { item in
                Button { open(item) } label: {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: item.severity == .critical ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(item.severity == .critical ? Palette.critical : Palette.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).font(.callout)
                            Text("\(registry.config(for: item.clusterID)?.name ?? item.clusterID) · \(item.detail)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var clusters: some View {
        if !registry.clusters.isEmpty {
            Text("Clusters").font(.caption).foregroundStyle(.secondary)
            ForEach(registry.clusters.prefix(12)) { cluster in
                Button { showCluster(cluster.id) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(color(registry.health(for: cluster.id)?.status)).frame(width: 8, height: 8)
                        Text(cluster.name).font(.callout)
                        EnvBadge(cluster.environment)
                        Spacer(minLength: 4)
                        Text(registry.health(for: cluster.id)?.issueSummary ?? "Not checked").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Beacon's state, read from the hub so the panel never starts Beacon.
    @ViewBuilder private var beacon: some View {
        if let model = BeaconModelHub.shared.model, model.isOn {
            Divider()
            HStack {
                Label("Beacon on · \(model.clients.count) client\(model.clients.count == 1 ? "" : "s")", systemImage: "dot.radiowaves.up.forward").font(.callout)
                Spacer()
                Button("Stop Beacon") { model.turnOff() }.controlSize(.small)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button("Open Compass") { showWorkspace { env.compass.open() } }.keyboardShortcut("k")
            Button("Open Wheelhouse") { showWorkspace() }
            if env.fleet.isPaused { Button("Resume Checks") { env.fleet.resume() } } else { Button("Pause Checks for 1 Hour") { env.fleet.pause() } }
            Button("Settings…") { env.activationPolicy.prepareForWindow(); NSApp.activate(); openSettings() }
            Button("Quit Wheelhouse") { NSApp.terminate(nil) }
        }
        .buttonStyle(.plain)
    }

    private func color(_ status: HealthStatus?) -> Color {
        switch status {
        case .critical: Palette.critical
        case .warning: Palette.warning
        case .healthy: Palette.healthy
        default: .gray
        }
    }

    /// Brings a workspace window forward (opening one first when none exists) and then runs `then` on its model.
    private func showWorkspace(then: @escaping @MainActor () -> Void = {}) {
        env.showWorkspace()
        Task { @MainActor in
            // The window opens on the next turn; its model is the active one by then.
            try? await Task.sleep(for: .milliseconds(150))
            then()
        }
    }

    private func open(_ item: AttentionItem) {
        showWorkspace {
            guard let model = env.workspace.activeModel else { return }
            if let ref = item.resource { model.show(WorkspaceWindowModel.destination(for: ref), placement: .newTab) } else { model.activate(cluster: item.clusterID, placement: .newTab) }
        }
    }

    private func showCluster(_ id: ClusterID) {
        showWorkspace { env.workspace.activeModel?.activate(cluster: id, placement: .newTab) }
    }
}
