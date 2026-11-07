import SwiftUI

/// Settings pane stub (M11b). The owning milestone replaces this file; nobody else edits it.
struct FirstMatePane: View {
    var body: some View {
        Form { Text("Arrives in M11b.").foregroundStyle(.secondary) }
            .formStyle(.grouped)
            .navigationTitle("First Mate")
    }
}
