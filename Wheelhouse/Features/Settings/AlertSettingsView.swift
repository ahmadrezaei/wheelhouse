import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Alert rules, per-cluster opt-in and quiet hours. Stored under `AlertKeys` via `AlertSettingsEditor`; the background engine reads `AlertSettings.load()`.
struct AlertSettingsView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Bindable var model: AlertSettingsEditor

    var body: some View {
        Form {
            Section {
                Toggle("CrashLoopBackOff and OOMKilled", isOn: ruleBinding(.crashLoop))
                Toggle("Node NotReady", isOn: ruleBinding(.nodeNotReady))
                Toggle("Failed Jobs", isOn: ruleBinding(.jobFailed))
                Toggle("Cluster unreachable", isOn: ruleBinding(.unreachable))
            } header: { Text("Rules") } footer: {
                Text("CrashLoopBackOff and OOMKilled: alerts once per pod, and again after 3 or more further restarts since the last alert. NotReady: a node has been not ready for over 5 minutes. Unreachable: 3 consecutive failed checks.")
            }
            Section("Clusters") {
                ForEach(registry.clusters) { c in
                    Toggle(isOn: Binding(get: { model.settings.isEnabled(clusterID: c.id) }, set: { model.settings.setEnabled($0, clusterID: c.id) })) {
                        HStack { Text(c.name); EnvBadge(c.environment) }
                    }
                }
            }
            Section {
                Toggle("Quiet hours", isOn: $model.settings.quietHoursEnabled)
                if model.settings.quietHoursEnabled {
                    DatePicker("From", selection: minutes($model.settings.quietStartMinutes), displayedComponents: .hourAndMinute)
                    DatePicker("Until", selection: minutes($model.settings.quietEndMinutes), displayedComponents: .hourAndMinute)
                }
            } footer: { Text("Alerts found during quiet hours are held back and summarised afterwards.") }
            Section {
                Label("Background checks are scheduled by iOS, not by Wheelhouse. Expect them every 15 minutes to several hours; they are paused in Low Power Mode and stop entirely if you force-quit the app. For paging-grade alerting use your cluster’s own monitoring.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: { Text("How alerts work") }
        }
        .navigationTitle("Alerts")
        .whInlineNavigationTitle()
    }

    private func ruleBinding(_ rule: AlertRule) -> Binding<Bool> {
        Binding(get: { model.settings.isRuleOn(rule) }, set: { model.settings.setRule(rule, on: $0) })
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
