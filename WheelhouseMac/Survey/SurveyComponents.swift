import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

// MARK: - Severity styling

extension Severity {
    var tone: StatusTone {
        switch self {
        case .critical: .critical
        case .high: .warning
        case .medium: .info
        case .low: .unknown
        case .unknown: .unknown
        }
    }
    var symbol: String {
        switch self {
        case .critical: "exclamationmark.octagon.fill"
        case .high: "exclamationmark.triangle.fill"
        case .medium: "exclamationmark.circle.fill"
        case .low: "info.circle.fill"
        case .unknown: "questionmark.circle"
        }
    }
    var barColor: Color {
        switch self {
        case .critical: Palette.critical
        case .high: Palette.warning
        case .medium: Palette.logHighlight
        case .low: Palette.info
        case .unknown: Palette.unknown
        }
    }
}

struct SeverityPill: View {
    let severity: Severity
    var body: some View { StatusPill(tone: severity.tone, text: severity.title, symbol: severity.symbol) }
}

/// Critical · High · Medium · Low, as proportional segments with the counts underneath.
struct SeverityBar: View {
    let counts: [Severity: Int]
    private let shown: [Severity] = [.critical, .high, .medium, .low]

    var body: some View {
        let total = shown.reduce(0) { $0 + (counts[$1] ?? 0) }
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if total == 0 {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.healthy.opacity(0.5))
                    } else {
                        ForEach(shown, id: \.self) { s in
                            if let n = counts[s], n > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(s.barColor).frame(width: max(4, geo.size.width * CGFloat(n) / CGFloat(total)))
                            }
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: Spacing.l) {
                ForEach(shown, id: \.self) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.barColor).frame(width: 8, height: 8)
                        Text("\(s.title) \(counts[s] ?? 0)").font(.caption.monospacedDigit())
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Findings by severity")
        .accessibilityValue(shown.map { "\($0.title) \(counts[$0] ?? 0)" }.joined(separator: ", "))
    }
}

// MARK: - Rows

/// A finding with what the lists need next to it.
struct FindingRow: Identifiable, Hashable {
    var finding: SecurityFinding
    var status: FindingStatus
    var clusterName: String
    var id: String { finding.id }

    var objectText: String {
        let o = finding.object
        return o.kind == "ServiceAccount" ? "ServiceAccount \(o.namespace.map { $0 + "/" } ?? "")\(o.name)" : "\(o.kind) \(o.name)"
    }
    var statusText: String {
        switch status {
        case .open: "Open"
        case .accepted(let until, _): "Accepted until \(until.formatted(date: .abbreviated, time: .omitted))"
        }
    }
}

enum SurveyFilters {
    static let systemNamespaces: Set<String> = ["kube-system", "kube-public", "kube-node-lease"]

    static func rows(from reports: [SurveyReport], names: [ClusterID: String], category: FindingCategory?, book: AcceptedRiskBook, now: Date = Date()) -> [FindingRow] {
        reports.flatMap { r in
            r.findings.compactMap { f -> FindingRow? in
                if let category, f.category != category { return nil }
                return FindingRow(finding: f, status: book.status(of: f, now: now), clusterName: names[f.clusterID] ?? f.clusterID)
            }
        }
    }

    static func apply(_ rows: [FindingRow], severity: Severity?, search: String, hideSystemNamespaces: Bool, showAccepted: Bool, namespace: String?) -> [FindingRow] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            if let severity, r.finding.severity != severity { return false }
            if !showAccepted, r.status.isAccepted { return false }
            if hideSystemNamespaces, let ns = r.finding.namespace, systemNamespaces.contains(ns) { return false }
            if let namespace, r.finding.namespace != namespace { return false }
            if !q.isEmpty {
                let hay = (r.finding.ruleID + " " + r.finding.title + " " + r.objectText + " " + (r.finding.namespace ?? "")).lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }
}

extension SecurityFinding {
    /// The text "Copy Finding" puts on the pasteboard.
    func plainText(clusterName: String, status: FindingStatus = .open) -> String {
        var lines = ["\(ruleID) \(severity.title): \(title)", "Cluster: \(clusterName)"]
        if let namespace { lines.append("Namespace: \(namespace)") }
        lines.append("Object: \(object.kind) \(object.name)")
        if !containers.isEmpty { lines.append("Containers: \(containers.joined(separator: ", "))") }
        if case .accepted(let until, let reason) = status { lines.append("Accepted until \(until.formatted(date: .abbreviated, time: .omitted)): \(reason)") }
        if !evidence.isEmpty { lines.append("Evidence:"); lines += evidence.map { "  \($0)" } }
        if let rule = catalogueEntry {
            lines.append("Why it matters: \(rule.whyItMatters)")
            lines.append("Fix:"); lines += rule.fix.map { "  - \($0)" }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Export document

struct SurveyExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText, .html, SurveyExportFormat.sarif.contentType] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

extension SurveyExportFormat {
    var contentType: UTType {
        switch self {
        case .csv: .commaSeparatedText
        case .json: .json
        case .sarif: UTType(filenameExtension: "sarif", conformingTo: .json) ?? .json
        case .html: .html
        }
    }
}
