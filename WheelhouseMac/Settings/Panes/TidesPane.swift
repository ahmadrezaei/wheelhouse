import SwiftUI

/// Settings pane stub (M9). The owning milestone replaces this file; nobody else edits it.
struct TidesPane: View {
    var body: some View {
        Form { Text("Arrives in M9.").foregroundStyle(.secondary) }
            .formStyle(.grouped)
            .navigationTitle("Tides")
    }
}
