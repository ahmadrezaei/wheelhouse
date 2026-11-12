import SwiftUI
import WheelhouseKit

/// Beacon in the workspace: its state, and Stop. Everything else (clients, scopes, snippets) is in Settings → Beacon.
enum BeaconFeature: WheelhouseFeature {
    static var id: FeatureID { .beacon }
    static var title: String { "Beacon" }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        BeaconStatusView()
    }
}

private struct BeaconStatusView: View {
    var body: some View {
        if let model = BeaconModelHub.shared.model {
            VStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(model.isOn ? .green : .secondary)
                Text(model.isOn ? "Beacon is on" : "Beacon is off").font(.title2)
                if model.isOn {
                    Text("\(model.sessionCount) connected client\(model.sessionCount == 1 ? "" : "s")").foregroundStyle(.secondary)
                    Button("Stop Beacon", role: .destructive) { model.turnOff() }
                } else {
                    Text("Turn it on in Settings → Beacon. It asks for Touch ID or your password.").foregroundStyle(.secondary)
                }
                SettingsLink { Text("Open Beacon Settings") }
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task { while !Task.isCancelled { model.refresh(); try? await Task.sleep(for: .seconds(2)) } }   // only while this view is visible
        } else {
            FeaturePlaceholderView(title: "Beacon", milestone: "M12")
        }
    }
}
