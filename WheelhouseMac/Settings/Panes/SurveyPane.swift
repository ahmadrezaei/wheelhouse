import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

/// Settings ▸ Survey (M8a): what the built-in rules check, display defaults and the accepted risks. The scanning settings (Trivy, registries) are in
/// ``ScanSettingsSection``.
struct SurveyPane: View {
    @AppStorage("survey.hideSystemNamespaces") private var hideSystem = true
    @State private var hub = SurveyHub.shared
    @State private var exporting = false
    @State private var riskDocument = SurveyExportDocument(data: Data())

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Hide kube-system, kube-public and kube-node-lease by default", isOn: $hideSystem)
                Text("The lists have their own switch. Findings in these namespaces are still counted in exports unless you leave them out.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rules") {
                ForEach(RuleCatalogue.all) { rule in
                    DisclosureGroup {
                        Text(rule.summary).font(.callout).foregroundStyle(.secondary)
                    } label: {
                        HStack {
                            Text(rule.id).font(.body.monospaced())
                            Text(rule.title)
                            Spacer()
                            SeverityPill(severity: rule.severity)
                        }
                    }
                }
                Text("Rules are built in and read RBAC objects and pod specs with your own permissions.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Accepted risks") {
                if let error = hub.riskStoreError {
                    Label("Accepted risks could not be stored in Survey's database: \(error)", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(Palette.warning)
                }
                if hub.risks.risks.isEmpty {
                    Text("Nothing accepted. Use Accept Risk… on a finding to record a reason and an expiry.").foregroundStyle(.secondary)
                }
                ForEach(hub.risks.risks.sorted { $0.expiresAt < $1.expiresAt }) { risk in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(risk.cveID.map { "\($0) · this cluster" } ?? "\(risk.ruleID) · \(risk.scope.title)").font(.body.weight(.medium))
                            Text(risk.reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Text(risk.isExpired() ? "Expired \(risk.expiresAt.formatted(date: .abbreviated, time: .omitted))" : "Until \(risk.expiresAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(risk.isExpired() ? Palette.warning : Color.secondary)
                        }
                        Spacer()
                        Button("Remove") { hub.removeRisk(risk.id) }
                    }
                    .accessibilityElement(children: .combine)
                }
                HStack {
                    Button("Remove Expired") { hub.removeExpiredRisks() }.disabled(!hub.risks.risks.contains { $0.isExpired() })
                    Button("Export…") {
                        riskDocument = SurveyExportDocument(data: Self.encode(hub.risks))
                        exporting = true
                    }
                    .disabled(hub.risks.risks.isEmpty)
                }
            }

            ScanSettingsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Survey")
        .fileExporter(isPresented: $exporting, document: riskDocument, contentType: .json, defaultFilename: "survey-accepted-risks") { _ in }
    }

    static func encode(_ book: AcceptedRiskBook) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return (try? e.encode(book)) ?? Data()
    }
}
