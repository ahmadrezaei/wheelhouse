import SwiftUI

/// Settings, Updates (ARCHITECTURE-MAC section 2.5): automatic checks, automatic download and the release channel.
/// Development builds (no feed, or the safety gate on) show the controls disabled with the reason.
struct UpdatesPane: View {
    @ObservedObject private var updater = MacUpdater.shared
    @AppStorage(UpdateChannel.defaultsKey) private var channel = UpdateChannel.stable.rawValue

    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    var body: some View {
        Form {
            if !updater.feedIsSet {
                Section {
                    Label("Updates are off in development builds.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Updates") {
                LabeledContent("Version", value: version)
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                Toggle("Download updates automatically", isOn: Binding(
                    get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!updater.automaticallyChecks)
                Picker("Channel", selection: $channel) {
                    ForEach(UpdateChannel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if let last = updater.lastCheck {
                    LabeledContent("Last checked", value: last.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Check Now") { updater.checkForUpdates() }
                    .disabled(!updater.canCheck)
            }
            .disabled(!updater.feedIsSet)
        }
        .formStyle(.grouped)
        .navigationTitle("Updates")
    }
}
