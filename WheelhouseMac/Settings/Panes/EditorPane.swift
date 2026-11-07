import SwiftUI

/// Settings pane stub (M7). The owning milestone replaces this file; nobody else edits it.
struct EditorPane: View {
    var body: some View {
        Form { Text("Arrives in M7.").foregroundStyle(.secondary) }
            .formStyle(.grouped)
            .navigationTitle("Editor")
    }
}
