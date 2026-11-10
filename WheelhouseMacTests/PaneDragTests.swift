import AppKit
import Testing
import WheelhouseKit
@testable import WheelhouseMac

@MainActor
@Suite("PaneDragTests")
struct PaneDragTests {
    @Test func theFiveZonesFollowTheCursor() {
        let size = CGSize(width: 400, height: 300)
        #expect(PaneDropZones.zone(at: CGPoint(x: 200, y: 150), in: size) == .center)
        #expect(PaneDropZones.zone(at: CGPoint(x: 10, y: 150), in: size) == .left)
        #expect(PaneDropZones.zone(at: CGPoint(x: 390, y: 150), in: size) == .right)
        #expect(PaneDropZones.zone(at: CGPoint(x: 200, y: 10), in: size) == .top)
        #expect(PaneDropZones.zone(at: CGPoint(x: 200, y: 290), in: size) == .bottom)
        // A corner goes to the nearer edge.
        #expect(PaneDropZones.zone(at: CGPoint(x: 20, y: 140), in: size) == .left)
        #expect(PaneDropZones.zone(at: CGPoint(x: 150, y: 8), in: size) == .top)
        #expect(PaneDropZones.zone(at: .zero, in: .zero) == .center)
    }

    @Test func thePayloadCarriesIdentifiersOnly() throws {
        let payload = PaneDragPayload(window: WorkspaceWindowID(rawValue: "w"), pane: PaneID(rawValue: "p"))
        #expect(PaneDragPayload(data: payload.data) == payload)
        let text = String(decoding: payload.data, as: UTF8.self)
        #expect(text.contains("\"p\"") && text.contains("\"w\""))
        #expect(PaneDragPayload(data: Data("nope".utf8)) == nil)
        #expect(PaneDragPayload(window: nil, pane: PaneID(rawValue: "x")).window == nil)
    }

    private func controller() -> WorkspaceController {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.drag.\(UUID().uuidString)")!)
        return WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
    }

    @Test func aPaneDockedWithinAWindowMoves() throws {
        let c = controller()
        let model = c.model(for: c.store.createWindow())
        let a = model.focusedPaneID
        model.split(.horizontal)
        let b = model.focusedPaneID
        let id: WorkspaceWindowID? = { if case .window(let w) = model.scope { w } else { nil } }()
        #expect(c.dockPane(PaneDragPayload(window: id, pane: b), into: model, onto: a, zone: .left))
        #expect(model.selectedTab.root.neighbour(of: b, .right) == a)
    }

    @Test func aPaneDraggedToAnotherWindowMovesItsState() throws {
        let c = controller()
        let source = c.model(for: c.store.createWindow())
        let target = c.model(for: c.store.createWindow())
        source.split(.horizontal)
        let moved = source.focusedPaneID
        source.mutate { $0.setRoot(.route(.sessions), in: moved) }
        let sourceID: WorkspaceWindowID? = { if case .window(let w) = source.scope { w } else { nil } }()
        let targetPane = target.focusedPaneID
        #expect(c.dockPane(PaneDragPayload(window: sourceID, pane: moved), into: target, onto: targetPane, zone: .bottom))
        #expect(source.selectedTab.panes.count == 1)
        #expect(target.selectedTab.panes.count == 2)
        #expect(target.pane(moved)?.stack == [.route(.sessions)])
        #expect(target.focusedPaneID == moved)
    }

    @Test func theOnlyPaneOfAWindowCannotBeDraggedAway() {
        let c = controller()
        let source = c.model(for: c.store.createWindow())
        let target = c.model(for: c.store.createWindow())
        let sourceID: WorkspaceWindowID? = { if case .window(let w) = source.scope { w } else { nil } }()
        #expect(!c.dockPane(PaneDragPayload(window: sourceID, pane: source.focusedPaneID), into: target, onto: target.focusedPaneID, zone: .right))
        #expect(target.selectedTab.panes.count == 1)
    }

    @Test func aTearOffKeepsThePanesStateInADetachedWindow() throws {
        let c = controller()
        let model = c.model(for: c.store.createWindow())
        model.split(.horizontal)
        let pane = model.focusedPaneID
        model.mutate { $0.setRoot(.route(.alerts), in: pane) }
        model.detach(pane, near: NSPoint(x: 300, y: 300))
        let detached = try #require(c.store.detachedPane(pane))
        #expect(detached.stack == [.route(.alerts)])
        #expect(c.store.detachedFrame(pane)?.count == 4)
        #expect(model.selectedTab.panes.count == 1)
    }

    @Test func aDropTargetRegistersOnlyForPaneDrags() {
        let c = controller()
        let model = c.model(for: c.store.createWindow())
        let target = PaneDropTargetView(model: model, paneID: model.focusedPaneID)
        #expect(target.registeredDraggedTypes == [.wheelhousePane])          // never file URLs: kubeconfig drops keep their own target
    }
}
