import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// DESIGN.md S6. Everything that needs attention across the fleet, grouped by severity or cluster. Seen state lives in memory.
struct AlertsInboxView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    private let model = FleetModel.shared
    private let seen = AlertsSeen.shared

    enum Grouping: String, CaseIterable, Identifiable { case severity = "Severity", cluster = "Cluster"; var id: String { rawValue } }
    @State private var grouping: Grouping = .severity
    @State private var filter: HealthStatus?
    @State private var unseenOnly = false

    private var names: [ClusterID: String] { Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.id, $0.name) }) }

    private var visible: [DashboardAlert] {
        model.alerts(in: registry).filter { a in
            (filter == nil || a.severity == filter) && (!unseenOnly || !seen.isSeen(a.id))
        }
    }

    private struct Group: Identifiable { var id: String; var title: String; var tone: StatusTone?; var alerts: [DashboardAlert] }

    private func groups(_ alerts: [DashboardAlert]) -> [Group] {
        switch grouping {
        case .severity:
            let order: [HealthStatus] = [.critical, .warning, .unknown]
            return order.compactMap { s in
                let items = alerts.filter { $0.severity == s }
                return items.isEmpty ? nil : Group(id: s.rawValue, title: s == .warning ? "Degraded" : s.title, tone: StatusTone(s), alerts: items)
            }
        case .cluster:
            return registry.clusters.compactMap { c in
                let items = alerts.filter { $0.clusterID == c.id }
                return items.isEmpty ? nil : Group(id: c.id, title: c.name, tone: nil, alerts: items)
            }
        }
    }

    var body: some View {
        let all = model.alerts(in: registry)
        let shown = visible
        List {
            if let t = model.lastRefresh {
                Text("Checked \(Format.age(from: t)) ago across \(registry.clusters.count) cluster\(registry.clusters.count == 1 ? "" : "s"). Background checks run when iOS allows.")
                    .font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
            }
            ForEach(groups(shown)) { g in
                Section {
                    ForEach(g.alerts) { a in
                        AlertRow(alert: a, clusterName: grouping == .severity ? names[a.clusterID] : nil, isUnseen: !seen.isSeen(a.id))
                            .swipeActions(edge: .leading) {
                                if seen.isSeen(a.id) { Button { seen.markUnseen(a.id) } label: { Label("Unseen", systemImage: "circle.fill") }.tint(Palette.info) }
                                else { Button { seen.markSeen([a.id]) } label: { Label("Seen", systemImage: "checkmark") }.tint(Palette.tint) }
                            }
                    }
                } header: {
                    HStack(spacing: 6) {
                        if let tone = g.tone { Image(systemName: tone.symbol).foregroundStyle(tone.color) }
                        Text(g.title)
                        Text("\(g.alerts.count)").foregroundStyle(.secondary).monospacedDigit()
                        if grouping == .cluster, let c = registry.config(for: g.id) { EnvBadge(c.environment) }
                    }
                }
            }
        }
        .overlay {
            if shown.isEmpty {
                if model.lastRefresh == nil { EmptyState(.loading) }
                else if all.isEmpty { EmptyState(.empty(title: "All Clear", systemImage: "checkmark.circle", hint: "Nothing needs attention across your clusters.")) }
                else { EmptyState(.filteredEmpty(filter: unseenOnly ? "unseen alerts" : (filter?.title ?? "filter"))) { Button("Clear Filters") { filter = nil; unseenOnly = false } } }
            }
        }
        .navigationTitle("Alerts")
        .navigationSubtitle(all.isEmpty ? "" : "\(seen.unseenCount(in: all)) unseen of \(all.count)")
        .toolbar {
            ToolbarItem(placement: .whTrailing) {
                Menu {
                    Picker("Group by", selection: $grouping) { ForEach(Grouping.allCases) { Text($0.rawValue).tag($0) } }
                    Picker("Severity", selection: $filter) {
                        Text("All Severities").tag(HealthStatus?.none)
                        Text("Critical").tag(HealthStatus?.some(.critical))
                        Text("Degraded").tag(HealthStatus?.some(.warning))
                        Text("Unknown").tag(HealthStatus?.some(.unknown))
                    }
                    Toggle("Unseen Only", isOn: $unseenOnly)
                } label: { Image(systemName: filter != nil || unseenOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel("Filter and group")
            }
            ToolbarItem(placement: .whTrailing) {
                Button { seen.markSeen(all.map(\.id)) } label: { Image(systemName: "checkmark.circle") }
                    .disabled(seen.unseenCount(in: all) == 0).accessibilityLabel("Mark all seen")
            }
        }
        .refreshable { await model.refresh(registry: registry) }
        .task(id: "\(scenePhase == .active)-\(preferences.refreshInterval)-\(EnergyMonitor.shared.policy.refreshMultiplier)") {
            guard scenePhase == .active else { return }
            await model.run(registry: registry, interval: preferences.refreshInterval)
        }
    }
}
