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
/// The cluster policy applies first: nothing about a cluster First Mate may not see (Never, or Ask without this conversation's grant).
@MainActor
enum FirstMateContextReader {
    static func current(env: MacAppEnvironment, policy: ToolboxPolicy) -> FirstMateContext? {
        guard let pane = env.workspace.activeModel?.focusedPane else { return nil }
        var ref: ResourceRef?
        switch pane.top {
        case .route(.resourceDetail(let r)), .route(.yaml(let r)), .route(.logs(let r, _, _)), .route(.shell(let r, _)), .route(.portForward(let r)): ref = r
        case .gitopsApp(let r): ref = r
        default: break
        }
        guard let clusterID = ref?.clusterID ?? pane.context.clusterID, let cluster = env.registry.config(for: clusterID) else { return nil }
        return FirstMateContext.make(cluster: cluster, policy: policy, object: ref.map { ($0.kind.kind, $0.name, $0.namespace) }, namespace: pane.context.namespace)
    }
}
