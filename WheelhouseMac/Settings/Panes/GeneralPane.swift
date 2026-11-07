import SwiftUI

/// Settings pane stub (M1b). The owning milestone replaces this file; nobody else edits it.
struct GeneralPane: View {
    var body: some View {
        Form { Text("Arrives in M1b.").foregroundStyle(.secondary) }
            .formStyle(.grouped)
            .navigationTitle("General")
    }
}
