import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Chart Room settings. M6a shows where the read path looks for helm's configuration; M6b adds the helm binary choice
/// (bundled Helm 4, or your own from PATH or a custom path) and Artifact Hub.
struct ChartRoomPane: View {
    @Environment(\.chartRoomServices) private var services
    @AppStorage(ChartRoomSettings.helmChoice) private var choice = "bundled"
    @AppStorage(ChartRoomSettings.helmPath) private var path = ""
    @AppStorage(ChartRoomSettings.artifactHub) private var artifactHub = false

    var body: some View {
        Form {
            Section("Helm configuration") {
                LabeledContent("Repositories file") { Text(services.helmPaths.repositoryConfig.path).textSelection(.enabled) }
                LabeledContent("Index cache") { Text(services.helmPaths.repositoryCache.path).textSelection(.enabled) }
                Text("Chart Room reads the repositories you have already added with helm. It only reads these files.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Helm binary") {
                Picker("Use", selection: $choice) {
                    Text(HelmToolbox.bundledURL() == nil ? "helm from PATH" : "The helm in Wheelhouse (then PATH)").tag("bundled")
                    Text("A helm I choose").tag("custom")
                }
                if choice == "custom" {
                    TextField("Path to helm", text: $path, prompt: Text("/opt/homebrew/bin/helm"))
                    if !path.isEmpty, !FileManager.default.isExecutableFile(atPath: path) {
                        Label("That file is not an executable.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warningText)
                    }
                }
                Text("Your own helm is needed for plugins such as helm-secrets and helm-diff. Installing, upgrading, rolling back and uninstalling run the chosen helm through Gangway: it can change only the objects of the review you confirm.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Artifact Hub") {
                Toggle("Search Artifact Hub", isOn: $artifactHub)
                Text("Off by default. When on, searching sends your query to artifacthub.io: the only third-party request Chart Room makes.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Chart Room")
    }
}
