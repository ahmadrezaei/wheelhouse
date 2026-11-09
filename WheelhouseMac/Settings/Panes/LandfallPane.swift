import SwiftUI
import WheelhouseDesktop

/// Settings → Landfall: CLI status per provider, accounts included, AWS regions, rescan interval and the optional merge into
/// `~/.kube/config`. Landfall is off in development builds.
struct LandfallPane: View {
    var body: some View {
        Form {
            if let model = LandfallModel.shared {
                if model.isEnabled { Content(model: model) } else {
                    Section { Label("Landfall is off in development builds. Cloud CLIs talk to real accounts.", systemImage: "lock").foregroundStyle(.secondary) }
                }
            } else {
                Text("Landfall isn’t running.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Landfall")
    }

    private struct Content: View {
        let model: LandfallModel
        @State private var regions = ""

        var body: some View {
            Section("Command-line tools") {
                ForEach(CloudProvider.allCases) { p in
                    LabeledContent(p.displayName) {
                        switch model.statuses[p] {
                        case .installed(let v): Text("\(p.tool) \(v)").foregroundStyle(.secondary)
                        case .notFound(let hint): Text("Not found · \(hint)").foregroundStyle(.orange)
                        case .signedOut: Text("Signed out").foregroundStyle(.orange)
                        case .failed(let why): Text(why).foregroundStyle(.red)
                        case .disabled(let why): Text(why).foregroundStyle(.secondary)
                        case nil: Text("Checking…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Accounts included") {
                let any = CloudProvider.allCases.contains { !(model.preferences.selectedAccounts[$0.rawValue] ?? []).isEmpty }
                Text(any ? CloudProvider.allCases.compactMap { p in
                    let n = model.preferences.selectedAccounts[p.rawValue]?.count ?? 0
                    return n == 0 ? nil : "\(p.displayName): \(n) \(p.accountNoun.lowercased())\(n == 1 ? "" : "s")"
                }.joined(separator: " · ") : "None yet. Tick accounts in the Landfall pane.").foregroundStyle(.secondary)
                TextField("AWS regions (blank = every enabled region)", text: $regions)
                    .onSubmit { model.setAWSRegions(regions) }
            }
            Section {
                Picker("Rescan", selection: Binding(get: { model.preferences.rescan }, set: { v in Task { await model.setRescan(v) } })) {
                    Text("Manual").tag(LandfallPreferences.Rescan.manual)
                    Text("Daily").tag(LandfallPreferences.Rescan.daily)
                }
                Toggle("Also merge into ~/.kube/config", isOn: Binding(get: { model.preferences.mergeIntoUserKubeconfig }, set: { model.setMerge($0) }))
            } footer: {
                Text("Nothing is scanned in the background unless you choose Daily. The merge shows the exact YAML first, makes a backup, and never changes current-context.")
            }
            .task {
                regions = (model.preferences.awsRegions ?? []).joined(separator: ", ")
                await model.loadStatus()
            }
        }
    }
}
