import Foundation

/// A Trivy Operator `VulnerabilityReport` reduced to what the roll-up needs (ARCHITECTURE-MAC §6.1): metadata, labels, the artifact
/// and `report.summary`. The CVE list (`report.vulnerabilities`, hundreds of KB on a big image) is NOT decoded: this type is what the
/// stores and lists hold, so memory stays small. Full lists are fetched lazily per report with ``TrivyOperator/vulnerabilities(in:)``.
public struct VulnerabilityReportSummary: KubeObject {
    public static var resourceKind: ResourceKind {
        .custom(group: TrivyOperator.group, version: TrivyOperator.version, kind: "VulnerabilityReport", plural: "vulnerabilityreports", namespaced: true)
    }

    public struct Artifact: Codable, Hashable, Sendable {
        public var repository: String?
        public var tag: String?
        public var digest: String?
    }
    public struct Summary: Codable, Hashable, Sendable {
        public var criticalCount: Int?
        public var highCount: Int?
        public var mediumCount: Int?
        public var lowCount: Int?
        public var unknownCount: Int?
    }
    public struct Body: Codable, Hashable, Sendable {
        public var artifact: Artifact?
        public var summary: Summary?
        public var updateTimestamp: String?
    }

    public var apiVersion: String?
    public var kind: String?
    public var metadata: ObjectMeta
    public var report: Body?

    public init(metadata: ObjectMeta, report: Body?) {
        self.metadata = metadata
        self.report = report
    }

    /// The summary counts. `fixable` is nil: the summary does not say.
    public var counts: SeverityCounts {
        let s = report?.summary
        return SeverityCounts(critical: s?.criticalCount ?? 0, high: s?.highCount ?? 0, medium: s?.mediumCount ?? 0, low: s?.lowCount ?? 0,
                              unknown: s?.unknownCount ?? 0, fixable: nil)
    }

    /// `registry/repo:tag` (or `@digest`) from the artifact.
    public var imageReference: String? {
        guard let repo = report?.artifact?.repository, !repo.isEmpty else { return nil }
        if let tag = report?.artifact?.tag, !tag.isEmpty { return "\(repo):\(tag)" }
        if let digest = report?.artifact?.digest, !digest.isEmpty { return "\(repo)@\(digest)" }
        return repo
    }

    /// The workload the labels point at (`trivy-operator.resource.*`). A ReplicaSet owner is mapped to its Deployment.
    public var workload: TrivyOperator.WorkloadKey? {
        let l = metadata.labels
        guard let kind = l[TrivyOperator.kindLabel], let name = l[TrivyOperator.nameLabel] else { return nil }
        let namespace = l[TrivyOperator.namespaceLabel] ?? metadata.namespace ?? ""
        let (k, n) = TrivyOperator.logicalOwner(kind: kind, name: name)
        return TrivyOperator.WorkloadKey(namespace: namespace, kind: k, name: n)
    }

    public var containerName: String? { metadata.labels[TrivyOperator.containerLabel] }
}

public enum TrivyOperator {
    public static let group = "aquasecurity.github.io"
    public static let version = "v1alpha1"
    public static let kindLabel = "trivy-operator.resource.kind"
    public static let nameLabel = "trivy-operator.resource.name"
    public static let namespaceLabel = "trivy-operator.resource.namespace"
    public static let containerLabel = "trivy-operator.container.name"

    public struct WorkloadKey: Hashable, Sendable, Identifiable, Codable {
        public var namespace: String
        public var kind: String
        public var name: String
        public var id: String { "\(namespace)/\(kind)/\(name)" }
    }

    /// Kinds of the operator's report CRDs the cluster serves (all in group `aquasecurity.github.io`).
    public struct Detection: Hashable, Sendable {
        public var kinds: Set<String>
        public var version: String?
        public init(kinds: Set<String> = [], version: String? = nil) {
            self.kinds = kinds
            self.version = version
        }
        public var hasVulnerabilityReports: Bool { kinds.contains("VulnerabilityReport") }
        public var isPresent: Bool { !kinds.isEmpty }
    }

    public static func detect(_ info: DiscoveryInfo?) -> Detection {
        guard let info else { return Detection() }
        let mine = info.topLevel.filter { ($0.group ?? "") == group && $0.verbs.contains("list") }
        return Detection(kinds: Set(mine.map(\.kind)), version: mine.compactMap(\.version).first)
    }

    /// The operator attaches a Deployment's reports to its ReplicaSet (`trivy-operator.resource.kind=ReplicaSet`, name
    /// `<deployment>-<pod-template-hash>`). The Deployment is what users know, so a ReplicaSet name with a trailing hash segment maps
    /// to it; every other kind is kept.
    public static func logicalOwner(kind: String, name: String) -> (kind: String, name: String) {
        guard kind == "ReplicaSet", let dash = name.lastIndex(of: "-"), dash != name.startIndex else { return (kind, name) }
        let hash = name[name.index(after: dash)...]
        // Kubernetes builds the pod-template-hash from this alphabet (no vowels, no 0, 1 or 3), 5 to 10 characters.
        guard (5...10).contains(hash.count), hash.allSatisfy({ "bcdfghjklmnpqrstvwxz2456789".contains($0) }) else { return (kind, name) }
        return ("Deployment", String(name[..<dash]))
    }

    /// The CVE list of a full report object (fetched on demand with `getRaw`).
    public static func vulnerabilities(in raw: JSONValue) -> [ImageVulnerability] {
        (raw.value(at: "report.vulnerabilities")?.arrayValue ?? []).compactMap { v in
            guard let id = v["vulnerabilityID"]?.stringValue, let pkg = v["resource"]?.stringValue else { return nil }
            return ImageVulnerability(cveID: id, severity: TrivyImageReportParser.severity(v["severity"]?.stringValue), package: pkg,
                                      installedVersion: v["installedVersion"]?.stringValue ?? "",
                                      fixedVersion: v["fixedVersion"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 },
                                      title: v["title"]?.stringValue, primaryURL: v["primaryLink"]?.stringValue)
        }
    }
}

/// Roll-ups of operator reports: namespace, workload and image, each with the same severity bar.
public struct OperatorRollup: Hashable, Sendable {
    public struct ContainerEntry: Hashable, Sendable, Identifiable {
        public var container: String?
        public var image: String?
        public var counts: SeverityCounts
        public var reportName: String
        public var id: String { reportName }
    }
    public struct WorkloadEntry: Hashable, Sendable, Identifiable {
        public var workload: TrivyOperator.WorkloadKey
        public var containers: [ContainerEntry]
        public var counts: SeverityCounts
        public var id: String { workload.id }
    }

    public var reportCount: Int
    public var total: SeverityCounts
    public var byNamespace: [String: SeverityCounts]
    public var workloads: [WorkloadEntry]
    /// Reports without the workload labels.
    public var unlinked: [ContainerEntry]

    /// Pure: sums `report.summary` counts. Reports of the same workload and container (a ReplicaSet history keeps old ones) are
    /// deduplicated by the newest `updateTimestamp`.
    public static func build(_ reports: [VulnerabilityReportSummary]) -> OperatorRollup {
        var latest: [String: VulnerabilityReportSummary] = [:]
        var unlinked: [ContainerEntry] = []
        for r in reports {
            guard let w = r.workload else {
                unlinked.append(ContainerEntry(container: r.containerName, image: r.imageReference, counts: r.counts, reportName: r.metadata.name))
                continue
            }
            let key = "\(w.id)|\(r.containerName ?? "")"
            if let existing = latest[key], (existing.report?.updateTimestamp ?? "") >= (r.report?.updateTimestamp ?? "") { continue }
            latest[key] = r
        }
        var perWorkload: [TrivyOperator.WorkloadKey: [ContainerEntry]] = [:]
        for r in latest.values {
            guard let w = r.workload else { continue }
            perWorkload[w, default: []].append(ContainerEntry(container: r.containerName, image: r.imageReference, counts: r.counts, reportName: r.metadata.name))
        }
        var total = SeverityCounts()
        var byNamespace: [String: SeverityCounts] = [:]
        var entries: [WorkloadEntry] = []
        for (w, containers) in perWorkload {
            var counts = SeverityCounts()
            for c in containers { counts.add(c.counts) }
            total.add(counts)
            byNamespace[w.namespace, default: SeverityCounts()].add(counts)
            entries.append(WorkloadEntry(workload: w, containers: containers.sorted { ($0.container ?? "") < ($1.container ?? "") }, counts: counts))
        }
        for u in unlinked { total.add(u.counts) }
        entries.sort { ($0.counts.critical, $0.counts.high, $1.workload.id) > ($1.counts.critical, $1.counts.high, $0.workload.id) }
        return OperatorRollup(reportCount: reports.count, total: total, byNamespace: byNamespace, workloads: entries, unlinked: unlinked)
    }
}

/// Roll-up of local scans: one row per CVE (package and installed version) with the images and workloads that carry it.
public struct LocalVulnerabilityRow: Hashable, Sendable, Identifiable {
    public var vulnerability: ImageVulnerability
    public var images: [String]
    public var workloads: [TrivyOperator.WorkloadKey]
    /// The clusters whose scans carry this CVE.
    public var clusters: [String] = []
    public var id: String { vulnerability.id }
}

public enum LocalRollup {
    /// `workloadsByImage` maps an image digest (or reference, for mutable ones) to the workloads running it.
    public static func rows(scans: [ImageScanResult], workloadsByImage: [String: [TrivyOperator.WorkloadKey]]) -> [LocalVulnerabilityRow] {
        var rows: [String: LocalVulnerabilityRow] = [:]
        for scan in scans {
            let workloads = workloadsByImage[scan.id] ?? []
            for v in scan.vulnerabilities {
                var row = rows[v.id] ?? LocalVulnerabilityRow(vulnerability: v, images: [], workloads: [])
                if !row.images.contains(scan.image) { row.images.append(scan.image) }
                for c in scan.clusters where !row.clusters.contains(c) { row.clusters.append(c) }
                for w in workloads where !row.workloads.contains(w) { row.workloads.append(w) }
                rows[v.id] = row
            }
        }
        return rows.values.sorted {
            ($0.vulnerability.severity.rank, -$0.workloads.count, $0.vulnerability.cveID) < ($1.vulnerability.severity.rank, -$1.workloads.count, $1.vulnerability.cveID)
        }
    }

    public static func counts(scans: [ImageScanResult], workloadsByImage: [String: [TrivyOperator.WorkloadKey]], in namespace: String? = nil) -> SeverityCounts {
        var total = SeverityCounts(fixable: 0)
        for row in rows(scans: scans, workloadsByImage: workloadsByImage) {
            if let namespace, !row.workloads.contains(where: { $0.namespace == namespace }) { continue }
            total.add(SeverityCounts.of([row.vulnerability]))
        }
        return total
    }
}
