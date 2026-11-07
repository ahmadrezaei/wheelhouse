import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

// MARK: - Entry points

/// `WorkspaceDestination.survey(scope)`: the fleet when `scope.clusterID` is nil, one cluster otherwise.
struct SurveyRootView: View {
    let scope: SurveyScope
    @Environment(ClusterRegistry.self) private var registry: ClusterRegistry?

    var body: some View {
        if let registry {
            if let id = scope.clusterID {
                if let session = registry.session(for: id) {
                    ClusterSurveyView(session: session, scope: scope)
                        .id(id)
                } else {
                    ContentUnavailableView("Cluster not found", systemImage: "questionmark.folder", description: Text("This cluster is no longer in your list."))
                }
            } else {
                FleetSurveyView(tab: scope.tab)
            }
        } else {
            ContentUnavailableView("Survey", systemImage: "binoculars", description: Text("No clusters are available."))
        }
    }
}

/// `WorkspaceDestination.surveyFinding(id)`: one finding, from the latest report of its cluster.
struct SurveyFindingPane: View {
    let findingID: FindingID
    @Environment(ClusterRegistry.self) private var registry: ClusterRegistry?
    private var hub: SurveyHub { SurveyHub.shared }

    /// Finding IDs start with `rule|clusterID|…` (see `SecurityFinding.makeID`).
    private var clusterID: ClusterID? {
        let parts = findingID.rawValue.split(separator: "|", omittingEmptySubsequences: false)
        return parts.count > 2 ? String(parts[1]) : nil
    }

    var body: some View {
        if let clusterID, let report = hub.report(for: clusterID), let finding = report.findings.first(where: { $0.id == findingID.rawValue }) {
            let name = registry?.config(for: clusterID)?.name ?? clusterID
            FindingDetailView(row: FindingRow(finding: finding, status: hub.risks.status(of: finding), clusterName: name), report: report)
        } else if let clusterID, let registry, let session = registry.session(for: clusterID) {
            // Not computed in this session yet: start the cluster's Survey, which opens the finding when it appears.
            PendingFindingView(session: session, findingID: findingID.rawValue)
        } else {
            ContentUnavailableView("Finding not available", systemImage: "binoculars", description: Text("Open Survey for the cluster to see it."))
        }
    }
}

private struct PendingFindingView: View {
    let session: ClusterSession
    let findingID: String
    @State private var model: SurveyModel?

    var body: some View {
        Group {
            if let model, let report = model.report, let finding = report.findings.first(where: { $0.id == findingID }) {
                FindingDetailView(row: FindingRow(finding: finding, status: SurveyHub.shared.risks.status(of: finding), clusterName: session.config.name), report: report)
            } else if let model, model.report != nil {
                ContentUnavailableView("Finding no longer present", systemImage: "checkmark.shield", description: Text("The rule no longer reports it."))
            } else {
                ProgressView("Reading RBAC objects and workloads…")
            }
        }
        .onAppear { let m = SurveyHub.shared.model(for: session); m.retain(); model = m }
        .onDisappear { model?.release() }
    }
}

// MARK: - One cluster

struct ClusterSurveyView: View {
    let session: ClusterSession
    @State var tab: SurveyTab
    let namespace: String?
    @State private var model: SurveyModel

    init(session: ClusterSession, scope: SurveyScope) {
        self.session = session
        _tab = State(initialValue: scope.tab)
        namespace = scope.namespace
        _model = State(initialValue: SurveyHub.shared.model(for: session))
    }

    var body: some View {
        SurveyScaffold(
            title: session.config.name, tab: $tab, namespace: namespace,
            reports: model.report.map { [$0] } ?? [], names: [session.config.id: session.config.name],
            isLoading: model.report == nil, isComputing: model.isComputing, isWatching: model.isWatching,
            refresh: { await model.refresh() })
        // The RBAC and workload stores exist only while this view is on screen.
        .onAppear { model.retain() }
        .onDisappear { model.release() }
    }
}

// MARK: - Fleet

struct FleetSurveyView: View {
    @State var tab: SurveyTab
    @Environment(ClusterRegistry.self) private var registry: ClusterRegistry?
    private var hub: SurveyHub { SurveyHub.shared }

    init(tab: SurveyTab) { _tab = State(initialValue: tab) }

    var body: some View {
        SurveyScaffold(
            title: "Fleet", tab: $tab, namespace: nil,
            reports: hub.fleet.compactMap(\.report), names: Dictionary(uniqueKeysWithValues: hub.fleet.map { ($0.id, $0.name) }),
            isLoading: hub.fleet.isEmpty || (hub.isLoadingFleet && hub.fleet.allSatisfy { $0.report == nil }), isComputing: hub.isLoadingFleet, isWatching: false,
            fleetEntries: hub.fleet,
            refresh: { if let registry { await hub.loadFleet(registry: registry) } })
        .task { if let registry, hub.fleet.isEmpty { await hub.loadFleet(registry: registry) } }
    }
}

// MARK: - Scaffold

/// The shell shared by the fleet and the cluster: tabs, status, Refresh, Export and the content of the chosen tab.
struct SurveyScaffold: View {
    let title: String
    @Binding var tab: SurveyTab
    let namespace: String?
    let reports: [SurveyReport]
    let names: [ClusterID: String]
    let isLoading: Bool
    let isComputing: Bool
    let isWatching: Bool
    var fleetEntries: [FleetSurveyEntry] = []
    let refresh: () async -> Void

    @State private var showExport = false
    private var hub: SurveyHub { SurveyHub.shared }

    private var limitations: [(String, SurveyLimitation)] {
        reports.flatMap { r in r.limitations.map { (names[r.clusterID] ?? r.clusterID, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !limitations.isEmpty { limitationBanner }
            content
        }
        .sheet(isPresented: $showExport) {
            SurveyExportSheet(reports: reports, names: names, defaultNamespace: namespace, title: title)
        }
        .background(Palette.groupedBackground)
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "binoculars").foregroundStyle(Palette.tintText).accessibilityHidden(true)
            Text("Survey · \(title)").font(.headline)
            Picker("View", selection: $tab) {
                Text("Overview").tag(SurveyTab.overview)
                Text("Vulnerabilities").tag(SurveyTab.vulnerabilities)
                Text("Access risks").tag(SurveyTab.access)
                Text("Workload risks").tag(SurveyTab.workload)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 440)
            Spacer()
            if isComputing { ProgressView().controlSize(.small) }
            if let at = reports.map(\.generatedAt).max() {
                Text("Updated \(at.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .help("Read the RBAC objects and workloads again")
            Button { showExport = true } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(reports.isEmpty)
                .help("Export findings as CSV, JSON, SARIF or an HTML report (⇧⌘E)")
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
    }

    private var limitationBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Findings are limited: some objects could not be read.", systemImage: "exclamationmark.triangle").font(.callout.weight(.medium))
            ForEach(Array(limitations.enumerated()), id: \.offset) { _, l in
                Text("\(l.0): \(l.1.message)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.warning.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var content: some View {
        switch tab {
        case .overview:
            if isLoading && reports.isEmpty && fleetEntries.isEmpty {
                ProgressView("Reading RBAC objects and workloads…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SurveyOverviewView(reports: reports, names: names, entries: fleetEntries, tab: $tab)
            }
        case .vulnerabilities:
            ContentUnavailableView("Vulnerability scanning arrives in M8b", systemImage: "ladybug",
                                   description: Text("Survey shows access and workload risks from built-in rules today. Trivy Operator reports and local image scans come next."))
        case .access:
            findings(.access)
        case .workload:
            findings(.workload)
        }
    }

    @ViewBuilder private func findings(_ category: FindingCategory) -> some View {
        if isLoading && reports.isEmpty {
            ProgressView("Reading RBAC objects and workloads…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FindingsBrowser(category: category, reports: reports, names: names, namespace: namespace)
        }
    }
}

// MARK: - Overview

struct SurveyOverviewView: View {
    let reports: [SurveyReport]
    let names: [ClusterID: String]
    let entries: [FleetSurveyEntry]
    @Binding var tab: SurveyTab
    private var hub: SurveyHub { SurveyHub.shared }

    private var open: [SecurityFinding] {
        reports.flatMap(\.findings).filter { !hub.risks.status(of: $0).isAccepted }
    }
    private var counts: [Severity: Int] { open.reduce(into: [:]) { $0[$1.severity, default: 0] += 1 } }
    private var acceptedCount: Int { reports.flatMap(\.findings).count - open.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                summary
                if entries.count > 1 || (entries.count == 1 && reports.isEmpty) { fleetTable }
                if reports.count == 1, let report = reports.first { topFindings(report); psaSection(report) }
                sources
            }
            .padding(Spacing.l)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SeverityBar(counts: counts).whCard()
            HStack(spacing: Spacing.m) {
                KPITile(label: "Access risks", value: "\(open.filter { $0.category == .access }.count)", caption: "\(reports.reduce(0) { $0 + $1.bindingCount }) bindings read")
                KPITile(label: "Workload risks", value: "\(open.filter { $0.category == .workload }.count)", caption: "\(reports.reduce(0) { $0 + $1.workloadCount }) workloads read")
                if reports.count == 1, let r = reports.first {
                    KPITile(label: "Access risk score", value: "\(r.accessRiskScore)", caption: "0 is best, 100 is worst", meter: Double(r.accessRiskScore) / 100,
                            tone: r.accessRiskScore >= 50 ? .critical : (r.accessRiskScore >= 20 ? .warning : .healthy))
                }
                if acceptedCount > 0 { KPITile(label: "Accepted risks", value: "\(acceptedCount)", caption: "hidden from the counts") }
            }
        }
    }

    private var fleetTable: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Clusters")
            VStack(spacing: 0) {
                ForEach(entries) { e in
                    HStack(spacing: Spacing.m) {
                        Text(e.name).font(.body.weight(.medium)).frame(width: 190, alignment: .leading)
                        EnvBadge(e.environment)
                        switch e.state {
                        case .loading:
                            ProgressView().controlSize(.small)
                            Spacer()
                        case .failed(let message):
                            Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                        case .done(let r):
                            let c = r.counts(r.findings.filter { !hub.risks.status(of: $0).isAccepted })
                            SeverityBar(counts: c).frame(maxWidth: 360)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("\(r.accessRiskScore)").font(.body.monospacedDigit().weight(.semibold))
                                Text("access score").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.s)
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            .whCard()
        }
    }

    private func topFindings(_ report: SurveyReport) -> some View {
        let top = report.findings.filter { !hub.risks.status(of: $0).isAccepted }.prefix(5)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Most severe")
            if top.isEmpty {
                Label("No findings. The built-in rules found nothing to report.", systemImage: "checkmark.shield").foregroundStyle(Palette.healthyText).whCard()
            } else {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    ForEach(Array(top)) { f in
                        HStack(spacing: Spacing.m) {
                            SeverityPill(severity: f.severity)
                            Text(f.ruleID).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(f.title).lineLimit(1)
                            Spacer()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    HStack {
                        Button("Access risks") { tab = .access }
                        Button("Workload risks") { tab = .workload }
                    }
                    .buttonStyle(.link)
                }
                .whCard()
            }
        }
    }

    private func psaSection(_ report: SurveyReport) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            SectionHeader("Pod Security Standards")
            if report.psa.isEmpty {
                Text("No workloads were found.").foregroundStyle(.secondary).whCard()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(report.psa) { ns in
                        PSARow(report: ns)
                        Divider()
                    }
                }
                .whCard()
            }
        }
    }

    private var sources: some View {
        Text("Source: built-in access and workload rules, computed from RBAC objects and pod specs read with your own permissions. Survey changes nothing in the cluster.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct PSARow: View {
    let report: PSANamespaceReport
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.m) {
                Button { expanded.toggle() } label: {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }
                .buttonStyle(.plain).disabled(report.failingRestricted.isEmpty)
                .accessibilityLabel(expanded ? "Collapse \(report.namespace)" : "Expand \(report.namespace)")
                Text(report.namespace).font(.body.weight(.medium))
                Text(labels).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if report.failingRestricted.isEmpty {
                    StatusPill(tone: .healthy, text: "passes restricted")
                } else {
                    StatusPill(tone: report.failingBaseline.isEmpty ? .warning : .critical,
                               text: "\(report.failingRestricted.count) would fail restricted" + (report.failingBaseline.isEmpty ? "" : ", \(report.failingBaseline.count) baseline"))
                }
            }
            if expanded {
                ForEach(report.failingRestricted) { r in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(r.workload.kind) \(r.workload.name)").font(.callout.weight(.medium))
                        Text((r.baseline + r.restricted).map { "\($0.control): \($0.detail)" }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    .padding(.leading, 30)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var labels: String {
        let parts = [("enforce", report.enforce), ("audit", report.audit), ("warn", report.warn)].compactMap { name, level in level.map { "\(name): \($0.rawValue)" } }
        return parts.isEmpty ? "no Pod Security Admission labels" : parts.joined(separator: " · ")
    }
}

// MARK: - Findings list and detail

struct FindingsBrowser: View {
    let category: FindingCategory
    let reports: [SurveyReport]
    let names: [ClusterID: String]
    let namespace: String?

    @AppStorage("survey.hideSystemNamespaces") private var hideSystem = true
    @State private var severity: Severity?
    @State private var search = ""
    @State private var showAccepted = false
    @State private var selection: String?
    private var hub: SurveyHub { SurveyHub.shared }

    private var allRows: [FindingRow] { SurveyFilters.rows(from: reports, names: names, category: category, book: hub.risks) }
    private var rows: [FindingRow] {
        SurveyFilters.apply(allRows, severity: severity, search: search, hideSystemNamespaces: hideSystem, showAccepted: showAccepted, namespace: namespace)
    }
    private var selected: FindingRow? { rows.first { $0.id == selection } ?? allRows.first { $0.id == selection } }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider()
            HSplitView {
                list.frame(minWidth: 420, idealWidth: 640)
                detail.frame(minWidth: 340, idealWidth: 420)
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: Spacing.m) {
            Picker("Severity", selection: $severity) {
                Text("All severities").tag(Severity?.none)
                ForEach([Severity.critical, .high, .medium, .low], id: \.self) { Text($0.title).tag(Severity?.some($0)) }
            }
            .frame(width: 170)
            TextField("Filter rule, object or namespace", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 280)
            Toggle("Hide system namespaces", isOn: $hideSystem)
            Toggle("Show accepted", isOn: $showAccepted)
            Spacer()
            Text("\(rows.count) of \(allRows.count)").font(.caption).foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
    }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            ContentUnavailableView(allRows.isEmpty ? "No findings" : "No findings match",
                                   systemImage: allRows.isEmpty ? "checkmark.shield" : "line.3.horizontal.decrease.circle",
                                   description: Text(allRows.isEmpty ? "The built-in \(category == .access ? "access" : "workload") rules found nothing to report." : "Change the filters to see more."))
        } else {
            Table(rows, selection: $selection) {
                TableColumn("Severity") { r in SeverityPill(severity: r.finding.severity) }.width(min: 84, ideal: 92, max: 110)
                TableColumn("Rule") { r in Text(r.finding.ruleID).font(.body.monospaced()) }.width(min: 56, ideal: 62, max: 72)
                TableColumn("Finding") { r in Text(r.finding.title).lineLimit(2).help(r.finding.title) }
                TableColumn("Object") { r in Text(r.objectText).lineLimit(1) }.width(min: 100, ideal: 160)
                TableColumn("Namespace") { r in Text(r.finding.namespace ?? "—").foregroundStyle(.secondary) }.width(min: 70, ideal: 100)
                TableColumn("Cluster") { r in Text(r.clusterName).foregroundStyle(.secondary) }.width(min: 70, ideal: 100)
                TableColumn("Status") { r in Text(r.statusText).foregroundStyle(r.status.isAccepted ? Palette.infoText : .secondary) }.width(min: 60, ideal: 120)
            }
            .accessibilityIdentifier("survey-findings-table")
        }
    }

    @ViewBuilder private var detail: some View {
        if let row = selected, let report = reports.first(where: { $0.clusterID == row.finding.clusterID }) {
            FindingDetailView(row: row, report: report)
        } else {
            ContentUnavailableView("Select a finding", systemImage: "sidebar.right", description: Text("Its meaning, evidence and fix guidance appear here."))
        }
    }
}

struct FindingDetailView: View {
    let row: FindingRow
    let report: SurveyReport?
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var showAccept = false
    @State private var copied = false
    private var hub: SurveyHub { SurveyHub.shared }
    private var finding: SecurityFinding { row.finding }
    private var rule: SecurityRule? { finding.catalogueEntry }
    private var patch: SuggestedPatch? { SuggestedPatches.patch(for: finding) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                header
                if let rule {
                    section("What it means") { Text(rule.summary) }
                    section("Why it matters") { Text(rule.whyItMatters) }
                }
                affected
                if !finding.evidence.isEmpty {
                    section("Evidence") { CodeView(finding.evidence.joined(separator: "\n"), wraps: true).frame(maxHeight: 180) }
                }
                if let rule { fix(rule) }
                actions
            }
            .padding(Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showAccept) { AcceptRiskSheet(finding: finding) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                SeverityPill(severity: finding.severity)
                Text(finding.ruleID).font(.callout.monospaced()).foregroundStyle(.secondary)
                if case .accepted(let until, _) = row.status {
                    StatusPill(tone: .info, text: "Accepted until \(until.formatted(date: .abbreviated, time: .omitted))", symbol: "checkmark.seal")
                }
            }
            Text(finding.title).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text("\(row.clusterName)\(finding.namespace.map { " · \($0)" } ?? "")").font(.caption).foregroundStyle(.secondary)
            if case .accepted(_, let reason) = row.status { Text("Reason: \(reason)").font(.callout).foregroundStyle(.secondary) }
        }
    }

    private var affected: some View {
        let objects = [finding.object] + finding.related.filter { $0 != finding.object }
        return section("Affected objects") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(objects.enumerated()), id: \.offset) { _, o in
                    if let ref = reference(o), let router {
                        Button { router.push(.resourceDetail(ref)) } label: { Label(label(o), systemImage: ref.kind.symbol) }.buttonStyle(.link)
                    } else {
                        Label(label(o), systemImage: o.kind == "User" || o.kind == "Group" ? "person" : "cube").foregroundStyle(.secondary)
                    }
                }
                if !finding.containers.isEmpty {
                    Text("Containers: \(finding.containers.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func label(_ o: FindingObject) -> String { "\(o.kind) \(o.namespace.map { $0 + "/" } ?? "")\(o.name)" }

    private func reference(_ o: FindingObject) -> ResourceRef? {
        guard let kind = o.resourceKind else { return nil }
        return ResourceRef(clusterID: finding.clusterID, kind: kind, namespace: kind.namespaced ? (o.namespace ?? finding.namespace) : nil, name: o.name)
    }

    private func fix(_ rule: SecurityRule) -> some View {
        section("Fix guidance") {
            VStack(alignment: .leading, spacing: Spacing.s) {
                ForEach(Array(rule.fix.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 6) { Text("\(i + 1).").foregroundStyle(.secondary).monospacedDigit(); Text(step) }
                }
                if let patch {
                    Divider()
                    Text("Suggested patch: \(patch.summary)").font(.callout.weight(.semibold))
                    if let location = SuggestedPatches.location(for: finding) {
                        Text("Merge under `\(location)`:").font(.caption).foregroundStyle(.secondary)
                    }
                    CodeView(patch.yaml, wraps: true).frame(maxHeight: 200)
                    if let caveat = patch.caveat { Text(caveat).font(.caption).foregroundStyle(.secondary) }
                    if let tool = report?.managingTool(for: finding) {
                        Label("\(tool) manages this object and will revert a change made in the cluster. Fix it at the source: change the chart, manifest or Kustomization it is rendered from.",
                              systemImage: "arrow.triangle.2.circlepath").font(.callout).foregroundStyle(Palette.warningText)
                    }
                    HStack {
                        Button("Copy Patch") { copy(patch.yaml) }
                        Button("Open in Editor") { openEditor(patch) }
                            .disabled(router == nil || SuggestedPatches.editTarget(for: finding) == nil)
                            .help("Copies the patch and opens the object's YAML. The normal review and confirmation apply.")
                    }
                }
                if let rule = self.rule, let url = URL(string: rule.docsURL) { Link("Kubernetes documentation", destination: url).font(.callout) }
            }
        }
    }

    private var actions: some View {
        HStack {
            Button { } label: { Label("Ask First Mate", systemImage: "sparkles") }
                .disabled(true).help("First Mate arrives in a later release.")
            if row.status.isAccepted {
                Button("Remove Acceptance") {
                    for r in hub.risks.risks where r.covers(finding) && !r.isExpired() { hub.removeRisk(r.id) }
                }
            } else {
                Button("Accept Risk…") { showAccept = true }
            }
            Button(copied ? "Copied" : "Copy Finding") { copy(finding.plainText(clusterName: row.clusterName, status: row.status)); copied = true }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func openEditor(_ patch: SuggestedPatch) {
        guard let ref = SuggestedPatches.editTarget(for: finding) else { return }
        copy(patch.yaml)
        router?.push(.yaml(ref))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            content().font(.body).fixedSize(horizontal: false, vertical: true)
        }
    }
}
