import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The first `initialize` from a client Wheelhouse has not approved (DESIGN-MAC section 6.13).
///
/// It shows what the APP found out about the program (path or signing identity, and the chain above it), not just the name the
/// client gave itself. Production clusters are unchecked. Change requests are not offered here: enabling them needs Touch ID and
/// is done in Settings. Like the other non-UI confirmations it has no default button and ignores input for one second.
struct BeaconApprovalSheet: View {
    let request: BeaconApprovalRequest
    let decide: (BeaconApprovalDecision) -> Void
    @State private var selected: Set<ClusterID>
    @State private var inputEnabled = false

    init(request: BeaconApprovalRequest, decide: @escaping (BeaconApprovalDecision) -> Void) {
        self.request = request
        self.decide = decide
        _selected = State(initialValue: Set(request.clusters.filter { $0.environment != .production }.map(\.id)))
    }

    private var canRemember: Bool {
        switch request.secretState {
        case .unbound, .mismatch: true
        case .none, .unknown: false
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("\(request.clientName) wants to read your clusters through Beacon.").font(.body)
                }
                Section("Program") {
                    LabeledContent("Reported name") { Text(request.clientName) }
                    LabeledContent("Launched by") { Text(request.launcher.description).multilineTextAlignment(.trailing) }
                    if !request.launcher.path.isEmpty { LabeledContent("Path") { Text(request.launcher.path).font(.whCode).multilineTextAlignment(.trailing) } }
                    if !request.launcher.ancestors.isEmpty {
                        LabeledContent("Started from") { Text(request.launcher.ancestors.joined(separator: "\n")).font(.whCode).multilineTextAlignment(.trailing) }
                    }
                    Text(secretNote).font(.footnote).foregroundStyle(.secondary)
                }
                Section("Clusters it may read") {
                    ForEach(request.clusters) { cluster in
                        Toggle(isOn: Binding(get: { selected.contains(cluster.id) }, set: { on in
                            if on { selected.insert(cluster.id) } else { selected.remove(cluster.id) }
                        })) {
                            HStack(spacing: 6) { Text(cluster.name); EnvBadge(cluster.environment) }
                        }
                    }
                }
                Section {
                    Text("Everything it reads is redacted, and it is labelled as untrusted data. Read access only: change requests are turned on per cluster in Settings, and never for Production.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Allow \(request.clientName)?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Deny") { decide(.deny) } }   // never delayed
                ToolbarItemGroup(placement: .confirmationAction) {
                    if canRemember {
                        Button("Always Allow") { decide(.allow(readClusters: selected, remember: true)) }.disabled(!inputEnabled)
                    }
                    Button("Allow This Session") { decide(.allow(readClusters: selected, remember: false)) }.disabled(!inputEnabled)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 440)
        .task {
            // Input is ignored for one second so a key in flight cannot approve it (ARCHITECTURE-MAC section 9.2).
            try? await Task.sleep(for: .seconds(ConfirmRequest.nonUIInputDelay))
            inputEnabled = true
        }
    }

    private var secretNote: String {
        switch request.secretState {
        case .none: "It sent no client secret, so this approval lasts for this connection only."
        case .unknown: "It sent a client secret Wheelhouse does not know, so this approval lasts for this connection only."
        case .unbound: "It used a client secret created in Settings. Always Allow ties that secret to this program."
        case .mismatch(let approvedFor): "This secret was approved for \(approvedFor), not this program. Always Allow replaces that tie."
        }
    }
}
