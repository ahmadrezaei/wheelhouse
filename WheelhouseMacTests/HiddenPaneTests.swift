import AppKit
import Observation
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The M4a resource pass: hidden panes stop their work and release their consumers, one window's changes leave the others alone,
/// a stale tab id never closes a window, torn-down content gives its memory back, and the Mac chart's geometry.
/// Set by an observation's `onChange` (which may run off the main actor's isolation domain as far as the compiler knows).
private final class Flag: @unchecked Sendable { var fired = false }

@MainActor
@Suite("HiddenPaneTests")
struct HiddenPaneTests {
    private func lines(_ range: Range<Int>) -> [LogLine] { range.map { LogLine(id: $0, message: "line \($0)") } }

    // MARK: Logs

    @Test func aLogTableInAHiddenPaneAppliesNothingAndCatchesUpWhenShown() {
        let v = LogsScrollView()
        v.assumeVisible = true                    // its window counts as visible
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        v.isPaneVisible = false                   // but its tab is not the selected one
        v.apply(lines: lines(0..<500), settings: LogsDisplaySettings(), matcher: nil, follow: true, scrollTarget: nil)
        #expect(v.displayedLineCount == 0 && v.tableRowCount == 0)
        v.isPaneVisible = true                    // shown again: the latest state lands at once
        #expect(v.displayedLineCount == 500)
    }

    @Test func aHiddenLogPaneStopsSyncingWhileItsStreamKeepsFilling() async throws {
        let registry = ClusterRegistry.preview()
        let session = try #require(registry.clusters.first.flatMap { registry.session(for: $0.id) })
        let model = LogsModel(pod: ResourceRef(clusterID: session.id, kind: .pod, namespace: "shop", name: "api-0"), container: nil, previous: false,
                              session: session, limits: .desktop)
        model.startStreamSync()                   // the visible screen's sync (`MacLogsStreamSync`)
        for i in 0..<300 { model.stream.appendMarker("visible \(i)") }
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.visible.count == 300)
        model.stopStreamSync()                    // the pane was hidden: the screen unmounts its sync
        for i in 0..<200 { model.stream.appendMarker("hidden \(i)") }
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.stream.count == 500)        // the stream kept filling
        #expect(model.visible.count == 300)       // nothing was synced or drawn
        model.startStreamSync()                   // shown again: one catch-up sync
        #expect(model.visible.count == 500)
        model.stopStreamSync()
    }

    @Test func aStreamCountsAsVisibleWhileAnyScreenOnItCanBeSeen() throws {
        let registry = ClusterRegistry.preview()
        let session = try #require(registry.clusters.first.flatMap { registry.session(for: $0.id) })
        let model = LogsModel(pod: ResourceRef(clusterID: session.id, kind: .pod, namespace: "shop", name: "api-0"), container: nil, previous: false,
                              session: session, limits: .desktop)
        model.screenDidAppear()
        #expect(model.stream.isVisible)           // nothing reported (iOS): visible, as before
        model.paneVisibilityChanged(false, previous: nil)
        #expect(!model.stream.isVisible)          // its only screen is in a hidden tab
        model.paneVisibilityChanged(true, previous: nil)
        #expect(model.stream.isVisible)           // a second screen on the same model can be seen
        model.paneVisibilityWithdrawn(true)
        #expect(!model.stream.isVisible)          // that screen went away
        model.paneVisibilityChanged(true, previous: false)
        #expect(model.stream.isVisible)           // the first one's tab was selected again
        model.screenDidDisappear()
    }

    // MARK: Terminal

    @Test func aHiddenTerminalDrawsNothingAndGetsItsKeyboardFocusBack() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let terminal = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView?.addSubview(terminal)
        window.makeFirstResponder(terminal)
        let coordinator = TerminalSurfaceHost.Coordinator()
        TerminalSurfaceHost.apply(visible: false, to: terminal, coordinator: coordinator)
        #expect(terminal.isHidden)
        #expect(window.firstResponder !== terminal)
        TerminalSurfaceHost.apply(visible: true, to: terminal, coordinator: coordinator)
        #expect(!terminal.isHidden)
        #expect(window.firstResponder === terminal)
    }

    // MARK: Consumers

    @Test func aHiddenPaneReleasesItsStoreConsumersWithinTheGrace() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        model.releaseGrace = 0.3                  // 30 s in the app; the mechanism is the same
        let pane = model.focusedPaneID
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: PaneHost(env: env, model: model, paneID: pane).frame(width: 900, height: 600))
        let session = try #require(env.registry.session(for: cluster))
        func consumers() -> Int { session.existingUnstructuredStore(kind: .pod, namespace: env.registry.namespace(for: cluster))?.consumerCount ?? 0 }
        try await waitUntil { consumers() > 0 }
        #expect(consumers() > 0)
        model.visibilityChanged(false, thermalGrace: false)
        #expect(consumers() > 0)                  // the grace avoids a re-list for a brief Space switch
        try await waitUntil { consumers() == 0 }
        #expect(consumers() == 0)
        #expect(!model.buildsContent)
        window.contentView = nil
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    // MARK: Per-window observation

    @Test func aChangeInOneWindowDoesNotInvalidateAnother() {
        let store = WorkspaceStore(file: nil)
        let a = store.createWindow(), b = store.createWindow()
        let flag = Flag()
        withObservationTracking { _ = store.state(for: b) } onChange: { flag.fired = true }
        store.mutate(a) { $0.addTab(TabState(showing: .route(.fleet))) }
        #expect(!flag.fired)
        store.mutate(b) { $0.addTab(TabState(showing: .route(.fleet))) }
        #expect(flag.fired)
    }

    @Test func anEqualWriteInvalidatesNothing() {
        let store = WorkspaceStore(file: nil)
        let a = store.createWindow()
        let flag = Flag()
        withObservationTracking { _ = store.state(for: a) } onChange: { flag.fired = true }
        store.mutate(a) { _ in }
        #expect(!flag.fired)
    }

    @Test func aViewThatAskedForAnUnknownWindowHearsWhenItAppearsAndWhenItCloses() {
        let store = WorkspaceStore(file: nil)
        let unknown = WorkspaceWindowID.new()
        let flag = Flag()
        withObservationTracking { _ = store.state(for: unknown) } onChange: { flag.fired = true }
        store.ensureWindow(unknown)
        #expect(flag.fired)
        let other = store.createWindow()
        store.windowAppeared(unknown); store.windowAppeared(other)
        flag.fired = false
        withObservationTracking { _ = store.state(for: unknown) } onChange: { flag.fired = true }
        store.windowClosed(unknown)
        #expect(flag.fired)
        #expect(store.windows[unknown] == nil && store.existingState(for: other) != nil)
    }

    @Test func theSavedFileIsTheSameWithPerWindowBoxes() throws {
        let store = WorkspaceStore(file: nil)
        let a = store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.fleet)), TabState(showing: .route(.alerts))]))
        store.mutate(a) { $0.select(tab: $0.tabs[1].id) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store.snapshot)
        let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: data)
        #expect(decoded.windows.count == store.windows.count)
        #expect(decoded.windows.first { $0.id == a }?.state == store.state(for: a))
    }

    // MARK: Tabs

    @Test func closingATabThatIsAlreadyGoneNeverClosesTheWindow() {
        var state = WorkspaceWindowState(tabs: [TabState(showing: .route(.fleet)), TabState(showing: .route(.alerts))])
        let gone = state.tabs[1].id
        let first = state.closeTab(gone)
        let second = state.closeTab(gone)         // a second click on the same close button: nothing happens
        #expect(first && second)
        #expect(state.tabs.count == 1)
        let last = state.closeTab(state.tabs[0].id)
        #expect(!last)                            // only the last tab asks the caller to close the window
    }

    @Test func closingTabsAsksForOneCoalescedMemoryRelief() async throws {
        let env = MacAppEnvironment.live()
        let model = env.workspace.model(for: env.workspace.store.createWindow())
        MemoryRelief.delay = .milliseconds(100)
        defer { MemoryRelief.delay = .seconds(2) }
        var ids: [TabID] = []
        for _ in 0..<4 { model.newTab(); ids.append(model.selectedTab.id); _ = model.focusedRouter }
        let requests = MemoryRelief.requests, runs = MemoryRelief.runs
        for id in ids { model.closeTab(id) }
        #expect(MemoryRelief.requests == requests + 4)
        #expect(model.liveRouterIDs.count <= 1)   // the closed tabs' routers went with them
        try await Task.sleep(for: .milliseconds(400))
        #expect(MemoryRelief.runs == runs + 1)    // four closes, one relief
    }

    // MARK: Chart

    @Test func theMacChartPicksRoundTicksAboveEveryValueAndTheCapacity() {
        #expect(MetricChartLayout.niceStep(for: 3.7, ticks: 4) == 1)
        #expect(MetricChartLayout.niceStep(for: 7, ticks: 4) == 2)
        #expect(MetricChartLayout.niceStep(for: 9, ticks: 4) == 2.5)
        #expect(MetricChartLayout.niceStep(for: 1_800_000_000, ticks: 4) == 500_000_000)
        let s = MetricChartLayout.Series(id: "u", name: "Usage", color: .systemTeal, style: .area, points: [(0, 1.2), (60, 3.1), (120, 2.4)])
        let layout = MetricChartLayout(series: [s], capacity: 4.5)
        #expect(layout.valueDomain == 0...6)                 // 4.5 (the capacity) in steps of 2
        #expect(layout.valueTicks == [0, 2, 4, 6])
        #expect(layout.timeDomain == 0...120)
        let plot = CGRect(x: 10, y: 0, width: 200, height: 100)
        #expect(layout.point(t: 0, v: 0, in: plot) == CGPoint(x: 10, y: 100))
        #expect(layout.point(t: 120, v: 6, in: plot) == CGPoint(x: 210, y: 0))
        #expect(layout.time(atX: 110, in: plot) == 60)
        let empty = MetricChartLayout(series: [], capacity: nil)
        #expect(empty.valueDomain.upperBound > 0 && empty.valueTicks.first == 0)
        let single = MetricChartLayout(series: [MetricChartLayout.Series(id: "u", name: "Usage", color: .systemTeal, style: .line, points: [(500, 2)])], capacity: nil)
        #expect(single.timeDomain == 440...560)
    }
}
