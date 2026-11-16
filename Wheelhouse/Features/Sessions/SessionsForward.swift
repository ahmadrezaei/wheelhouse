import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// What the Sessions screens do for a port forward on the Mac: Recent entries and the New Port Forward picker start a forward
/// through the pane's launcher (one click, the same safety checks as a resource's own action) instead of opening the old form.
enum SessionsForward {
    /// A service or pod chosen for forwarding. `configure` asks for the advanced form (Option-click, or the "…" item).
    struct Choice: Equatable {
        var ref: ResourceRef
        var configure: Bool
        /// The remote port when it is known (a Recent forward); nil asks the object.
        var port: Int?

        init(ref: ResourceRef, configure: Bool, port: Int? = nil) {
            self.ref = ref
            self.configure = configure
            self.port = port
        }
    }

    /// The object a Recent port-forward entry was about; nil for shells, log streams and entries without one.
    static func target(of recent: RecentSession) -> ResourceRef? {
        guard recent.kind == .forward, case .portForward(let ref)? = recent.route else { return nil }
        return ref
    }

    /// Hands the target to the pane's launcher. A router without one opens the form as before.
    @MainActor static func start(_ choice: Choice, router: AppRouter) {
        router.forward(choice.ref, port: choice.port, configure: choice.configure)
    }
}

/// The stores of a namespace selection for one typed kind: one per selected namespace, or one cluster-wide store for All.
@MainActor
struct NamespaceTypedStores<T: KubeObject> {
    let stores: [ResourceStore<T>]

    init(session: ClusterSession, selection: NamespaceSelection) {
        let names = selection.names
        stores = names.isEmpty ? [session.store(for: T.self)] : names.map { session.store(for: T.self, namespace: $0) }
    }

    var items: [T] { stores.flatMap(\.items) }
    var isLoading: Bool { stores.contains { $0.isLoading } }
    /// The first member error; the picker shows it only while there is nothing to list.
    var error: KubeError? { stores.lazy.compactMap(\.error).first }

    /// Runs every member's reflector while the calling task is alive.
    func run() async {
        for store in stores { store.start() }
        defer { for store in stores { store.stop() } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }
}

/// One row of the picker: a navigation link to the form on iOS; on the Mac a button that starts the forward (Option-click and
/// the "Port Forward…" menu item open the advanced form).
struct PickerRow<Label: View>: View {
    let ref: ResourceRef
    let onChoose: (@MainActor (SessionsForward.Choice) -> Void)?
    let dismiss: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        #if os(macOS)
        Button {
            guard let onChoose else { return }
            onChoose(.init(ref: ref, configure: optionKeyIsDown()))
            dismiss()
        } label: { label().contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Port Forward", systemImage: "arrow.left.arrow.right") { onChoose?(.init(ref: ref, configure: false)); if onChoose != nil { dismiss() } }
            Button("Port Forward…", systemImage: "arrow.left.arrow.right") { onChoose?(.init(ref: ref, configure: true)); if onChoose != nil { dismiss() } }
        }
        #else
        NavigationLink { PortForwardSetupView(target: ref, onDone: dismiss) } label: { label() }
        #endif
    }
}
