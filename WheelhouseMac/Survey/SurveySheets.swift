import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

/// Accept Risk…: a reason, an expiry (30, 90 or 180 days) and a scope. Stored locally and exportable.
struct AcceptRiskSheet: View {
    let finding: SecurityFinding
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var days = 30
    @State private var scope: AcceptanceScope = .finding

    private var trimmed: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Accept Risk").font(.title3.weight(.semibold))
            Text("\(finding.ruleID): \(finding.title)").font(.callout).foregroundStyle(.secondary).lineLimit(3)
            Form {
                Picker("Scope", selection: $scope) {
                    ForEach(AcceptanceScope.allCases) { Text($0.title).tag($0) }
                }
                Picker("Accept for", selection: $days) {
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("180 days").tag(180)
                }
                TextField("Reason", text: $reason, axis: .vertical).lineLimit(3...6)
            }
            .formStyle(.grouped)
            Text("The risk stays in the lists, marked as accepted, until it expires. Nothing changes in the cluster. Accepted risks are stored on this Mac and can be exported.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Accept Risk") {
                    SurveyHub.shared.accept(finding, scope: scope, reason: trimmed, days: days)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 480)
    }
}

/// Export (⇧⌘E): scope, format and options.
struct SurveyExportSheet: View {
    let reports: [SurveyReport]
    let names: [ClusterID: String]
    let defaultNamespace: String?
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var format: SurveyExportFormat = .sarif
    @State private var namespace: String?
    @State private var includeAccepted = true
    @State private var redactRegistries = false
    @State private var includeSystem = true
    @State private var exporting = false
    @State private var document = SurveyExportDocument(data: Data())

    private var all: [SecurityFinding] { reports.flatMap(\.findings) }
    private var namespaces: [String] { Array(Set(all.compactMap(\.namespace))).sorted() }
    private var selected: [SecurityFinding] {
        all.filter { f in
            if let namespace, f.namespace != namespace { return false }
            if !includeSystem, let ns = f.namespace, SurveyFilters.systemNamespaces.contains(ns) { return false }
            return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("Export Findings").font(.title3.weight(.semibold))
            Form {
                Picker("Format", selection: $format) {
                    ForEach(SurveyExportFormat.allCases) { Text($0.title).tag($0) }
                }
                Picker("Scope", selection: $namespace) {
                    Text("\(title), all namespaces").tag(String?.none)
                    ForEach(namespaces, id: \.self) { Text("Namespace \($0)").tag(String?.some($0)) }
                }
                Toggle("Include accepted risks", isOn: $includeAccepted)
                Toggle("Include system namespaces", isOn: $includeSystem)
                Toggle("Redact image registries", isOn: $redactRegistries)
            }
            .formStyle(.grouped)
            Text("\(selected.count) findings. Exports contain rule excerpts and object names only, never Secret data. The HTML report prints well: use File ▸ Print and save as PDF.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Export…") {
                    document = SurveyExportDocument(data: SurveyExporter.export(
                        selected, format: format, book: SurveyHub.shared.risks,
                        options: SurveyExportOptions(includeAcceptedRisks: includeAccepted, redactImageRegistries: redactRegistries), clusterNames: names))
                    exporting = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 500)
        .onAppear { namespace = defaultNamespace }
        .fileExporter(isPresented: $exporting, document: document, contentType: format.contentType,
                      defaultFilename: "survey-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))") { result in
            if case .success = result { dismiss() }
        }
    }
}
