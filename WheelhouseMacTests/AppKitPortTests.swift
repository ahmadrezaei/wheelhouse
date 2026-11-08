import Testing
import AppKit
import Foundation
import SwiftTerm
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The AppKit ports driven without a visible window (the views have a test seam that makes them count as visible):
/// virtualisation, incremental updates, coalescing and the editor's attributes.
@Suite("AppKit ports")
@MainActor
struct AppKitPortTests {
    private func lines(_ range: Range<Int>, text: String = "GET /healthz 200 12ms") -> [LogLine] {
        range.map { LogLine(id: $0, message: "\(text) #\($0)", timestamp: "2026-11-07T10:00:00.000Z", level: $0 % 50 == 0 ? .error : .none) }
    }

    private func logs(width: CGFloat = 900, height: CGFloat = 600) -> LogsScrollView {
        let v = LogsScrollView()
        v.assumeVisible = true
        v.frame = NSRect(x: 0, y: 0, width: width, height: height)
        v.layoutSubtreeIfNeeded()
        return v
    }

    private func apply(_ v: LogsScrollView, _ l: [LogLine], follow: Bool = true, wrap: Bool = true) {
        var s = LogsDisplaySettings()
        s.wrap = wrap
        v.apply(lines: l, settings: s, matcher: nil, follow: follow, scrollTarget: nil)
    }

    // MARK: Logs

    @Test func twentyThousandLinesLoadOnceAndFollowTheEnd() {
        let v = logs()
        let start = ContinuousClock.now
        apply(v, lines(0..<20_000))
        let elapsed = ContinuousClock.now - start
        #expect(v.displayedLineCount == 20_000 && v.tableRowCount == 20_000)
        #expect(v.applyCounts.reload == 1)
        #expect(v.isAtBottom)
        #expect(elapsed < .seconds(1), "initial load of 20,000 lines took \(elapsed)")
    }

    @Test func appendsInsertRowsInsteadOfReloading() async throws {
        let v = logs()
        apply(v, lines(0..<5_000))
        for batch in 1...10 { apply(v, lines(0..<(5_000 + batch * 200))) }
        // Updates inside 250 ms are coalesced: wait for the last one.
        try await Task.sleep(for: .milliseconds(600))
        #expect(v.displayedLineCount == 7_000)
        #expect(v.applyCounts.reload == 1)
        #expect(v.applyCounts.append >= 1)
        #expect(v.isAtBottom)
    }

    @Test func aFullRingDroppingAtTheFrontOnlyAddsRowsUntilTheSlackIsUsed() async throws {
        let v = logs()
        apply(v, lines(0..<20_000))
        try await Task.sleep(for: .milliseconds(600))   // a following table updates twice a second
        // The ring is full: 100 lines fall off the front while 100 arrive at the back. P1: the dropped lines' rows stay for now
        // (front slack), so only rows at the end are added (removing front rows on every update rebuilt every row view).
        apply(v, lines(100..<20_100))
        try await Task.sleep(for: .milliseconds(600))   // a following table updates twice a second
        #expect(v.applyCounts.frontDrop == 1 && v.applyCounts.frontTrim == 0)
        #expect(v.applyCounts.reload == 1)               // never a second full reload
        #expect(v.tableRowCount == 20_100 && v.isAtBottom)
        // Past the slack (a tenth of the lines) the old rows go in one removal.
        apply(v, lines(2_500..<22_500))
        try await Task.sleep(for: .milliseconds(600))   // a following table updates twice a second
        #expect(v.applyCounts.frontTrim == 1 && v.applyCounts.reload == 1)
        #expect(v.tableRowCount == 20_000 && v.displayedLineCount == 20_000 && v.isAtBottom)
    }

    @Test func aReaderScrolledAwayKeepsTheirPlaceWhileTheRingDrops() async throws {
        let v = logs(height: 300)
        apply(v, lines(0..<5_000))
        try await Task.sleep(for: .milliseconds(300))
        apply(v, lines(0..<5_000), follow: false)                             // the reader scrolled away (follow off) ...
        try await Task.sleep(for: .milliseconds(300))
        apply(v, lines(50..<5_050), follow: false)                            // ... and the full ring moves on
        try await Task.sleep(for: .milliseconds(300))
        #expect(v.applyCounts.reload == 1 && v.applyCounts.frontDrop == 1)    // no full reload under the reader
        #expect(v.tableRowCount == 5_050)
    }

    @Test func updatesInsideAQuarterSecondAreCoalesced() async throws {
        let v = logs()
        apply(v, lines(0..<1_000))
        try await Task.sleep(for: .milliseconds(300))
        let base = v.applyCounts
        for i in 1...20 { apply(v, lines(0..<(1_000 + i * 10))) }       // 20 updates in a burst
        try await Task.sleep(for: .milliseconds(600))
        let appended = v.applyCounts.append - base.append
        #expect(appended <= 3, "20 updates in a burst became \(appended) table updates")
        #expect(v.displayedLineCount == 1_200)                            // and the last state won
    }

    @Test func nothingIsDrawnWhileHiddenAndTheLatestStateAppliesOnReturn() {
        let v = LogsScrollView()                                          // no window, not assumed visible: hidden
        v.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        apply(v, lines(0..<500))
        #expect(v.displayedLineCount == 0 && v.tableRowCount == 0)
        v.assumeVisible = true
        apply(v, lines(0..<800))
        #expect(v.displayedLineCount == 800)
    }

    @Test func wrappedRowsGrowWithLongLinesAndFixedHeightWithoutWrap() {
        let v = logs(width: 400)
        let long = String(repeating: "x", count: 600)
        apply(v, [LogLine(id: 0, message: "short"), LogLine(id: 1, message: long)])
        #expect(v.tableRowCount == 2)
        apply(v, [LogLine(id: 0, message: "short"), LogLine(id: 1, message: long)], wrap: false)
        #expect(v.tableRowCount == 2)
    }

    // MARK: Resource table

    private func tableKeys(_ n: Int, version: String = "1") -> [KubeRowKey] { (0..<n).map { KubeRowKey(id: "p\($0)", version: version) } }
    private func row(_ i: Int) -> KubeTableRow {
        KubeTableRow(id: "p\(i)", name: "pod-\(i)", namespace: "shop", status: "Running", tone: .healthy, ready: "1/1", upToDate: "", restarts: "0", node: "n1",
                     cpu: "1m", memory: "4Mi", details: "", age: "3d", extra: [], accessibility: "pod-\(i), Pod, Running")
    }

    @Test func theTableReloadsOnFirstLoadAndUpdatesIncrementallyAfter() {
        let t = KubeTableScrollView()
        t.assumeVisible = true
        t.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let cols = KubeColumn.columns(for: .pod, showNamespace: true, extra: [])
        t.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false, keys: tableKeys(2_000), rowAt: row)
        #expect(t.tableRowCount == 2_000 && t.reloadCount == 1)
        // A few pods change, one disappears, three appear: no reload.
        var keys = tableKeys(2_000)
        keys.remove(at: 5)
        keys[40].version = "2"
        keys.append(contentsOf: (0..<3).map { KubeRowKey(id: "n\($0)", version: "1") })
        t.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false, keys: keys, rowAt: row)
        // Applied now or after the 250 ms window; wait for it.
        #expect(t.tableRowCount == 2_000 || t.tableRowCount == 2_002)
    }

    @Test func aSortChangeReloadsTheTable() async throws {
        let t = KubeTableScrollView()
        t.assumeVisible = true
        t.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        let cols = KubeColumn.columns(for: .pod, showNamespace: true, extra: [])
        t.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false, keys: tableKeys(100), rowAt: row)
        try await Task.sleep(for: .milliseconds(300))
        t.update(kindID: ResourceKind.pod.id, columns: cols, sort: .name, reversed: true, keys: tableKeys(100).reversed(), rowAt: row)
        try await Task.sleep(for: .milliseconds(300))
        #expect(t.reloadCount == 2)
        #expect(t.tableRowCount == 100)
    }

    // MARK: Editor

    @Test func theEditorHighlightsYAMLAndNumbersLines() throws {
        let editor = CodeEditorScrollView()
        editor.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let yaml = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: demo # comment\ndata:\n  replicas: 3\n  enabled: true\n"
        editor.setText(yaml)
        #expect(editor.lineStarts.count == 8)                               // seven lines plus the empty last one
        let storage = try #require(editor.textView.textStorage)
        let ns = yaml as NSString
        let keyRange = ns.range(of: "kind")
        let valueRange = ns.range(of: "true")
        let kindColor = storage.attribute(.foregroundColor, at: keyRange.location, effectiveRange: nil) as? NSColor
        let boolColor = storage.attribute(.foregroundColor, at: valueRange.location, effectiveRange: nil) as? NSColor
        #expect(kindColor != nil && boolColor != nil)
        #expect(kindColor != boolColor)                                     // keys and keywords are coloured differently
        #expect(editor.lineIndex(forOffset: ns.range(of: "metadata").location) == 2)
        editor.jump(toLine: 6)
        #expect(editor.textView.selectedRange().location == editor.lineStarts[5])
    }

    @Test func diagnosticsUnderlineTheirLine() throws {
        let editor = CodeEditorScrollView()
        let text = "a: 1\nb: [\nc: 3\n"
        editor.setText(text)
        editor.setDiagnostics([YAMLDiagnostic(line: 2, column: 1, message: "bad flow sequence")])
        let storage = try #require(editor.textView.textStorage)
        let at = (text as NSString).range(of: "b: [").location
        #expect(storage.attribute(.underlineStyle, at: at, effectiveRange: nil) != nil)
        let clean = (text as NSString).range(of: "c: 3").location
        #expect(storage.attribute(.underlineStyle, at: clean, effectiveRange: nil) == nil)
    }

    @Test func tabInsertsSpacesAndNewlineKeepsTheIndent() {
        let editor = CodeEditorScrollView()
        editor.setText("  key: value")
        editor.setEditable(true)
        editor.textView.setSelectedRange(NSRange(location: 12, length: 0))
        editor.textView.insertNewline(nil)
        #expect(editor.textView.string == "  key: value\n  ")
        editor.textView.insertTab(nil)
        #expect(editor.textView.string.hasSuffix("\n    "))
        #expect(!editor.textView.string.contains("\t"))
    }

    @Test func aHugeDocumentOnlyHighlightsAWindowAroundTheEdit() throws {
        let editor = CodeEditorScrollView()
        var text = ""
        for i in 0..<12_000 { text += "key\(i): value-\(i)-padding-padding\n" }
        #expect(text.utf16.count > 150_000)
        editor.setText(text)
        let storage = try #require(editor.textView.textStorage)
        // The edit offset starts at the top: lines far below the window keep the base colour.
        let far = (text as NSString).range(of: "key11990:").location
        let near = (text as NSString).range(of: "key10:").location
        let nearColor = storage.attribute(.foregroundColor, at: near, effectiveRange: nil) as? NSColor
        let farColor = storage.attribute(.foregroundColor, at: far, effectiveRange: nil) as? NSColor
        #expect(nearColor != farColor)
    }

    // MARK: Terminal

    @Test func scrollbackIsCappedAndClamped() {
        #expect(SwiftTermSurface.Scrollback.clamp(500) == 1_000)
        #expect(SwiftTermSurface.Scrollback.clamp(5_000) == 5_000)
        #expect(SwiftTermSurface.Scrollback.clamp(1_000_000) == 20_000)
        #expect(SwiftTermSurface(scrollback: 999_999).scrollbackLines == 20_000)
        #expect(SwiftTermSurface(scrollback: SwiftTermSurface.Scrollback.signInLines).scrollbackLines == 1_000)
        let defaults = UserDefaults(suiteName: "wh.test.scrollback")!
        defaults.removePersistentDomain(forName: "wh.test.scrollback")
        #expect(SwiftTermSurface.Scrollback.configured(defaults: defaults) == 5_000)
    }

    @Test func theSurfaceRendersAlternateScreenApplications() {
        let surface = SwiftTermSurface(scrollback: 5_000)
        surface.view.frame = NSRect(x: 0, y: 0, width: 800, height: 500)
        // What vim does on start: alternate screen, clear, tildes down the left edge, a status line at the bottom.
        var out = "\u{1b}[?1049h\u{1b}[2J\u{1b}[H"
        for row in 1...10 { out += "\u{1b}[\(row);1H~" }
        out += "\u{1b}[12;1H\u{1b}[7m\"notes.txt\" 3L, 42B\u{1b}[0m"
        surface.feed(out)
        let text = surface.allText()
        #expect(text.contains("\"notes.txt\" 3L, 42B"))
        #expect(text.contains("~"))
        // Leaving the alternate screen restores the shell screen.
        surface.feed("\u{1b}[?1049l")
        #expect(!surface.allText().contains("notes.txt"))
    }

    @Test func theSurfaceRendersColouredFullScreenTables() {
        let surface = SwiftTermSurface(scrollback: 5_000)
        // What htop does: alternate screen, 256-colour bars, cursor addressing, a header with reverse video.
        var out = "\u{1b}[?1049h\u{1b}[H\u{1b}[2J"
        out += "\u{1b}[38;5;46m  1  [||||||||||||      30.0%]\u{1b}[0m\r\n"
        out += "\u{1b}[48;5;21m\u{1b}[97m  PID USER      PRI  NI  VIRT   RES   SHR S CPU% MEM%   TIME+  Command\u{1b}[0m\r\n"
        out += "    1 root       20   0  1204   640   576 S  0.0  0.0  0:00.01 /bin/sh\r\n"
        surface.feed(out)
        let text = surface.allText()
        #expect(text.contains("PID USER"))
        #expect(text.contains("30.0%"))
        #expect(text.contains("/bin/sh"))
    }

    /// Records the memory cost of terminal lines: a full 5,000-line scrollback at 120 columns. Printed for the baseline.
    @Test func terminalScrollbackCostPerLineIsMeasured() {
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
        let surface = SwiftTermSurface(scrollback: 5_000)
        surface.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        surface.feed("")                                                    // make sure the terminal exists before measuring
        let before = footprint()
        let line = String(repeating: "abcdefghij", count: 12)                // 120 columns
        for i in 0..<5_000 { surface.feed("\u{1b}[3\(i % 7 + 1)m\(line)\u{1b}[0m\r\n") }
        let after = footprint()
        let perLineKB = (after - before) * 1_024 / 5_000
        print("TERMINAL_SCROLLBACK_COST: 5000 lines x 120 cols = \(String(format: "%.1f", after - before)) MB, \(String(format: "%.2f", perLineKB)) KB per line")
        #expect(after - before < 40, "5,000 lines grew the footprint by \(after - before) MB")      // budget note: about 12 MB
        // The cap holds: feeding 3x more keeps the buffer at the scrollback plus the screen.
        for _ in 0..<10_000 { surface.feed("\(line)\r\n") }
        let rows = surface.allText().split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(rows <= 5_000 + 80, "buffer has \(rows) rows")
    }

    // MARK: Memory pressure and energy

    private final class FakeMemorySource: MemoryPressureSource, @unchecked Sendable {
        var handler: (@Sendable (MemoryPressureLevel) -> Void)?
        func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) -> @Sendable () -> Void { self.handler = handler; return { [weak self] in self?.handler = nil } }
    }

    @Test func memoryWarningTrimsNonVisibleLogBuffersAndLeavesVisibleOnes() async throws {
        let registry = ClusterRegistry.preview()
        let coordinator = MacEnergyCoordinator(registry: registry, memorySource: FakeMemorySource(), releaseGrace: 0.05, visibility: { true })
        let hidden = LogStream(capacity: 10_000, limits: .desktop)
        let visible = LogStream(capacity: 10_000, limits: .desktop)
        hidden.isVisible = false
        for i in 0..<5_000 { hidden.appendMarker("line \(i)"); visible.appendMarker("line \(i)") }
        try await Task.sleep(for: .milliseconds(700))                       // markers reach the buffer on the flush timer
        #expect(hidden.count == 5_000 && visible.count == 5_000)
        coordinator.handleMemoryPressure(.warning)
        #expect(coordinator.memoryWarnings == 1)
        #expect(hidden.count == MacEnergyCoordinator.trimmedLogLines)       // non-visible streams keep the last 2,000 lines
        #expect(visible.count == 5_000)                                      // the visible one is untouched
    }

    @Test func hiddenWindowsReleaseWatchesAfterTheGraceAndResumeOnReturn() async throws {
        let registry = ClusterRegistry.preview()
        var visible = true
        let coordinator = MacEnergyCoordinator(registry: registry, memorySource: FakeMemorySource(), releaseGrace: 0.1, visibility: { visible })
        coordinator.evaluateVisibility()
        #expect(coordinator.windowsVisible && !coordinator.released)
        visible = false
        coordinator.evaluateVisibility()
        #expect(!coordinator.windowsVisible && !coordinator.released)         // inside the grace: nothing is released yet
        visible = true
        coordinator.evaluateVisibility()                                       // back before the grace ended: never released
        try await Task.sleep(for: .milliseconds(250))
        #expect(!coordinator.released)
        visible = false
        coordinator.evaluateVisibility()
        try await Task.sleep(for: .milliseconds(300))
        #expect(coordinator.released)                                          // hidden past the grace: released
        visible = true
        coordinator.evaluateVisibility()
        #expect(!coordinator.released)                                         // visible again: resumed
    }

    @Test func criticalMemoryPressureReleasesImmediatelyWhenHidden() {
        let registry = ClusterRegistry.preview()
        let coordinator = MacEnergyCoordinator(registry: registry, memorySource: FakeMemorySource(), releaseGrace: 30, visibility: { false })
        coordinator.evaluateVisibility()
        #expect(!coordinator.released)
        coordinator.handleMemoryPressure(.critical)
        #expect(coordinator.released && coordinator.memoryCriticals == 1)
    }

    @Test func powerSourceIsReadWithoutPolling() {
        _ = PowerSourceMonitor.onBattery                                       // a single IOKit read
        let m = PowerSourceMonitor()
        m.start { _ in }
        m.stop()
    }

    @Test func theCoordinatorAloneSwitchesThePeriodicCadence() {
        let periodic = PeriodicTaskRegistry()
        var visible = true
        let coordinator = MacEnergyCoordinator(registry: ClusterRegistry.preview(), memorySource: FakeMemorySource(), releaseGrace: 30,
                                               visibility: { visible }, periodicTasks: periodic)
        coordinator.evaluateVisibility()
        #expect(periodic.windowsVisible)
        visible = false
        coordinator.evaluateVisibility()
        #expect(!periodic.windowsVisible)                                    // one source of "visible": no second window scan
    }

    // MARK: Workspace windows (P1: an open Settings window is not a visible workspace)

    @Test func onlyRegisteredWorkspaceWindowsCount() {
        let workspace = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        workspace.isReleasedWhenClosed = false; settings.isReleasedWhenClosed = false
        var seen: [NSWindow] = []
        WorkspaceWindows.observe { if $0 === workspace { seen.append($0) } }
        WorkspaceWindows.register(workspace)
        WorkspaceWindows.register(workspace)                                   // idempotent
        #expect(WorkspaceWindows.contains(workspace) && !WorkspaceWindows.contains(settings))
        #expect(WorkspaceWindows.all.filter { $0 === workspace }.count == 1)
        #expect(seen.count == 1)
        var replayed = 0
        WorkspaceWindows.observe { if $0 === workspace { replayed += 1 } }   // a late observer sees the windows already registered
        #expect(replayed == 1)
        // The visibility rule only ever sees registered windows: Settings is not among them, whatever its state.
        #expect(!WorkspaceWindows.all.contains { $0 === settings })
    }

    @Test func aReleasedWorkspaceWindowDropsOut() {
        weak var gone: NSWindow?
        autoreleasepool {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
            w.isReleasedWhenClosed = false
            WorkspaceWindows.register(w)
            gone = w
        }
        // Held weakly: once AppKit lets the window go, it is no longer listed (AppKit may keep it alive a little longer).
        if gone == nil { #expect(!WorkspaceWindows.all.contains { $0 === gone }) }
    }

    // MARK: Log follow off the SwiftUI path (P1)

    private func logsModel() throws -> LogsModel {
        let registry = ClusterRegistry.preview()
        let cluster = try #require(registry.clusters.first)
        let session = try #require(registry.session(for: cluster.id))
        return LogsModel(pod: ResourceRef(clusterID: cluster.id, kind: .pod, namespace: "shop", name: "chatter"), container: nil,
                         previous: false, session: session)
    }

    /// Polls `condition` on the main actor until it holds or `timeout` passes (the stream flush and the table coalescing are timers,
    /// slower under Low Power Mode or thermal pressure).
    private func eventually(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    @Test func theMacTableFollowsTheModelWithoutSwiftUI() async throws {
        let model = try logsModel()
        let v = logs()
        v.track(model)
        model.startStreamSync()
        for i in 0..<50 { model.stream.appendMarker("line \(i)") }
        #expect(try await eventually { v.displayedLineCount == 50 })
        #expect(model.visible.count == 50 && v.isAtBottom)
        v.teardown()
        model.stream.appendMarker("after teardown")
        #expect(try await eventually { model.visible.count == 51 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(v.displayedLineCount == 50)                                   // no longer following
        model.stopStreamSync()
        model.stream.appendMarker("after stop")
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.visible.count == 51)                                    // the model stopped syncing itself
    }

    @Test func newLinesDoNotSnapBackAfterTheUserScrolledAway() async throws {
        let model = try logsModel()
        let v = logs(height: 300)
        v.track(model)
        model.startStreamSync()
        for i in 0..<100 { model.stream.appendMarker("line \(i)") }
        #expect(try await eventually { v.displayedLineCount == 100 && v.isAtBottom })
        // A user scroll sets the model's follow to false before SwiftUI passes it on: the next lines must not scroll to the end.
        model.userScrolledAway()
        for i in 0..<200 { model.stream.appendMarker("more \(i)") }
        #expect(try await eventually { v.displayedLineCount == 300 })
        #expect(!v.isAtBottom)
        model.stopStreamSync()
    }

    @Test func theTableFollowsOnlyTheModelItWasLastGiven() async throws {
        let a = try logsModel(), b = try logsModel()
        let v = logs()
        a.startStreamSync(); b.startStreamSync()
        v.track(a)
        a.stream.appendMarker("a0")
        #expect(try await eventually { v.displayedLineCount == 1 })
        v.track(b)
        for i in 0..<3 { b.stream.appendMarker("b\(i)") }
        #expect(try await eventually { v.displayedLineCount == 3 })
        for i in 0..<5 { a.stream.appendMarker("a\(i + 1)") }
        #expect(try await eventually { a.visible.count == 6 })
        try await Task.sleep(for: .milliseconds(400))
        #expect(v.displayedLineCount == 3)                                    // the old model's lines never reach the table
        a.stopStreamSync(); b.stopStreamSync()
    }

    @Test func aNewModelWithOverlappingLineIDsReplacesTheRows() async throws {
        let a = try logsModel(), b = try logsModel()
        a.startStreamSync(); b.startStreamSync()
        for i in 0..<1_000 { a.stream.appendMarker("a\(i)") }
        for i in 0..<300 { b.stream.appendMarker("old b\(i)") }
        #expect(try await eventually { a.visible.count == 1_000 && b.visible.count == 300 })
        b.clear()                                                             // ids go on counting: b now holds ids 300..<1300
        for i in 0..<1_000 { b.stream.appendMarker("b\(i)") }
        #expect(try await eventually { b.visible.count == 1_000 })
        let v = logs()
        v.track(a)
        #expect(try await eventually { v.displayedLineCount == 1_000 })
        let reloads = v.applyCounts.reload
        v.track(b)
        #expect(try await eventually { v.applyCounts.reload == reloads + 1 })
        #expect(v.displayedLineCount == 1_000)                                // b's lines only, not a's rows plus b's tail
        a.stopStreamSync(); b.stopStreamSync()
    }

    @Test func theStreamSyncLastsWhileAnyScreenHoldsIt() async throws {
        let model = try logsModel()
        model.startStreamSync()                                               // the new screen appears ...
        model.startStreamSync()
        model.stopStreamSync()                                                // ... before the old one goes
        model.stream.appendMarker("still synced")
        #expect(try await eventually { model.visible.count == 1 })
        model.stopStreamSync()
        model.stopStreamSync()                                                // an extra stop is harmless
        model.stream.appendMarker("not synced")
        try await Task.sleep(for: .milliseconds(800))
        #expect(model.visible.count == 1)
    }

    @Test func hasLinesChangesOnlyBetweenEmptyAndNotEmpty() async throws {
        let model = try logsModel()
        model.startStreamSync()
        model.stream.appendMarker("first")
        #expect(try await eventually { model.hasLines })
        let fired = Fired()
        withObservationTracking { _ = model.hasLines; _ = model.statusDroppedCount } onChange: { fired.hit() }
        for i in 0..<10 { model.stream.appendMarker("more \(i)") }
        #expect(try await eventually { model.visible.count == 11 })
        #expect(fired.count == 0)                                             // a flush of new lines does not touch them
        model.clear()
        #expect(!model.hasLines && model.statusLineCount == 0)                 // a reset shows at once
        #expect(fired.count == 1)
        model.stopStreamSync()
    }

    @Test func statusCountsFollowAtMostOncePerSecondWithATrailingUpdate() async throws {
        let model = try logsModel()
        model.startStreamSync()
        for i in 0..<10 { model.stream.appendMarker("a \(i)") }
        #expect(try await eventually { model.statusLineCount == 10 })        // the first change shows at once
        for i in 0..<5 { model.stream.appendMarker("b \(i)") }
        #expect(try await eventually { model.visible.count == 15 })
        let shownAt = ContinuousClock.now
        if model.statusLineCount == 10 {
            // Held back inside the second, then the trailing update lands.
            #expect(try await eventually { model.statusLineCount == 15 })
            #expect(ContinuousClock.now - shownAt <= .milliseconds(1_300))
        }
        #expect(model.statusLineCount == 15)
        model.stopStreamSync()
    }

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func hit() { lock.withLock { n += 1 } }
    }

    // MARK: Performance scenarios (P1)

    @Test func aSavedPerfClusterIsRefreshedOnlyWhenTheContextChanged() throws {
        let saved = ClusterConfig(name: "wh-perf-01", server: try #require(URL(string: "https://127.0.0.1:60561")), authKind: .clientCertificate,
                                  environment: .development, defaultNamespace: "wh-perf")
        let secrets = ClusterSecrets(clientCertificatePEM: "cert", clientKeyPEM: "key", caPEM: "ca")
        var same = saved
        same.id = UUID().uuidString                                            // a freshly made config has its own id and dates
        #expect(PerfScenarioRunner.refreshed(saved, secrets: secrets, from: (same, secrets)) == nil)
        var moved = same
        moved.server = try #require(URL(string: "https://127.0.0.1:52192"))
        let refresh = try #require(PerfScenarioRunner.refreshed(saved, secrets: secrets, from: (moved, secrets)))
        #expect(refresh.config.id == saved.id && refresh.config.server == moved.server)
        let newCA = ClusterSecrets(clientCertificatePEM: "cert", clientKeyPEM: "key", caPEM: "other-ca")
        #expect(PerfScenarioRunner.refreshed(saved, secrets: secrets, from: (same, newCA))?.secrets == newCA)
        let newUser = ClusterSecrets(clientCertificatePEM: "other-cert", clientKeyPEM: "other-key", caPEM: "ca")
        #expect(PerfScenarioRunner.refreshed(saved, secrets: secrets, from: (same, newUser)) != nil)
    }

    @Test func keepVisibleIsOnlyForScenariosThatKeepTheirWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "perf-scenarios-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"name":"idle-1","clusters":3,"windows":1,"tabs":1}"#.utf8).write(to: dir.appending(path: "idle-1.json"))
        try Data(#"{"name":"soak-5","clusters":5,"windows":2,"tabs":2,"cycleSeconds":120}"#.utf8).write(to: dir.appending(path: "soak-5.json"))
        let info: [String: Any] = ["WHPerfScenarioDirectory": dir.path]
        let gate = DevSafetyPolicy(isActive: true)
        let keep = ["app", "-WHPerfScenario", "idle-1", "-WHPerfKeepVisible", "YES"]
        #expect(PerfScenario.requested(arguments: ["app", "-WHPerfScenario", "idle-1", "-WHPerfKeepVisible"], gate: gate, info: info)?.keepsWindowVisible == false)
        #expect(PerfScenario.requested(arguments: keep, gate: gate, info: info)?.keepsWindowVisible == true)
        #expect(PerfScenario.requested(arguments: keep + ["-WHPerfHideAfter", "5"], gate: gate, info: info)?.keepsWindowVisible == false)
        #expect(PerfScenario.requested(arguments: ["app", "-WHPerfScenario", "idle-1"], gate: gate, info: info)?.keepsWindowVisible == false)
        #expect(PerfScenario.requested(arguments: keep, gate: DevSafetyPolicy(isActive: false), info: info) == nil)
        #expect(PerfScenario.requested(arguments: ["app", "-WHPerfScenario", "soak-5"], gate: gate, info: info)?.cycleSeconds == 120)
    }
}
