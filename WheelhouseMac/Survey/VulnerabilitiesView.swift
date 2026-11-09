import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

extension SeverityCounts {
    /// The shape `SeverityBar` takes.
    var bySeverity: [Severity: Int] { [.critical: critical, .high: high, .medium: medium, .low: low, .unknown: unknown] }
}

/// The Vulnerabilities tab (DESIGN-MAC §6.9): Trivy Operator roll-ups from the clusters, and local scans of the running images.
/// Nothing runs while the tab is not on screen: the operator report stores start in `onAppear` and stop in `onDisappear`, and local
/// scanning starts only when the user presses Scan Now.
struct VulnerabilitiesTabView: View {
    let sessions: [ClusterSession]
    let namespace: String?
    @State private var model: VulnerabilityModel
    @State private var coordinator = ScanCoordinator.shared
    @State private var hub = SurveyHub.shared
    @State private var showSetup = false
    @State private var confirmOnBattery: ScanGate.PauseReason?
    @State private var severity: Severity?
    @State private var fixableOnly = false
    @State private var search = ""
    @State private var accepting: LocalVulnerabilityRow?
    @State private var selection: LocalVulnerabilityRow.ID?

    init(sessions: [ClusterSession], namespace: String?) {
        self.sessions = sessions
        self.namespace = namespace
        _model = State(initialValue: VulnerabilityModel(sessions: sessions))
    }

    private var clusterIDs: Set<ClusterID> { Set(sessions.map(\.config.id)) }

    /// Local scan results of images these clusters ran when they were scanned (stored with each result, so a relaunch scopes correctly).
    private var scopedScans: [ImageScanResult] {
        coordinator.scans.filter { !Set($0.clusters).isDisjoint(with: clusterIDs) }
    }

    private var rows: [LocalVulnerabilityRow] {
        var byImage: [String: [TrivyOperator.WorkloadKey]] = [:]
        for s in sessions { for (k, v) in coordinator.workloadsByImage[s.config.id] ?? [:] { byImage[k, default: []] += v } }
        let all = LocalRollup.rows(scans: scopedScans, workloadsByImage: byImage)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { r in
            if let namespace, !r.workloads.contains(where: { $0.namespace == namespace }) { return false }
            if let severity, r.vulnerability.severity != severity { return false }
            if fixableOnly, !r.vulnerability.isFixable { return false }
            if !q.isEmpty, !(r.vulnerability.cveID + " " + r.vulnerability.package + " " + r.images.joined(separator: " ")).lowercased().contains(q) { return false }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    operatorSection
                    localSection
                    sourcesFootnote
                }
                .padding(Spacing.l)
            }
        }
        .onAppear { model.retain() }
        .onDisappear { model.release() }
        .task { await coordinator.prepare() }
        .sheet(isPresented: $showSetup) { ScannerSetupSheet(sessions: sessions) }
        .sheet(item: $accepting) { row in
            AcceptCVESheet(cveID: row.vulnerability.cveID, clusterIDs: row.clusters.filter { clusterIDs.contains($0) }.sorted())
        }
        .confirmationDialog(confirmOnBattery?.message ?? "", isPresented: Binding(get: { confirmOnBattery != nil }, set: { if !$0 { confirmOnBattery = nil } }),
                            titleVisibility: .visible) {
            Button("Scan Anyway") { Task { await coordinator.scan(sessions: sessions, trigger: .manual) } }
            Button("Wait Until Conditions Allow") { Task { await coordinator.scan(sessions: sessions, trigger: .scheduled) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Scanning uses the CPU and the network for a while. Scans started automatically wait for power.")
        }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: Spacing.m) {
            progressSummary
            Spacer()
            switch coordinator.progress.state {
            case .running:
                Button("Pause") { Task { await coordinator.pause() } }
            case .paused, .userPaused:
                Button("Resume") { Task { await coordinator.resume(manual: false) } }
                Button("Scan Anyway") { Task { await coordinator.resume(manual: true) } }
            case .idle:
                if coordinator.progress.queued > 0 {
                    Button("Resume \(coordinator.progress.queued) waiting") { Task { await coordinator.resume(manual: true) } }
                    Button("Clear Queue") { Task { await coordinator.clearQueue() } }
                }
            }
            if coordinator.source == .none {
                Button("Set Up Local Scanning…") { showSetup = true }
            } else {
                Button("Scan Now") {
                    if let reason = coordinator.wouldPauseOnEnergy { confirmOnBattery = reason }
                    else { Task { await coordinator.scan(sessions: sessions, trigger: .manual) } }
                }
                .disabled(coordinator.progress.state == .running)
                .help("Scan the images running in the selected clusters with trivy on this Mac")
            }
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
    }

    @ViewBuilder private var progressSummary: some View {
        let p = coordinator.progress
        VStack(alignment: .leading, spacing: 2) {
            switch p.state {
            case .running:
                Text("Scanning \(p.scanned + 1) of \(p.scanned + p.queued)…").font(.callout.weight(.medium))
                if let current = p.current { Text(current).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let eta = p.eta { Text("About \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))) left").font(.caption).foregroundStyle(.secondary) }
            case .paused(let reason):
                Text(reason.message).font(.callout.weight(.medium))
                Text("\(p.queued) image\(p.queued == 1 ? "" : "s") waiting. It resumes by itself when the Mac allows it.").font(.caption).foregroundStyle(.secondary)
            case .userPaused:
                Text("Paused · \(p.queued) waiting").font(.callout.weight(.medium))
            case .idle:
                if p.queued > 0 {
                    Text("\(p.queued) image\(p.queued == 1 ? "" : "s") waiting from the last session").font(.callout.weight(.medium))
                } else if p.scanned > 0 || p.failed > 0 {
                    Text("Scanned \(p.scanned)\(p.failed > 0 ? ", \(p.failed) failed" : "")").font(.callout)
                } else {
                    Text("Local scanning: \(coordinator.source.title)").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = p.lastError ?? coordinator.message { Text(error).font(.caption).foregroundStyle(Palette.warning).lineLimit(2) }
        }
    }

    // MARK: Operator

    @ViewBuilder private var operatorSection: some View {
        let withOperator = model.clusters.filter { $0.detection.hasVulnerabilityReports }
        if withOperator.isEmpty {
            if model.isWatching, !model.clusters.isEmpty {
                Text("Trivy Operator is not installed in the selected cluster\(model.clusters.count == 1 ? "" : "s"). Install it for always-fresh reports at no cost on this Mac, or scan images locally.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        } else {
            ForEach(withOperator) { c in
                GroupBox {
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        if let rollup = c.rollup {
                            let ns = namespace.flatMap { rollup.byNamespace[$0] } ?? rollup.total
                            SeverityBar(counts: ns.bySeverity)
                            Text("From \(rollup.reportCount) Trivy Operator report\(rollup.reportCount == 1 ? "" : "s"). Fixable counts need the full report; open a workload to load it.")
                                .font(.caption).foregroundStyle(.secondary)
                            workloadTable(rollup)
                        } else if let error = c.error {
                            Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(Palette.warning)
                        } else {
                            ProgressView("Reading reports…")
                        }
                    }
                } label: { Label("\(c.name) · Trivy Operator", systemImage: "shield.lefthalf.filled") }
            }
        }
    }

    private func workloadTable(_ rollup: OperatorRollup) -> some View {
        let entries = rollup.workloads.filter { namespace == nil || $0.workload.namespace == namespace }
        return Table(entries) {
            TableColumn("Namespace") { Text($0.workload.namespace).foregroundStyle(.secondary) }.width(min: 80, ideal: 110)
            TableColumn("Workload") { Text("\($0.workload.kind) \($0.workload.name)").lineLimit(1) }
            TableColumn("Critical") { Text("\($0.counts.critical)").monospacedDigit().foregroundStyle($0.counts.critical > 0 ? Palette.critical : .secondary) }.width(60)
            TableColumn("High") { Text("\($0.counts.high)").monospacedDigit() }.width(50)
            TableColumn("Medium") { Text("\($0.counts.medium)").monospacedDigit() }.width(60)
            TableColumn("Low") { Text("\($0.counts.low)").monospacedDigit() }.width(50)
            TableColumn("Unknown") { Text("\($0.counts.unknown)").monospacedDigit() }.width(64)
        }
        .frame(minHeight: 120, maxHeight: 280)
        .accessibilityIdentifier("survey-operator-table")
    }

    // MARK: Local

    @ViewBuilder private var localSection: some View {
        if !coordinator.scans.isEmpty {
            let rows = self.rows          // computed once per body
            GroupBox {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    let counts = SeverityCounts.of(rows.map(\.vulnerability))
                    SeverityBar(counts: counts.bySeverity)
                    HStack {
                        Picker("Severity", selection: $severity) {
                            Text("All severities").tag(Severity?.none)
                            ForEach(Severity.allCases, id: \.self) { Text($0.title).tag(Severity?.some($0)) }
                        }.frame(maxWidth: 180)
                        Toggle("Fixable only", isOn: $fixableOnly)
                        TextField("Search CVE, package or image", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                        Spacer()
                        Text("\(rows.count) CVEs · \(counts.fixable ?? 0) fixable").font(.caption).foregroundStyle(.secondary)
                    }
                    Table(rows, selection: $selection) {
                        TableColumn("Severity") { SeverityPill(severity: $0.vulnerability.severity) }.width(min: 84, ideal: 92, max: 110)
                        TableColumn("CVE") { Text($0.vulnerability.cveID).font(.body.monospaced()) }.width(min: 110, ideal: 130)
                        TableColumn("Package") { Text($0.vulnerability.package).lineLimit(1) }
                        TableColumn("Installed → fixed") { r in
                            Text("\(r.vulnerability.installedVersion) → \(r.vulnerability.fixedVersion ?? "no fix")").lineLimit(1).foregroundStyle(r.vulnerability.isFixable ? .primary : .secondary)
                        }
                        TableColumn("Workloads") { Text("\($0.workloads.count)").monospacedDigit() }.width(70)
                        TableColumn("Image") { Text($0.images.first ?? "").lineLimit(1).foregroundStyle(.secondary) }
                        TableColumn("Status") { r in
                            let status = r.clusters.filter { clusterIDs.contains($0) }.map { hub.risks.status(ofCVE: r.vulnerability.cveID, cluster: $0) }.first { $0.isAccepted } ?? .open
                            Text(statusText(status)).foregroundStyle(status.isAccepted ? Palette.infoText : .secondary)
                        }.width(min: 60, ideal: 130)
                    }
                    .frame(minHeight: 200, maxHeight: 420)
                    .contextMenu(forSelectionType: LocalVulnerabilityRow.ID.self) { ids in
                        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                            Button("Accept Risk…") { accepting = row }
                            Button("Copy CVE ID") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.vulnerability.cveID, forType: .string) }
                        }
                    }
                    .accessibilityIdentifier("survey-vulnerabilities-table")
                }
            } label: { Label("Local scans", systemImage: "ladybug") }
        } else if coordinator.source != .none, coordinator.progress.state == .idle, coordinator.progress.queued == 0 {
            ContentUnavailableView("No local scans yet", systemImage: "ladybug",
                                   description: Text("Scan Now reads the images running in this cluster and scans them one at a time with \(coordinator.source.title)."))
                .frame(maxWidth: .infinity)
        }
    }

    private func statusText(_ status: FindingStatus) -> String {
        if case .accepted(let until, _) = status { return "Accepted until \(until.formatted(date: .abbreviated, time: .omitted))" }
        return "Open"
    }

    private var sourcesFootnote: some View {
        Text("Sources: Trivy Operator reports (in the cluster) · local scans with \(coordinator.source.title). Scans are cached by image digest and vulnerability database version.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Sheets

/// Accept a CVE for a cluster: a reason and an expiry. Stored in `survey.sqlite`.
struct AcceptCVESheet: View {
    let cveID: String
    let clusterIDs: [ClusterID]
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Accept \(cveID)").font(.title3.weight(.semibold))
            Text("Accepted in the selected cluster\(clusterIDs.count == 1 ? "" : "s"). It stays in the list, marked as accepted, until it expires. Nothing changes in the cluster.")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                Picker("Accept for", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                }
                TextField("Reason", text: $reason, axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept Risk") {
                    for c in clusterIDs { SurveyHub.shared.acceptCVE(cveID, clusterID: c, reason: reason.trimmingCharacters(in: .whitespacesAndNewlines), days: days) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 460)
    }
}

/// Set Up Local Scanning…: the consent sheet of the managed download (file name, URL, size, SHA-256), or the path of the user's own
/// trivy. Nothing is downloaded until the button is pressed.
struct ScannerSetupSheet: View {
    let sessions: [ClusterSession]
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator = ScanCoordinator.shared
    @State private var downloading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Set Up Local Scanning").font(.title3.weight(.semibold))
            Text("Wheelhouse scans images with Trivy on this Mac. It never bundles Trivy: use your own, or let Wheelhouse download a pinned release after you approve it.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox("Your own trivy") {
                Text("Install it (for example with Homebrew) or set its path in Settings ▸ Survey. Wheelhouse finds a `trivy` on your PATH.")
                    .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                Button("Look Again") { Task { await coordinator.resolveSource(); if coordinator.source != .none { dismiss() } } }
            }
            GroupBox("Download a pinned release") {
                if let consent = coordinator.managed.consent {
                    Grid(alignment: .leading, horizontalSpacing: Spacing.m, verticalSpacing: 4) {
                        GridRow { Text("File").foregroundStyle(.secondary); Text(consent.fileName).textSelection(.enabled) }
                        GridRow { Text("From").foregroundStyle(.secondary); Text(consent.url.absoluteString).textSelection(.enabled).lineLimit(2) }
                        GridRow { Text("Size").foregroundStyle(.secondary); Text(ByteCountFormatter.string(fromByteCount: consent.size, countStyle: .file)) }
                        GridRow { Text("SHA-256").foregroundStyle(.secondary); Text(consent.sha256).font(.caption.monospaced()).textSelection(.enabled).lineLimit(2) }
                        GridRow { Text("Installs to").foregroundStyle(.secondary); Text(consent.installLocation.path).lineLimit(2) }
                    }
                    Text("The download is checked against this SHA-256 before it is unpacked, and the program against its pinned hash before every launch. It is never updated by itself. Trivy then downloads its vulnerability database (tens of MB) the first time you scan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(downloading ? "Downloading…" : "Download and Install") {
                        downloading = true
                        Task { await coordinator.installManaged(); downloading = false; if coordinator.source != .none { dismiss() } }
                    }
                    .disabled(downloading)
                } else {
                    Text(TrivyPin.unavailableMessage).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let message = coordinator.message { Text(message).font(.caption).foregroundStyle(Palette.warning) }
            HStack { Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(Spacing.xl)
        .frame(width: 560)
    }
}
