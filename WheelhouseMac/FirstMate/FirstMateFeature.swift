import SwiftUI
import WheelhouseKit

/// First Mate: the assistant that reads cluster state through tools, explains failures and proposes changes
/// (ARCHITECTURE-MAC section 9, DESIGN-MAC section 6.12).
///
/// The same panel is the inspector's First Mate segment (`InspectorView` asks the registry for `.firstMate("inspector")`) and a full
/// pane (`.firstMate(<conversation>)`). It reads the selection itself from the active window, so no Workspace file changes.
/// Nothing runs until the panel is shown; the hub, the Keychain and the conversation store are created on first use.
enum FirstMateFeature: WheelhouseFeature {
    static var id: FeatureID { .firstMate }
    static var title: String { "First Mate" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .firstMate = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        if case .firstMate(let conversation) = destination {
            FirstMatePanel(slot: conversation.rawValue)
        } else {
            FeaturePlaceholderView(title: "First Mate", milestone: "M11b")
        }
    }
}

/// What the active window's focused pane shows, as a sentence for First Mate (sent as a note after the next message when it changes).
@MainActor
enum FirstMateContextReader {
    static func current(env: MacAppEnvironment) -> FirstMateContext? {
        guard let pane = env.workspace.activeModel?.focusedPane else { return nil }
        let registry = env.registry
        var ref: ResourceRef?
        switch pane.top {
        case .route(.resourceDetail(let r)), .route(.yaml(let r)), .route(.logs(let r, _, _)), .route(.shell(let r, _)), .route(.portForward(let r)): ref = r
        case .gitopsApp(let r): ref = r
        default: break
        }
        guard let clusterID = ref?.clusterID ?? pane.context.clusterID, let cluster = registry.config(for: clusterID) else { return nil }
        let place = "cluster \(cluster.name) (\(cluster.environment.rawValue))"
        if let ref {
            let namespace = ref.namespace.map { " in namespace \($0)" } ?? ""
            return FirstMateContext(description: "the user is looking at \(ref.kind.kind) \(ref.name)\(namespace) on \(place)")
        }
        let namespace = pane.context.namespace.map { ", namespace \($0)" } ?? ""
        return FirstMateContext(description: "the user is working in \(place)\(namespace)")
    }
}
