import LocalAuthentication
import SwiftUI
import UserNotifications
import WheelhouseKit
import WheelhouseUI

/// §11 / S25 — settings sheet root.
struct SettingsView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @Environment(\.editMode) private var editMode
    @Environment(\.scenePhase) private var scenePhase

    @State private var alerts = AlertSettingsEditor()
    @State private var pendingDelete: ClusterConfig?
    @State private var editingCluster: ClusterConfig?
    @State private var lockError: String?
    @State private var actionError: String?
    @State private var notificationStatus: UNAuthorizationStatus?
    @State private var showManagedFields = ExtraPreferences.showManagedFields
    private let biometry = BiometryKind.current

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            clustersSection
            securitySection($preferences)
            iCloudSection
            alertsSection($preferences)
            generalSection($preferences)
            demoSection
            aboutSection
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { router.dismissSheet() } }
            if !registry.isDemoMode && registry.clusters.count > 1 { ToolbarItem(placement: .cancellationAction) { EditButton() } }
        }
        .confirmationDialog("Remove \(pendingDelete?.name ?? "cluster")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Remove Cluster", role: .destructive) {
                // The registry also deletes the cluster's credentials and Prometheus token.
                if let c = pendingDelete {
                    do { try registry.remove(id: c.id) } catch { actionError = "Couldn’t remove \(c.name): \(error.localizedDescription)" }
                }
                pendingDelete = nil
            }
        } message: { Text("Deletes the cluster and its credentials from this device\(pendingDelete?.iCloudSync == true ? " and from iCloud Keychain" : ""). The cluster itself is not touched.") }
        .alert("Couldn’t enable App Lock", isPresented: Binding(get: { lockError != nil }, set: { if !$0 { lockError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(lockError ?? "") }
        .alert("Couldn’t save the change", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        // The edit screen is built only when a cluster is chosen (it reads the keychain), not for every row.
        .navigationDestination(item: $editingCluster) { AddClusterView(editing: $0, registry: registry) }
        .task(id: scenePhase) { if scenePhase == .active { notificationStatus = await AlertNotifier.authorizationStatus() } }
    }

    // MARK: Clusters

    private var clustersSection: some View {
        Section {
            ForEach(registry.clusters) { c in
                if registry.isDemoMode {
                    ClusterSettingsRow(cluster: c)
                } else {
                    Button { editingCluster = c } label: {
                        HStack { ClusterSettingsRow(cluster: c); Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button("Remove", role: .destructive) { pendingDelete = c } }
                }
            }
            .onMove { registry.move(fromOffsets: $0, toOffset: $1) }
            .moveDisabled(registry.isDemoMode)
            if registry.isDemoMode {
                Label("These are sample clusters. Exit Demo Mode to manage real ones.", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
            }
            NavigationLink { AddClusterView() } label: { Label("Add Cluster…", systemImage: "plus.circle") }
            NavigationLink { KubeconfigImportView() } label: { Label("Import kubeconfig…", systemImage: "square.and.arrow.down") }
        } header: { Text("Clusters") } footer: {
            if registry.clusters.count > 1 && !registry.isDemoMode { Text("Tap Edit to reorder. The order is used everywhere, including the sidebar and ⌘1–9.") }
        }
    }

    // MARK: Security

    private func securitySection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            Toggle(isOn: Binding(get: { preferences.appLockEnabled }, set: { setLock($0) })) {
                Label("App Lock (\(biometry.name))", systemImage: biometry.symbol)
            }
            if preferences.appLockEnabled {
                Picker("Require unlock", selection: Binding(get: { preferences.lockTimeout }, set: { setLockTimeout($0) })) {
                    Text("Immediately").tag(LockTimeout.immediately)
                    Text("After 1 minute").tag(LockTimeout.oneMinute)
                    Text("After 5 minutes").tag(LockTimeout.fiveMinutes)
                    Text("After 15 minutes").tag(LockTimeout.fifteenMinutes)
                }
            }
            Picker("Reveal secrets", selection: prefs.revealSecretsOncePerSession) {
                Text("Authenticate each time").tag(false)
                Text("Once per session").tag(true)
            }
            Toggle("Hide content in App Switcher", isOn: prefs.hideInAppSwitcher)
        } header: { Text("Security") } footer: {
            Text("Secret values stay masked until you authenticate with \(biometry.name) or your passcode. Copied values are cleared from the clipboard after 60 seconds.")
        }
    }

    /// Weakening or changing the lock needs the owner: authenticate first (skipped only when the device has no passcode at all,
    /// where the lock could not be satisfied anyway).
    private func authenticateOwner(reason: String) async -> Bool {
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await AppLockController.authenticate(reason: reason)
    }

    private func setLock(_ on: Bool) {
        Task {
            if !on {
                if await authenticateOwner(reason: "Turn off App Lock") { preferences.appLockEnabled = false }
                return
            }
            if await AppLockController.authenticate(reason: "Turn on App Lock") { preferences.appLockEnabled = true }
            else { lockError = "Set a device passcode (and \(biometry.name) if you like) in the system Settings, then try again." }
        }
    }

    private func setLockTimeout(_ timeout: LockTimeout) {
        guard timeout != preferences.lockTimeout else { return }
        Task { if await authenticateOwner(reason: "Change the App Lock delay") { preferences.lockTimeout = timeout } }
    }

    // MARK: iCloud

    private var iCloudSection: some View {
        let real = registry.isDemoMode ? [] : registry.clusters
        return Section {
            LabeledContent("Syncing", value: "\(real.filter(\.iCloudSync).count) of \(real.count) clusters")
            ForEach(real) { c in
                Toggle(c.name, isOn: Binding(get: { c.iCloudSync }, set: { on in
                    var n = c; n.iCloudSync = on
                    do { try registry.update(n) } catch { actionError = "Couldn’t change iCloud sync for \(c.name): \(error.localizedDescription)" }
                }))
            }
        } header: { Text("iCloud") } footer: {
            Text("Cluster list and credentials sync end-to-end encrypted via iCloud Keychain to your devices signed in with the same Apple Account. Turning sync off removes the item from iCloud, not from this device.")
        }
    }

    // MARK: Alerts

    private func alertsSection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section {
            Toggle("Background alerts", isOn: prefs.alertsEnabled)
                .onChange(of: preferences.alertsEnabled) { _, on in
                    guard on else { return }
                    Task {
                        await AlertNotifier.requestAuthorizationIfNeeded()
                        notificationStatus = await AlertNotifier.authorizationStatus()
                    }
                }
            if preferences.alertsEnabled { notificationStatusRow }
            Toggle("Hide details on Lock Screen", isOn: prefs.hideAlertDetailsOnLockScreen).disabled(!preferences.alertsEnabled)
            NavigationLink { AlertSettingsView(model: alerts) } label: { Label("Rules, clusters and quiet hours", systemImage: "bell.badge") }
                .disabled(!preferences.alertsEnabled)
        } header: { Text("Alerts") } footer: {
            Text("iOS decides when Wheelhouse may check your clusters in the background — typically every 15 minutes to several hours, less in Low Power Mode, and never after you force-quit the app. Alerts are best effort and not a replacement for a pager.")
        }
    }

    @ViewBuilder private var notificationStatusRow: some View {
        switch notificationStatus {
        case .denied?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are turned off for Wheelhouse, so alerts can’t be delivered.", systemImage: "bell.slash").font(.subheadline).foregroundStyle(Palette.warningText)
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.subheadline.weight(.semibold))
            }
        case .notDetermined?:
            Label("Wheelhouse will ask for permission to send notifications.", systemImage: "bell.badge").font(.footnote).foregroundStyle(.secondary)
        case .authorized?, .provisional?, .ephemeral?:
            Label("Notifications allowed", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: General

    private func generalSection(_ prefs: Bindable<AppPreferences>) -> some View {
        Section("Appearance & behaviour") {
            Picker("Default namespace", selection: prefs.namespaceBehavior) {
                Text("Remember per cluster").tag(NamespaceBehavior.rememberPerCluster)
                Text("Always All namespaces").tag(NamespaceBehavior.alwaysAll)
            }
            Picker("Refresh", selection: prefs.refreshInterval) {
                Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("30 seconds").tag(30); Text("Manual").tag(0)
            }
            VStack(alignment: .leading) {
                HStack { Text("Log font size"); Spacer(); Text("\(Int(preferences.logFontSize)) pt").foregroundStyle(.secondary).monospacedDigit() }
                Slider(value: prefs.logFontSize, in: 9...20, step: 1) { Text("Log font size") }
                Text("2024-05-01T12:00:03Z  INFO  listening on :8080").font(.system(size: preferences.logFontSize, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.5)
            }
            Toggle("Show managedFields in YAML", isOn: $showManagedFields).onChange(of: showManagedFields) { _, v in ExtraPreferences.showManagedFields = v }
            Toggle("Binary units (GiB, MiB)", isOn: prefs.useBinaryUnits)
        }
    }

    // MARK: Demo & About

    private var demoSection: some View {
        Section {
            if registry.isDemoMode {
                Button("Exit Demo Mode", role: .destructive) { preferences.demoMode = false; registry.exitDemoMode(); router.dismissSheet() }
            } else {
                Button { preferences.demoMode = true; registry.enterDemoMode(); router.dismissSheet() } label: { Label("Explore Demo", systemImage: "sparkles") }
            }
        } header: { Text("Demo mode") } footer: { Text("Loads sample clusters so you can try Wheelhouse without a network. Nothing is saved to your real cluster list.") }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
            NavigationLink("Privacy") { AboutTextView(title: "Privacy", text: AboutText.privacy) }
            NavigationLink("Acknowledgements") { AcknowledgementsView() }
        } header: { Text("About") } footer: { Text("No analytics or tracking. Credentials never leave your devices except via iCloud Keychain if you enable it.") }
    }
}

private struct ClusterSettingsRow: View {
    let cluster: ClusterConfig
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(cluster.color.color).frame(width: 12, height: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.name).font(.body)
                Text(cluster.isDemo ? "Demo · \(cluster.provider ?? "")" : cluster.host).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if cluster.readOnly { FlagBadge("READ-ONLY", tone: .info) }
                if cluster.allowsInsecureTLS { FlagBadge("UNVERIFIED TLS", tone: .critical) }
                if cluster.iCloudSync { Image(systemName: "icloud").font(.footnote).foregroundStyle(.secondary).accessibilityLabel("Synced with iCloud") }
                EnvBadge(cluster.environment)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
