import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Settings ▸ Survey ▸ Vulnerability scanning: the source of trivy, the database mirror, the energy rule and the per-cluster
/// "Use the cluster's imagePullSecrets" opt-in (off by default). Opening Settings opens `survey.sqlite` (lazily, here and in the
/// Survey screens) and looks up where trivy is; nothing is scanned.
struct ScanSettingsSection: View {
    @Environment(MacAppEnvironment.self) private var env
    @AppStorage(SurveyScanSettings.onlyOnPower) private var onlyOnPower = true
    @AppStorage(SurveyScanSettings.dbRepository) private var dbRepository = ""
    @AppStorage(SurveyScanSettings.javaDBRepository) private var javaDBRepository = ""
    @AppStorage(SurveyScanSettings.trivyPath) private var trivyPath = ""
    @State private var coordinator = ScanCoordinator.shared
    @State private var optIn: [ClusterID: Bool] = [:]
    @State private var showSetup = false

    var body: some View {
        Section("Vulnerability scanning") {
            LabeledContent("Trivy") { Text(coordinator.source.title).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.trailing) }
            TextField("Path to your trivy (optional)", text: $trivyPath)
                .onSubmit { Task { await coordinator.resolveSource() } }
            HStack {
                Button("Look Again") { Task { await coordinator.resolveSource() } }
                Button("Download a Pinned Release…") { showSetup = true }
                    .disabled(coordinator.managed.consent == nil)
                    .help(coordinator.managed.consent == nil ? TrivyPin.unavailableMessage : "Shows the file, address, size and SHA-256 before anything is downloaded")
            }
            Toggle("Only scan on the power adapter", isOn: $onlyOnPower)
            Text("Scans never run in Low Power Mode or when the Mac is hot unless you start them yourself with Scan Now. Trivy downloads its vulnerability database (at most once a day, and only when you scan) from its own registry; Wheelhouse itself contacts no server.")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Database mirror (optional)", text: $dbRepository, prompt: Text("mirror.example.com/trivy-db"))
            TextField("Java database mirror (optional)", text: $javaDBRepository, prompt: Text("mirror.example.com/trivy-java-db"))
        }
        Section("Registry sign-in") {
            Text("Wheelhouse uses your Docker configuration and credential helpers, and the AWS, Google and Azure variables of your shell, so trivy can pull from private registries like your own tools do.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(env.registry.clusters.filter { !$0.isDemo }) { cluster in
                Toggle(isOn: Binding(get: { optIn[cluster.id] ?? false }, set: { on in
                    optIn[cluster.id] = on
                    Task { await coordinator.setUsesPullSecrets(on, clusterID: cluster.id) }
                })) {
                    VStack(alignment: .leading) {
                        Text("Use \(cluster.name)'s imagePullSecrets")
                        Text("Reads the pull secrets of running pods (needs permission to get secrets) and gives trivy only the matching registry, in a private folder deleted after each scan.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task {
            await coordinator.prepare()
            await coordinator.resolveSource()
            for c in env.registry.clusters where !c.isDemo { optIn[c.id] = await coordinator.usesPullSecrets(c.id) }
        }
        .sheet(isPresented: $showSetup) { ScannerSetupSheet(sessions: []) }
    }
}
