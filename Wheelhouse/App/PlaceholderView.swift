import SwiftUI
import WheelhouseUI

/// Shared stand-in used by feature entry views until their owners replace them.
struct PlaceholderView: View {
    let title: String
    var symbol: String = "hammer"
    var note: String = "This screen is being built."

    var body: some View {
        EmptyState(.empty(title: title, systemImage: symbol, hint: note))
            .navigationTitle(title)
            .whInlineNavigationTitle()
    }
}
