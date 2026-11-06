import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// DESIGN.md S4. Entry point of the Fleet tab / iPad Fleet content column.
struct FleetDashboardView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.scenePhase) private var scenePhase
    @State private var editingCluster: ClusterConfig?
    private let model = FleetModel.shared
    private let seen = AlertsSeen.shared

    private var alerts: [DashboardAlert] { model.alerts(in: registry) }

    var body: some View {
        let alerts = self.alerts
        ScrollView {
            VStack(spacing: Spacing.cardGap) {
                if registry.isDemoMode { StateBanner(.demo) { Button("Exit Demo") { preferences.demoMode = false; registry.exitDemoMode() }.font(.footnote.weight(.semibold)) } }
                healthCard
                kpiGrid
                attentionCard(alerts)
                ForEach(registry.clusters) { cluster in clusterCard(cluster) }
                cpuCard
                warningsCard
                footnote
            }
            .padding(Spacing.l)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .background(Palette.groupedBackground)
        .navigationTitle("Fleet")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button { router.push(.settings) } label: { Image(systemName: "gearshape") }.accessibilityLabel("Settings") }
            ToolbarItem(placement: .topBarTrailing) { bell(alerts) }
            ToolbarItem(placement: .topBarTrailing) { Button { router.push(.addCluster) } label: { Image(systemName: "plus") }.accessibilityLabel("Add Cluster") }
        }
        .refreshable { await model.refresh(registry: registry) }
        .sheet(item: $editingCluster) { cfg in NavigationStack { AddClusterView(editing: cfg, registry: registry) } }
        .task(id: "\(scenePhase == .active)-\(preferences.refreshInterval)") {
            guard scenePhase == .active else { return }
            await model.run(registry: registry, interval: preferences.refreshInterval)
        }
        // After the first real cluster is added, ask once for notification permission (a no-op unless never asked).
        .task(id: registry.clusters.count) {
            if !registry.isDemoMode, !registry.clusters.isEmpty, preferences.alertsEnabled { await AlertNotifier.requestAuthorizationIfNeeded() }
        }
    }

    private var subtitle: String {
        let n = registry.clusters.count
        var s = "\(n) cluster\(n == 1 ? "" : "s")"
        if let t = model.lastRefresh { s += " · updated \(Format.age(from: t)) ago" } else { s += " · updating…" }
        return s
    }

    private func bell(_ alerts: [DashboardAlert]) -> some View {
        let unseen = seen.unseenCount(in: alerts)
        return Button { router.push(.alerts) } label: {
            Image(systemName: unseen > 0 ? "bell.fill" : "bell")
        }
        .badge(unseen)
        .accessibilityLabel(unseen > 0 ? "Alerts, \(unseen) unseen" : "Alerts")
    }

    // MARK: Health ring

    private var healthCard: some View {
        var healthy = 0, degraded = 0, critical = 0, unreachable = 0, checking = 0
        for c in registry.clusters {
            guard let h = registry.health(for: c.id) else { checking += 1; continue }
            if !h.isReachable { unreachable += 1 } else {
                switch h.status { case .healthy: healthy += 1; case .warning: degraded += 1; case .critical: critical += 1; case .unknown: checking += 1 }
            }
        }
        let total = registry.clusters.count
        let reachable = total - unreachable - checking
        let needAttention = degraded + critical + unreachable
        let slices = [HealthDonut.Slice(label: "Healthy", count: healthy, color: Palette.healthy),
                      .init(label: "Degraded", count: degraded, color: Palette.warning),
                      .init(label: "Critical", count: critical, color: Palette.critical),
                      .init(label: "Unreachable", count: unreachable, color: Palette.unknown)]
        return HStack(spacing: Spacing.l) {
            HealthDonut(slices: slices, centerTitle: "\(reachable)/\(total)", centerCaption: "reachable").frame(width: 112, height: 112)
            VStack(alignment: .leading, spacing: 6) {
                Text("Fleet Health").font(.headline)
                ForEach(slices) { s in
                    HStack(spacing: 8) {
                        Circle().fill(s.color).frame(width: 9, height: 9)
                        Text(s.label).font(.subheadline)
                        Spacer(minLength: 4)
                        Text("\(s.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text(checking > 0 && needAttention == 0 ? "Checking clusters…" : needAttention == 0 ? "All clusters healthy" : "\(needAttention) cluster\(needAttention == 1 ? "" : "s") need\(needAttention == 1 ? "s" : "") attention")
                    .font(.footnote.weight(.medium)).foregroundStyle(needAttention == 0 ? Palette.healthyText : Palette.warningText)
            }
        }
        .whCard()
        .accessibilityElement(children: .contain)
    }

    // MARK: KPIs

    private var kpiGrid: some View {
        var c = ClusterCounts()
        for cl in registry.clusters {
            guard let h = registry.health(for: cl.id), h.isReachable else { continue }
            c.nodesTotal += h.counts.nodesTotal; c.nodesReady += h.counts.nodesReady; c.nodesNotReady += h.counts.nodesNotReady
            c.podsTotal += h.counts.podsTotal; c.podsRunning += h.counts.podsRunning; c.podsPending += h.counts.podsPending; c.podsFailing += h.counts.podsFailing
        }
        let u = model.fleetUsage(in: registry)
        let columns = [GridItem(.flexible(), spacing: Spacing.cardGap), GridItem(.flexible(), spacing: Spacing.cardGap)]
        return LazyVGrid(columns: columns, spacing: Spacing.cardGap) {
            KPITile(label: "Nodes Ready", value: "\(c.nodesReady)/\(c.nodesTotal)", caption: c.nodesNotReady > 0 ? "\(c.nodesNotReady) NotReady" : "All ready", tone: c.nodesNotReady > 0 ? .critical : nil)
            KPITile(label: "Pods Running", value: c.podsRunning.formatted(), caption: "\(c.podsPending) pending · \(c.podsFailing) failing", tone: c.podsFailing > 0 ? .warning : nil)
            KPITile(label: "CPU", value: u.cpuFraction.map(Format.percent) ?? "–",
                    caption: u.cpuUsage == nil ? "No metrics source" : shortUsage(cpu: u.cpuUsage, allocatable: u.cpuAllocatable), meter: u.cpuFraction)
            KPITile(label: "Memory", value: u.memFraction.map(Format.percent) ?? "–",
                    caption: u.memUsage == nil ? "No metrics source" : shortUsage(bytes: u.memUsage, allocatable: u.memAllocatable, binary: preferences.useBinaryUnits), meter: u.memFraction)
        }
    }

    // MARK: Attention

    private func attentionCard(_ alerts: [DashboardAlert]) -> some View {
        let names = Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.id, $0.name) })
        return DashCard("Needs Attention") {
            if !alerts.isEmpty { Button("See All (\(alerts.count))") { router.push(.alerts) }.font(.subheadline) }
        } content: {
            if alerts.isEmpty {
                Label(registry.clusters.allSatisfy({ registry.health(for: $0.id) != nil }) ? "Nothing needs attention" : "Checking clusters…",
                      systemImage: "checkmark.circle.fill").foregroundStyle(Palette.healthyText).font(.subheadline)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(alerts.prefix(6).enumerated()), id: \.element.id) { i, a in
                        if i > 0 { Divider() }
                        AlertRow(alert: a, clusterName: names[a.clusterID], isUnseen: !seen.isSeen(a.id))
                    }
                }
            }
        }
    }

    // MARK: Clusters

    private func clusterCard(_ cluster: ClusterConfig) -> some View {
        let session = registry.session(for: cluster.id)
        let usage = model.snapshots[cluster.id]?.usage
        return RouteLink(route: .cluster(cluster.id)) {
            ClusterCard(cluster: cluster, health: registry.health(for: cluster.id), version: session?.version?.gitVersion,
                        cpu: usage?.cpuFraction, memory: usage?.memFraction, sparkline: model.sparklines[cluster.id] ?? [],
                        credentialsMissing: session?.credentialsMissing ?? false, onEdit: { editingCluster = cluster }) {
                Task { await session?.refreshHealth() }
            }
        }
    }

    // MARK: CPU history

    @ViewBuilder private var cpuCard: some View {
        if let s = model.cpuSeries {
            DashCard(s.isHistory ? "Fleet CPU (24h)" : "Fleet CPU (live)") {
                if !s.isHistory { SourceChip(text: "Live", live: true) }
            } content: {
                if s.usage.count >= 2 {
                    MetricChart(title: "Fleet CPU", series: chartSeries(s), unit: .cores, capacity: s.capacity > 0 ? s.capacity : nil)
                } else {
                    Text("Collecting samples… the chart fills in with every refresh.").font(.footnote).foregroundStyle(.secondary)
                }
                Text(s.coverage).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chartSeries(_ s: FleetModel.FleetSeries) -> [ChartSeries] {
        var series = [ChartSeries(name: "CPU", color: Palette.chartCPU, style: .area, points: s.usage)]
        if s.requests.count >= 2 { series.append(ChartSeries(name: "Requests", color: Palette.chartRequests, style: .requests, points: s.requests)) }
        return series
    }

    // MARK: Warnings

    @ViewBuilder private var warningsCard: some View {
        let warnings = Array(model.warnings.prefix(5))
        if !warnings.isEmpty {
            DashCard("Recent Warnings") {
                VStack(spacing: 0) {
                    ForEach(Array(warnings.enumerated()), id: \.element.id) { i, w in
                        if i > 0 { Divider().padding(.vertical, 6) }
                        EventRow(clusterID: w.clusterID, event: w.event, clusterName: w.clusterName)
                    }
                }
            }
        }
    }

    // MARK: Footnote

    private var footnote: some View {
        let reachable = registry.clusters.filter { registry.health(for: $0.id)?.isReachable == true }
        let sources = reachable.map { model.snapshots[$0.id]?.metrics ?? MetricsAvailability.none }
        let ms = sources.filter(\.hasLiveUsage).count, prom = sources.filter(\.hasHistory).count
        return Text("Usage from metrics-server on \(ms) of \(reachable.count) reachable clusters; Prometheus history on \(prom). \(preferences.refreshInterval > 0 ? "Auto-refreshes every \(preferences.refreshInterval) s." : "Pull to refresh.")")
            .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}

#Preview { NavigationStack { FleetDashboardView() }.environment(ClusterRegistry.preview()).environment(AppRouter()) }
