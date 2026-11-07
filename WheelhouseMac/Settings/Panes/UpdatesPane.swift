import SwiftUI

/// Updates (DESIGN-MAC section 12). Sparkle is wired in M2; until then, and in every development build, everything is off.
struct UpdatesPane: View {
    var body: some View {
        Form {
            Section {
                Toggle("Automatically check for updates", isOn: .constant(false)).disabled(true)
                Toggle("Automatically download updates", isOn: .constant(false)).disabled(true)
                Button("Check Now") {}.disabled(true)
            } footer: {
                Text("Updates are off in development builds and arrive with the first release build.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Updates")
    }
}
