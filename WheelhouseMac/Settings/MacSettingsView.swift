import SwiftUI

/// The Settings window: a sidebar of panes (DESIGN-MAC §12). Each pane is a stub in `Settings/Panes/` until its milestone.
struct MacSettingsView: View {
    @State private var selection: SettingsPane? = .general
    private let navigation = SettingsNavigation.shared   // M4b: Compass's settings: jump

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            NavigationStack { (selection ?? .general).content }
        }
        .frame(minWidth: 640, minHeight: 420)
        // M4b
        .onAppear { if let requested = navigation.requested { selection = requested; navigation.requested = nil } }
        .onChange(of: navigation.requested) { _, requested in if let requested { selection = requested; navigation.requested = nil } }
        // end M4b
    }
}
