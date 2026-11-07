import SwiftUI
import WheelhouseKit

/// Chart Room settings. M6a shows where the read path looks for helm's configuration; M6b adds the helm binary choice
/// (bundled Helm 4, or your own from PATH or a custom path) and Artifact Hub.
struct ChartRoomPane: View {
    @Environment(\.chartRoomServices) private var services

    var body: some View {
        Form {
            Section("Helm configuration") {
                LabeledContent("Repositories file") { Text(services.helmPaths.repositoryConfig.path).textSelection(.enabled) }
                LabeledContent("Index cache") { Text(services.helmPaths.repositoryCache.path).textSelection(.enabled) }
                Text("Chart Room reads the repositories you have already added with helm. It only reads these files.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Helm binary") {
                Text("Installing, upgrading, rolling back and uninstalling arrive in M6b, together with the choice between the bundled Helm and your own.")
                    .foregroundStyle(.secondary)
            }
            Section("Artifact Hub") {
                LabeledContent("Search") { Text("Off") }
                Text("Artifact Hub search is a third-party request, so it stays off until the write path ships and you turn it on.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Chart Room")
    }
}
