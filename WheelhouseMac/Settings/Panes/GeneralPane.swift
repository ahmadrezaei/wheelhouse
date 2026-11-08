import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// General: appearance, defaults for lists and charts, units, log display, Demo mode (the iOS "Appearance & behaviour" and "Demo mode"
/// sections, DESIGN-MAC section 12).
struct GeneralPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppPreferences.self) private var preferences
    @Environment(ClusterRegistry.self) private var registry
    @AppStorage("appearance") private var appearance = "system"
    @State private var showManagedFields = ExtraPreferences.showManagedFields

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .onChange(of: appearance) { _, v in Self.apply(v) }
            }
            Section("Behaviour") {
                Picker("Default namespace", selection: $preferences.namespaceBehavior) {
                    Text("Remember per cluster").tag(NamespaceBehavior.rememberPerCluster)
                    Text("Always All namespaces").tag(NamespaceBehavior.alwaysAll)
                }
                Picker("Refresh dashboards", selection: $preferences.refreshInterval) {
                    Text("5 seconds").tag(5); Text("10 seconds").tag(10); Text("30 seconds").tag(30); Text("Manual").tag(0)
                }
                Toggle("Binary units (GiB, MiB)", isOn: $preferences.useBinaryUnits)
                Toggle("Show managedFields in YAML", isOn: $showManagedFields).onChange(of: showManagedFields) { _, v in ExtraPreferences.showManagedFields = v }
            }
            Section {
                LabeledContent("Log font size") {
                    HStack {
                        Slider(value: $preferences.logFontSize, in: 9...20, step: 1).frame(width: 180)
                        Text("\(Int(preferences.logFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                LabeledContent("Log lines kept per stream") {
                    Stepper(value: $preferences.logMaxLines, in: 1_000...LogLimits.desktop.maxLines, step: 1_000) {
                        Text(preferences.logMaxLines.formatted()).monospacedDigit()
                    }
                }
            } header: { Text("Logs") } footer: {
                Text("Each stream keeps the last \(preferences.logMaxLines.formatted()) lines (at most 50,000 lines and 16 MB). Older lines scroll off. Lines over 16 KB are shortened.")
            }
            Section {
                if registry.isDemoMode {
                    Button("Exit Demo Mode", role: .destructive) { preferences.demoMode = false; registry.exitDemoMode() }
                } else {
                    Button("Explore Demo") { preferences.demoMode = true; registry.enterDemoMode() }
                }
            } header: { Text("Demo mode") } footer: { Text("Loads sample clusters so you can try Wheelhouse without a network. Nothing is saved to your real cluster list.") }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}
