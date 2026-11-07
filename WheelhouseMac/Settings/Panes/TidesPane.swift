import SwiftUI
import WheelhouseKit

/// Settings → Tides: where Argo CD's API server is reached from the Kubernetes service proxy, and the Argo CD tokens this Mac holds.
/// Tokens are in the Mac-private keychain group, this device only, never synchronised (decision 17).
struct TidesPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @State private var connection = ArgoConnection.live
    @State private var location = ArgoServiceLocation()
    @State private var refresh = 0

    var body: some View {
        Form {
            Section {
                TextField("Namespace", text: $location.namespace)
                TextField("Service", text: $location.service)
                TextField("Port", text: $location.port)
                Picker("Scheme", selection: $location.scheme) {
                    Text("https").tag("https")
                    Text("http").tag("http")
                }
                Button("Save Default Location") { connection.setDefaultLocation(location) }
            } header: {
                Text("Argo CD server (default)")
            } footer: {
                Text("Used for every cluster that has no location of its own. The stock install is https:argocd-server:443 in namespace argocd.")
            }

            Section {
                ForEach(env.registry.clusters.filter { !$0.isDemo }) { cluster in
                    HStack {
                        Text(cluster.name)
                        Spacer()
                        if connection.hasToken(cluster.id) {
                            Label("Token stored", systemImage: "key.fill").foregroundStyle(.secondary)
                            Button("Remove", role: .destructive) { _ = connection.writeToken(nil, cluster.id); refresh += 1 }
                        } else {
                            Text("No token").foregroundStyle(.secondary)
                        }
                    }
                }
                if env.registry.clusters.allSatisfy(\.isDemo) { Text("No clusters yet.").foregroundStyle(.secondary) }
            } header: {
                Text("Argo CD tokens on this Mac")
            } footer: {
                Text("Add a token from an Argo CD application: Tides → app → More → Connect to Argo CD. Tokens are read-only diff credentials and never leave this Mac.")
            }

            Section {
                Text("Every Tides action asks for confirmation after a server dry-run. On Production clusters you type the app name.")
                    .foregroundStyle(.secondary)
            } header: { Text("Safety") }
        }
        .formStyle(.grouped)
        .navigationTitle("Tides")
        .id(refresh)
        .onAppear { location = connection.defaultLocation() }
    }
}
