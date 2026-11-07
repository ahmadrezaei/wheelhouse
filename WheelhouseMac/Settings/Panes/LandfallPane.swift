import SwiftUI

/// Settings pane stub (M10). The owning milestone replaces this file; nobody else edits it.
struct LandfallPane: View {
    var body: some View {
        Form { Text("Arrives in M10.").foregroundStyle(.secondary) }
            .formStyle(.grouped)
            .navigationTitle("Landfall")
    }
}
