import SwiftUI
import UserNotifications
import WheelhouseKit
import WheelhouseUI

/// Notifications: the master switch, permission state, hiding details, and the shared rules, clusters and quiet hours
/// (the iOS "Alerts" section and `AlertSettingsView`). Alerts are checked every minute while a window is visible.
struct NotificationsPane: View {
    @Environment(AppPreferences.self) private var preferences
    @Environment(ClusterRegistry.self) private var registry
    @Environment(\.openURL) private var openURL
    @State private var editor = AlertSettingsEditor()
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Alerts", isOn: $preferences.alertsEnabled)
                    .onChange(of: preferences.alertsEnabled) { _, on in
                        guard on else { return }
                        Task { await AlertNotifier.requestAuthorizationIfNeeded(); status = await AlertNotifier.authorizationStatus() }
                    }
                if preferences.alertsEnabled { statusRow }
                Toggle("Hide details on the Lock Screen", isOn: $preferences.hideAlertDetailsOnLockScreen).disabled(!preferences.alertsEnabled)
            } header: { Text("Alerts") } footer: {
                Text("Wheelhouse checks your clusters every minute while a window is open. Alerts are best effort and not a replacement for a pager.")
            }
            Section("Rules") {
                Toggle("CrashLoopBackOff and OOMKilled", isOn: rule(.crashLoop))
                Toggle("Node NotReady", isOn: rule(.nodeNotReady))
                Toggle("Failed Jobs", isOn: rule(.jobFailed))
                Toggle("Cluster unreachable", isOn: rule(.unreachable))
            }
            .disabled(!preferences.alertsEnabled)
            Section("Clusters") {
                ForEach(registry.clusters) { c in
                    Toggle(isOn: Binding(get: { editor.settings.isEnabled(clusterID: c.id) }, set: { editor.settings.setEnabled($0, clusterID: c.id) })) {
                        HStack { Text(c.name); EnvBadge(c.environment) }
                    }
                }
            }
            .disabled(!preferences.alertsEnabled)
            Section {
                Toggle("Quiet hours", isOn: $editor.settings.quietHoursEnabled)
                if editor.settings.quietHoursEnabled {
                    DatePicker("From", selection: minutes($editor.settings.quietStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutes($editor.settings.quietEndMinutes), displayedComponents: .hourAndMinute)
                }
            } footer: { Text("Alerts found during quiet hours are held back and summarised afterwards.") }
                .disabled(!preferences.alertsEnabled)
        }
        .formStyle(.grouped)
        .navigationTitle("Notifications")
        .task { status = await AlertNotifier.authorizationStatus() }
    }

    @ViewBuilder private var statusRow: some View {
        switch status {
        case .denied?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are turned off for Wheelhouse, so alerts can’t be delivered.", systemImage: "bell.slash").foregroundStyle(Palette.warningText)
                Button("Open System Settings") { if let url = PlatformActions.notificationSettingsURL { openURL(url) } }
            }
        case .notDetermined?:
            Label("Wheelhouse will ask for permission to send notifications.", systemImage: "bell.badge").font(.footnote).foregroundStyle(.secondary)
        case let s? where AlertNotifier.isAuthorized(s):
            Label("Notifications allowed", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func rule(_ rule: AlertRule) -> Binding<Bool> {
        Binding(get: { editor.settings.isRuleOn(rule) }, set: { editor.settings.setRule(rule, on: $0) })
    }

    private func minutes(_ binding: Binding<Int>) -> Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: binding.wrappedValue / 60, minute: binding.wrappedValue % 60, second: 0, of: Date()) ?? Date()
        } set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            binding.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        }
    }
}
