import SwiftUI

/// Placeholder for the `NSOutlineView`-backed tree (M1b): view-based rows, type-to-select, real disclosure levels, node diffing
/// that preserves disclosure state. Until then the shell shows no tree.
struct SidebarTree: View {
    let model: SidebarModel
    var body: some View {
        ContentUnavailableView("Sidebar", systemImage: "sidebar.left", description: Text("The resource tree arrives in M1b."))
    }
}
