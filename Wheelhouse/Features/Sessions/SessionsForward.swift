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

    /// The choice made in the picker, held until its sheet is gone. Opening the picker clears it, so a Cancel after an earlier
    /// choice can never start that one again, and a choice starts exactly once.
    struct Pending: Equatable {
        private(set) var choice: Choice?

        /// The picker opens: nothing from before may replay.
        mutating func reset() { choice = nil }
        mutating func choose(_ choice: Choice) { self.choice = choice }
        /// The picker's sheet is gone: the choice to start, if one was made, and nothing afterwards.
        mutating func take() -> Choice? {
            defer { choice = nil }
            return choice
        }
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
        await Task.waitUntilCancelled()
    }
}

/// What a picker row does when chosen.
typealias PickerChoose = @MainActor (SessionsForward.Choice) -> Void

/// One row of the picker: a navigation link to the form on iOS; on the Mac a button that starts the forward (Option-click and
/// the "Port Forward…" menu item open the advanced form).
struct PortForwardPickerRow<Label: View>: View {
    let ref: ResourceRef
    let onChoose: PickerChoose
    let dismiss: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        #if os(macOS)
        Button {
            onChoose(.init(ref: ref, configure: optionKeyIsDown()))
            dismiss()
        } label: { label().contentShape(Rectangle()) }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Port Forward", systemImage: "arrow.left.arrow.right") { onChoose(.init(ref: ref, configure: false)); dismiss() }
            Button("Port Forward…", systemImage: "arrow.left.arrow.right") { onChoose(.init(ref: ref, configure: true)); dismiss() }
        }
        #else
        NavigationLink { PortForwardSetupView(target: ref, onDone: dismiss) } label: { label() }
        #endif
    }
}
