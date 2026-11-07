import SwiftUI

/// Settings pane stub (M2). The owning milestone replaces this file; nobody else edits it.
struct UpdatesPane: View {
    var body: some View {
        Form {
            Text("Updates are off in development builds.").foregroundStyle(.secondary)
            Text("Sparkle is wired in M2.").foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
            .navigationTitle("Updates")
    }
}
