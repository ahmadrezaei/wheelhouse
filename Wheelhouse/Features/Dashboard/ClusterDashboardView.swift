import SwiftUI
import UIKit
import WheelhouseKit
import WheelhouseUI

/// DESIGN.md S5. `clusterID == nil` means the current cluster (Cluster tab). Wide containers (iPad detail column) use two columns.
struct ClusterDashboardView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppPreferences.self) private var preferences
    var clusterID: ClusterID?

    @State private var selectedID: ClusterID?
    @State private var model = ClusterDashModel()
    @State private var range: MetricsRange = .hour
    @State private var topMetric: TopMetric = .cpu
    @State private var width: CGFloat = 0

    enum TopMetric: String, CaseIterable, Identifiable { case cpu = "CPU", memory = "Memory"; var id: String { rawValue } }

    /// The Cluster tab (`clusterID == nil`) always follows the registry, so deep links and the switcher agree.
    /// A pushed or iPad instance (`clusterID != nil`) may be switched locally with the title menu.
    private var effectiveID: ClusterID? { clusterID == nil ? registry.currentCluster?.id : (selectedID ?? clusterID) }
    private var session: ClusterSession? { effectiveID.flatMap { registry.session(for: $0) } }
    private var isWide: Bool { width >= 780 }

    var body: some View {
        Group {
            if let session {
                Content(session: session, model: model, range: $range, topMetric: $topMetric, isWide: isWide, binaryUnits: preferences.useBinaryUnits,
                        refreshInterval: preferences.refreshInterval)
                    .id(session.id)
            } else {
                EmptyState(.empty(title: "No Cluster", systemImage: "server.rack", hint: "Add a cluster to see its dashboard."))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(Palette.groupedBackground)
        .navigationTitle(session?.config.name ?? "Cluster")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { switcher }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let session {
                        Button { Task { await model.refresh(session, range: range) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        Button { UIPasteboard.general.string = session.config.server.absoluteString } label: { Label("Copy Server URL", systemImage: "doc.on.doc") }
                    }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("More")
            }
        }
        .onChange(of: effectiveID) { _, _ in model.reset() }
        .task(id: "\(effectiveID ?? "")-\(scenePhase == .active)-\(preferences.refreshInterval)") {
            guard let session, scenePhase == .active else { return }
            // Metrics first sample quickly so the live chart has two points soon after opening.
            var first = true
            let configured = preferences.refreshInterval
            while !Task.isCancelled {
                await model.refresh(session, range: range)
                guard configured > 0 else { return }   // Manual: refresh once, then only on pull-to-refresh
                let interval = first && UsageHistory.shared.samples(for: session.id).count < 2 ? min(6, configured) : configured
                first = false
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        .onChange(of: range) { _, new in
            guard let session else { return }
            Task { await model.loadHistory(session, range: new) }
        }
    }

    private var switcher: some View {
        Menu {
            ForEach(registry.clusters) { c in
                let status = registry.health(for: c.id)?.status ?? .unknown
                Button {
                    if clusterID == nil { registry.select(c.id) } else { selectedID = c.id }
                } label: {
                    Label(c.name + (c.id == session?.id ? "  ✓" : ""), systemImage: status.symbol)
                }
            }
            Divider()
            Button { router.push(.settings) } label: { Label("Manage Clusters…", systemImage: "gearshape") }
        } label: {
            HStack(spacing: 4) {
                Text(session?.config.name ?? "Cluster").font(.headline)
                Image(systemName: "chevron.down.circle.fill").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("Cluster: \(session?.config.name ?? "none"). Switch cluster")
    }

    // MARK: - Content

    private struct Content: View {
        let session: ClusterSession
        let model: ClusterDashModel
        @Binding var range: MetricsRange
        @Binding var topMetric: TopMetric
        let isWide: Bool
        let binaryUnits: Bool
        let refreshInterval: Int
        @Environment(ClusterRegistry.self) private var registry
        @Environment(AppRouter.self) private var router

        @State private var editing: ClusterConfig?
        private let history = UsageHistory.shared
        private let fleet = FleetModel.shared

        // Shared stores (one watch per key across the app).
        private var nodesStore: ResourceStore<Node> { session.store(for: Node.self) }
        private var podsStore: ResourceStore<Pod> { session.store(for: Pod.self) }
        private var deploymentsStore: ResourceStore<Deployment> { session.store(for: Deployment.self) }
        private var statefulStore: ResourceStore<StatefulSet> { session.store(for: StatefulSet.self) }
        private var daemonStore: ResourceStore<DaemonSet> { session.store(for: DaemonSet.self) }
        private var jobsStore: ResourceStore<Job> { session.store(for: Job.self) }
        private var eventsStore: ResourceStore<KubeEvent> { session.store(for: KubeEvent.self, fieldSelector: "type=Warning") }

        private typealias Derived = ClusterDashModel.Dash

        var body: some View {
            Group {
                if session.credentialsMissing {
                    credentialsMissing
                } else if session.health?.isReachable == false {
                    unreachable
                } else if let dash = model.dash, session.health != nil || !dash.nodes.isEmpty {
                    dashboard(dash)
                } else {
                    ScrollView { SkeletonList(rows: 8).padding(Spacing.l) }.accessibilityLabel("Loading")
                }
            }
                .refreshable { await model.refresh(session, range: range) }
            .task(id: session.id) { await runStores() }
        }

        private func runStores() async {
            let nodes = nodesStore, pods = podsStore, deployments = deploymentsStore, sts = statefulStore
            let ds = daemonStore, jobs = jobsStore
            let events = eventsStore
            events.sortOrder = { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await nodes.run() }
                g.addTask { await pods.run() }
                g.addTask { await deployments.run() }
                g.addTask { await sts.run() }
                g.addTask { await ds.run() }
                g.addTask { await jobs.run() }
                g.addTask { await events.run() }
                g.addTask { await model.pollStores(session) }
            }
        }

        private var credentialsMissing: some View {
            ScrollView {
                VStack(spacing: Spacing.cardGap) {
                    ContextLine(cluster: session.config, namespace: nil, showsNamespace: false)
                    EmptyState(.credentialsMissing(clusterName: session.config.name)) {
                        Button("Edit Cluster") { editing = session.config }.buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 320)
                }
                .padding(Spacing.l)
            }
            .sheet(item: $editing) { cfg in
                NavigationStack { AddClusterView(editing: cfg, registry: registry) }
            }
        }

        private var unreachable: some View {
            ScrollView {
                VStack(spacing: Spacing.cardGap) {
                    ContextLine(cluster: session.config, namespace: nil, showsNamespace: false)
                    EmptyState(.unreachable(cause: session.health?.items.first?.detail ?? "The API server did not respond.")) {
                        Button("Retry") { Task { await model.refresh(session, range: range) } }.buttonStyle(.borderedProminent)
                    }
                    .frame(minHeight: 320)
                }
                .padding(Spacing.l)
            }
        }

        // MARK: Layout

        private func dashboard(_ d: Derived) -> some View {
            let availability = session.metricsAvailability ?? MetricsAvailability.none
            return ScrollView {
                VStack(alignment: .leading, spacing: Spacing.cardGap) {
                    header(availability, forbidden: d.forbidden)
                    summary(d)
                    if isWide {
                        HStack(alignment: .top, spacing: Spacing.cardGap) {
                            VStack(spacing: Spacing.cardGap) {
                                cpuCard(d, availability); memoryCard(d, availability); podsCard(d); heatCard(d)
                            }
                            VStack(spacing: Spacing.cardGap) {
                                attentionCard; failingCard(d); topPodsCard(availability); eventsCard(d); controlPlaneCard(d); workloadsCard
                            }
                        }
                    } else {
                        attentionCard; cpuCard(d, availability); memoryCard(d, availability); podsCard(d); heatCard(d)
                        failingCard(d); topPodsCard(availability); eventsCard(d); controlPlaneCard(d); workloadsCard
                    }
                    footnote(availability)
                }
                .padding(Spacing.l)
            }
        }

        // MARK: Header & summary

        @ViewBuilder private func header(_ availability: MetricsAvailability, forbidden: [String]) -> some View {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ContextLine(cluster: session.config, namespace: registry.namespace(for: session.id), showsNamespace: false)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                if availability == .none { StateBanner(.noMetrics) }
                else if !availability.hasHistory { StateBanner(.partialMetrics) }
                if !forbidden.isEmpty { StateBanner(.partiallyForbidden(detail: "You cannot list \(forbidden.joined(separator: ", ")) on this cluster; related cards are incomplete.")) }
                else if let h = session.health, h.isPartial {
                    StateBanner(.partiallyForbidden(detail: "Couldn’t load \(h.failedKinds.joined(separator: ", ")) in the last check, so health may be incomplete."))
                }
            }
        }

        private var subtitle: String {
            [session.config.provider, session.config.region, session.version?.gitVersion,
             session.latency.map { "API \(Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000))ms" },
             session.health?.isStale == true ? "connection problem, showing the last result" : nil,
             model.lastRefresh.map { "updated \(Format.age(from: $0)) ago" }].compactMap { $0 }.joined(separator: " · ")
        }

        private func summary(_ d: Derived) -> some View {
            let c = session.health?.counts ?? ClusterCounts()
            let cols = isWide ? 4 : 2
            return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.cardGap), count: cols), spacing: Spacing.cardGap) {
                KPITile(label: "Nodes Ready", value: "\(c.nodesReady)/\(c.nodesTotal)", caption: c.nodesNotReady > 0 ? "\(c.nodesNotReady) NotReady" : (c.nodesCordoned > 0 ? "\(c.nodesCordoned) cordoned" : "All ready"), tone: c.nodesNotReady > 0 ? .critical : nil)
                KPITile(label: "Pods Running", value: "\(c.podsRunning)/\(c.podsTotal)", caption: "\(c.podsPending) pending · \(c.podsFailing) failing", tone: c.podsFailing > 0 ? .warning : nil)
                KPITile(label: "Namespaces", value: "\(c.namespaces)", caption: "\(c.deploymentsAvailable)/\(c.deploymentsTotal) deployments available")
                KPITile(label: "Version", value: session.version?.gitVersion ?? "–", caption: sourceName)
            }
        }

        private var sourceName: String {
            switch session.metricsAvailability {
            case .some(.both): "metrics-server + Prometheus"
            case .some(.metricsServer): "metrics-server"
            case .some(.prometheus): "Prometheus"
            case .some(.none): "No metrics source"
            case nil: "Detecting metrics…"
            }
        }

        // MARK: Usage cards

        private enum Resource { case cpu, memory }

        private func chartPoints(for resource: Resource, usage: ClusterUsage) -> (series: [ChartSeries], capacity: Double?, isLive: Bool)? {
            let color = resource == .cpu ? Palette.chartCPU : Palette.chartMemory
            let name = resource == .cpu ? "CPU" : "Memory"
            if let p = model.prom, !p.isEmpty {
                let u = resource == .cpu ? p.cpuUsage : p.memUsage
                let r = resource == .cpu ? p.cpuRequests : p.memRequests
                var s = [ChartSeries(name: name, color: color, style: .area, points: u)]
                if r.count > 1 { s.append(ChartSeries(name: "Requests", color: Palette.chartRequests, style: .requests, points: r)) }
                let alloc = resource == .cpu ? (usage.cpuAllocatable > 0 ? usage.cpuAllocatable : p.cpuAllocatable) : (usage.memAllocatable > 0 ? usage.memAllocatable : p.memAllocatable)
                return (s, alloc, false)
            }
            let samples = history.samples(for: session.id)
            guard samples.count >= 2 else { return nil }
            var s = [ChartSeries(name: name, color: color, style: .area, points: samples.map { MetricPoint(time: $0.time, value: resource == .cpu ? $0.cpuUsage : $0.memUsage) })]
            let reqs = samples.compactMap { smp in (resource == .cpu ? smp.cpuRequests : smp.memRequests).map { MetricPoint(time: smp.time, value: $0) } }
            if reqs.count > 1 { s.append(ChartSeries(name: "Requests", color: Palette.chartRequests, style: .requests, points: reqs)) }
            return (s, resource == .cpu ? samples.last?.cpuAllocatable : samples.last?.memAllocatable, true)
        }

        private func cpuCard(_ d: Derived, _ availability: MetricsAvailability) -> some View { usageCard(.cpu, d, availability) }
        private func memoryCard(_ d: Derived, _ availability: MetricsAvailability) -> some View { usageCard(.memory, d, availability) }

        private func usageCard(_ resource: Resource, _ d: Derived, _ availability: MetricsAvailability) -> some View {
            let u = d.usage
            let isCPU = resource == .cpu
            let used = isCPU ? u.cpuUsage : u.memUsage
            let alloc = isCPU ? u.cpuAllocatable : u.memAllocatable
            let fraction = isCPU ? u.cpuFraction : u.memFraction
            let reqFraction = isCPU ? u.cpuRequestFraction : u.memRequestFraction
            let requests = isCPU ? u.cpuRequests : u.memRequests
            let binary = binaryUnits
            let format: (Double) -> String = { isCPU ? Quantity.formatCPU(cores: $0) : Quantity.formatBytes($0, binary: binary) }
            let chart = chartPoints(for: resource, usage: u)
            return DashCard(isCPU ? "CPU" : "Memory") {
                if availability.hasHistory { rangePicker } else if availability.hasLiveUsage { SourceChip(text: "Live", live: true) }
            } content: {
                VStack(alignment: .leading, spacing: 4) {
                    if let used {
                        HStack(alignment: .firstTextBaseline) {
                            Text(format(used)).font(.whKPI)
                            Text("of \(format(alloc))\(isCPU ? " cores" : "")").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(fraction.map(Format.percent) ?? "–").font(.title3.weight(.semibold).monospacedDigit())
                        }
                        Meter(value: fraction ?? 0, request: reqFraction, height: 6)
                    } else if let requests {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Requested \(format(requests))").font(.title3.weight(.semibold))
                            Text("of \(format(alloc))").font(.subheadline).foregroundStyle(.secondary)
                            Spacer()
                            Text(reqFraction.map(Format.percent) ?? "–").font(.title3.weight(.semibold).monospacedDigit())
                        }
                        Meter(value: reqFraction ?? 0, height: 6, tint: Palette.chartRequests)
                    } else {
                        Text("Waiting for node data…").font(.footnote).foregroundStyle(.secondary)
                    }
                    if used != nil, let requests {
                        Text("Requests \(format(requests))\(reqFraction.map { " (\(Format.percent($0)) of allocatable)" } ?? "")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let chart {
                    MetricChart(title: isCPU ? "CPU" : "Memory", series: chart.series, unit: isCPU ? .cores : .bytes, capacity: chart.capacity)
                    HStack(spacing: 12) {
                        legend(isCPU ? Palette.chartCPU : Palette.chartMemory, "Usage")
                        if chart.series.count > 1 { legend(Palette.chartRequests, "Requests", dashed: true) }
                        if chart.capacity != nil { legend(Palette.chartCapacity, "Capacity") }
                    }
                } else if availability.hasLiveUsage {
                    Label(model.isLoadingHistory ? "Loading history…" : "Collecting live samples…", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if availability.hasHistory, model.historyFailed {
                    Label("Prometheus returned no data for this range.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }

        private func legend(_ color: Color, _ text: String, dashed: Bool = false) -> some View {
            HStack(spacing: 5) {
                Rectangle().fill(color).frame(width: 14, height: dashed ? 2 : 3).mask { dashed ? AnyView(HStack(spacing: 2) { ForEach(0..<3, id: \.self) { _ in Rectangle() } }) : AnyView(Rectangle()) }
                Text(text).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }

        private var rangePicker: some View {
            Picker("Range", selection: $range) { ForEach(MetricsRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(maxWidth: 220).labelsHidden().accessibilityLabel("Time range")
        }

        // MARK: Pods

        private func podsCard(_ d: Derived) -> some View {
            let b = d.breakdown
            let parts: [(String, Int, Color)] = [("Healthy", b.healthy, Palette.healthy), ("Crash / error", b.crashing, Palette.critical), ("Pending", b.pending, Palette.warning),
                                                 ("Failed", b.failed, Palette.criticalText), ("Completed", b.completed, Palette.unknown)]
            return DashCard("Pods") {
                Text("\(b.total) total").font(.subheadline).foregroundStyle(.secondary)
            } content: {
                if b.total == 0 {
                    Text(d.podsLoading ? "Loading pods…" : "No pods").font(.footnote).foregroundStyle(.secondary)
                } else {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(parts.filter { $0.1 > 0 }, id: \.0) { p in
                                RoundedRectangle(cornerRadius: 3).fill(p.2).frame(width: max(6, geo.size.width * CGFloat(p.1) / CGFloat(b.total)))
                            }
                        }
                    }
                    .frame(height: 14).clipShape(RoundedRectangle(cornerRadius: 5))
                    .accessibilityHidden(true)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 6) {
                        ForEach(parts, id: \.0) { p in
                            HStack(spacing: 6) {
                                Circle().fill(p.2).frame(width: 9, height: 9)
                                Text(p.0).font(.footnote)
                                Text("\(p.1)").font(.footnote.monospacedDigit().weight(.semibold))
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }

        // MARK: Heat map

        private func heatCard(_ d: Derived) -> some View {
            let live = d.heatIsLive
            let tiles = d.heat
            let types = d.nodeTypes
            return DashCard("Nodes · CPU\(live ? "" : " requested")") {
                if tiles.isEmpty {
                    Text(d.nodesLoading ? "Loading nodes…" : "No nodes visible").font(.footnote).foregroundStyle(.secondary)
                } else {
                    HeatGrid(tiles: tiles) { tile in
                        router.push(.resourceDetail(ResourceRef(clusterID: session.id, kind: .node, name: tile.id)))
                    }
                    HStack(spacing: 10) {
                        legend(Palette.tint.opacity(0.6), "< 80%")
                        legend(Palette.warning, "≥ 80%")
                        legend(Palette.critical, "NotReady")
                    }
                    if !types.isEmpty { Text(types).font(.caption).foregroundStyle(.secondary) }
                    if !live { Text("No live node usage; tiles show the share of allocatable CPU requested by pods.").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }

        // MARK: Attention & failing workloads

        private var attentionCard: some View {
            let items = (session.health?.items ?? []).map(DashboardAlert.init(item:))
            return DashCard("Needs Attention") {
                if items.count > 5 { Text("\(items.count) total").font(.subheadline).foregroundStyle(.secondary) }
            } content: {
                if items.isEmpty {
                    Label("All workloads healthy", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Palette.healthyText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(5).enumerated()), id: \.element.id) { i, a in
                            if i > 0 { Divider() }
                            AlertRow(alert: a, isUnseen: false)
                        }
                    }
                }
            }
        }

        private func failingCard(_ d: Derived) -> some View {
            let rows = d.failing
            return DashCard("Failing Workloads") {
                if rows.count > 6 { Text("\(rows.count) total").font(.subheadline).foregroundStyle(.secondary) }
            } content: {
                if rows.isEmpty {
                    Label("Every workload has its replicas", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(Palette.healthyText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(rows.prefix(6).enumerated()), id: \.element.id) { i, r in
                            if i > 0 { Divider() }
                            RouteLink(route: .resourceDetail(r.ref)) { ResourceRow(title: r.title, subtitle: r.subtitle, lead: r.lead, trailing: r.trailing) }
                        }
                    }
                }
            }
        }

        // MARK: Top pods

        private func topPodsCard(_ availability: MetricsAvailability) -> some View {
            let isCPU = topMetric == .cpu
            let top = isCPU ? model.topCPU : model.topMemory
            let scale = max(top.first?.value ?? 1, 0.0001)
            let binary = binaryUnits
            return DashCard("Top Pods") {
                Picker("Metric", selection: $topMetric) { ForEach(TopMetric.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).frame(maxWidth: 180).labelsHidden()
            } content: {
                if !availability.hasLiveUsage {
                    Text("Pod usage needs metrics-server.").font(.footnote).foregroundStyle(.secondary)
                } else if top.isEmpty {
                    Text("No pod metrics yet.").font(.footnote).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(top) { e in
                            RouteLink(route: .resourceDetail(e.ref)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(e.name).font(.subheadline).lineLimit(1).truncationMode(.middle)
                                            Text(e.namespace).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer(minLength: 6)
                                        Text(isCPU ? Quantity.formatCPU(cores: e.value) : Quantity.formatBytes(e.value, binary: binary)).font(.subheadline.monospacedDigit())
                                        if e.cap > 0 { Text("/ " + (isCPU ? Quantity.formatCPU(cores: e.cap) : Quantity.formatBytes(e.cap, binary: binary))).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                    }
                                    Meter(value: e.cap > 0 ? e.value / e.cap : e.value / scale, height: 5, tint: isCPU ? Palette.chartCPU : Palette.chartMemory)
                                }
                                .padding(.vertical, 4).contentShape(Rectangle())
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    Text("Bar shows usage against the pod's limit, or its request when there is no limit.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        // MARK: Events

        private func eventsCard(_ d: Derived) -> some View {
            let recent = d.events
            let hour = session.health?.counts.warningEvents ?? 0
            return DashCard("Warning Events") {
                RouteLink(route: .resourceList(session.id, .event, namespace: nil)) { Text(hour > 0 ? "\(hour) in 1h" : "See all").font(.subheadline).foregroundStyle(Palette.tintText) }
            } content: {
                if recent.isEmpty {
                    Label(d.eventsLoading ? "Loading events…" : "No warnings", systemImage: d.eventsLoading ? "ellipsis" : "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(d.eventsLoading ? Color.secondary : Palette.healthyText)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(recent.enumerated()), id: \.element.id) { i, e in
                            if i > 0 { Divider().padding(.vertical, 6) }
                            EventRow(clusterID: session.id, event: e)
                        }
                    }
                }
            }
        }

        // MARK: Control plane

        private func controlPlaneCard(_ d: Derived) -> some View {
            let skew = d.skew
            return DashCard("Control Plane & Versions") {
                if let sev = skew.severity { StatusPill(sev, text: "Skew") }
                else if !skew.kubelets.isEmpty { StatusPill(.healthy, text: skew.isMixed ? "Mixed" : "Aligned") }
            } content: {
                VStack(spacing: 8) {
                    fact("API server", session.version?.gitVersion ?? "–", symbol: session.connection == .connected ? "checkmark.circle.fill" : "questionmark.circle", tone: session.connection == .connected ? .healthy : .unknown)
                    fact("API latency", session.latency.map { "\(Int($0.components.seconds * 1000 + $0.components.attoseconds / 1_000_000_000_000_000)) ms" } ?? "–")
                    fact("Platform", session.version?.platform ?? "–")
                    fact("Credentials", session.config.authKind == .token ? "Bearer token" : session.config.authKind == .clientCertificate ? "Client certificate" : "None")
                    Divider()
                    HStack(alignment: .top) {
                        Text("Kubelet versions").font(.subheadline).foregroundStyle(.secondary)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if skew.kubelets.isEmpty { Text("–").font(.subheadline) }
                            ForEach(skew.kubelets) { v in Text("\(v.version)  ×\(v.count)").font(.subheadline.monospacedDigit()) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                    Text(skew.summary).font(.caption).foregroundStyle(skew.severity == nil ? Color.secondary : Palette.warningText).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }

        private func fact(_ title: String, _ value: String, symbol: String? = nil, tone: StatusTone? = nil) -> some View {
            HStack {
                Text(title).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let symbol, let tone { Image(systemName: symbol).foregroundStyle(tone.color).imageScale(.small) }
                Text(value).font(.subheadline.monospacedDigit())
            }
            .accessibilityElement(children: .combine)
        }

        // MARK: Workloads summary

        private var workloadsCard: some View {
            let c = session.health?.counts ?? ClusterCounts()
            let rows: [(String, ResourceKind, String, Bool)] = [
                ("Deployments", .deployment, "\(c.deploymentsAvailable)/\(c.deploymentsTotal)", c.deploymentsAvailable < c.deploymentsTotal),
                ("StatefulSets", .statefulSet, "\(c.statefulSetsReady)/\(c.statefulSetsTotal)", c.statefulSetsReady < c.statefulSetsTotal),
                ("DaemonSets", .daemonSet, "\(c.daemonSetsReady)/\(c.daemonSetsTotal)", c.daemonSetsReady < c.daemonSetsTotal),
                ("Jobs", .job, c.jobsFailed > 0 ? "\(c.jobsFailed) failed" : "OK", c.jobsFailed > 0),
            ]
            return DashCard("Workloads") {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                        if i > 0 { Divider() }
                        RouteLink(route: .resourceList(session.id, r.1, namespace: registry.namespace(for: session.id))) {
                            HStack {
                                Image(systemName: r.1.symbol).foregroundStyle(Palette.tintText).frame(width: 28)
                                Text(r.0).font(.body)
                                Spacer()
                                Text(r.2).font(.subheadline.monospacedDigit()).foregroundStyle(r.3 ? Palette.warningText : Color.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: Spacing.minHit).contentShape(Rectangle())
                        }
                    }
                }
            }
        }

        // MARK: Footnote

        private func footnote(_ availability: MetricsAvailability) -> some View {
            var text = availability.footnote
            if let ep = session.prometheusEndpoint { text += " Prometheus: \(ep.description)." }
            text += refreshInterval > 0 ? " Auto-refreshes every \(refreshInterval) s." : " Pull to refresh."
            return Text(text).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
    }
}

#Preview { NavigationStack { ClusterDashboardView() }.environment(ClusterRegistry.preview()).environment(AppRouter()) }
