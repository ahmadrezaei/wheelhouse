import AppKit
import SwiftUI
import Testing
import WheelhouseKit
@testable import WheelhouseMac

/// A provider that answers from the schema bundled with the app and counts where it was called from.
private final class ThreadSpy: ManifestSchemaProviding, @unchecked Sendable {
    private let inner = OpenAPIStore(cluster: "t", serverVersion: "v1.32.0", cacheRoot: nil, fetch: { _ in throw KubeError.unsupported("no openapi") })
    private let lock = NSLock()
    private var main = 0
    private var calls = 0
    var delay: Duration = .zero
    var mainThreadCalls: Int { lock.withLock { main } }
    var callCount: Int { lock.withLock { calls } }

    func kindSchema(for gvk: GroupVersionKind) async -> KindSchema? {
        lock.withLock { calls += 1; if Thread.isMainThread { main += 1 } }
        if delay != .zero { try? await Task.sleep(for: delay) }
        return await inner.kindSchema(for: gvk)
    }
}

@MainActor @Suite("Manifest editor", .serialized)
struct ManifestEditorTests {
    private let deployment = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\nspec:\n  replica: 3\n"

    // MARK: Model

    @Test func analysisRunsOffTheMainThreadAndLandsOnTheModel() async throws {
        let spy = ThreadSpy()
        let model = ManifestAssistModel(schemas: spy, references: nil, namespace: nil)
        model.textChanged(deployment, immediately: true)
        for _ in 0..<100 where model.analyzedGeneration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(spy.callCount == 1 && spy.mainThreadCalls == 0)
        #expect(model.analysis.schemaIssues.map(\.message).contains { $0.hasPrefix("Unknown field “replica”") })
        #expect(model.analysis.outline.map(\.title) == ["Deployment/web"])
    }

    @Test func aStaleAnalysisNeverOverwritesANewerOne() async throws {
        let spy = ThreadSpy()
        spy.delay = .milliseconds(300)
        let model = ManifestAssistModel(schemas: spy, references: nil, namespace: nil)
        model.debounce = .zero
        model.textChanged(deployment, immediately: true)                       // slow: still analysing when the next text arrives
        try await Task.sleep(for: .milliseconds(30))
        let newer = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: fresh\n"
        spy.delay = .zero
        model.textChanged(newer, immediately: true)
        for _ in 0..<100 where model.analysis.outline.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        try await Task.sleep(for: .milliseconds(500))                          // the slow one finishes meanwhile
        #expect(model.analysis.outline.map(\.title) == ["ConfigMap/fresh"])
    }

    @Test func typingIsDebouncedToOneAnalysis() async throws {
        let spy = ThreadSpy()
        let model = ManifestAssistModel(schemas: spy, references: nil, namespace: nil)
        model.debounce = .milliseconds(120)
        for i in 0..<5 { model.textChanged("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\(i)\n") }
        try await Task.sleep(for: .milliseconds(600))
        #expect(spy.callCount == 1)
        #expect(model.analysis.outline.map(\.title) == ["ConfigMap/a4"])
    }

    @Test func theModelSuppliesCompletionsAndHover() async throws {
        let model = ManifestAssistModel(schemas: ThreadSpy(), references: nil,
                                        known: [GroupVersionKind(group: "apps", version: "v1", kind: "Deployment")], namespace: "shop")
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  rep\n"
        let result = await model.completions(text: text, offset: (text as NSString).length - 1)
        #expect(result.items.map(\.label) == ["replicas"])
        let hoverText = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 2\n"
        let hover = await model.hover(text: hoverText, offset: (hoverText as NSString).range(of: "replicas").location + 1)
        #expect(hover?.title == "replicas")
    }

    // MARK: The AppKit editor

    @Test func schemaFindingsAreDrawnAsColouredUnderlines() throws {
        let editor = CodeEditorScrollView()
        let text = "a: 1\nb: \"😀\"\nc: 3\n"
        editor.setText(text)
        let warning = ManifestDiagnostic(span: YAMLSpan(line: 1, column: 0, endLine: 1, endColumn: 1), message: "Unknown field “a”", severity: .warning, source: .schema, path: "a")
        let error = ManifestDiagnostic(span: YAMLSpan(line: 2, column: 3, endLine: 2, endColumn: 7), message: "Expected an integer", severity: .error, source: .schema, path: "b")
        editor.setSchemaDiagnostics([warning, error])
        let storage = try #require(editor.textView.textStorage)
        let ns = text as NSString
        #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil)
        let warnColor = storage.attribute(.underlineColor, at: 0, effectiveRange: nil) as? NSColor
        let emoji = ns.range(of: "\"😀\"")
        var range = NSRange()
        let errColor = storage.attribute(.underlineColor, at: emoji.location, effectiveRange: &range) as? NSColor
        #expect(range == emoji)                                   // the UTF-16 column mapping covers the whole quoted value
        #expect(warnColor != nil && errColor != nil && warnColor != errColor)
        #expect(storage.attribute(.underlineStyle, at: ns.range(of: "c: 3").location, effectiveRange: nil) == nil)
        // Clearing the findings clears the underlines.
        editor.setSchemaDiagnostics([])
        #expect(storage.attribute(.underlineStyle, at: 0, effectiveRange: nil) == nil)
    }

    @Test func nsRangeOfASpanClampsToTheText() {
        let editor = CodeEditorScrollView()
        editor.setText("ab\ncd")
        #expect(editor.nsRange(of: YAMLSpan(line: 2, column: 0, endLine: 2, endColumn: 2)) == NSRange(location: 3, length: 2))
        #expect(editor.nsRange(of: YAMLSpan(line: 9, column: 40, endLine: 9, endColumn: 50)).location <= 5)
    }

    @Test func foldingHidesLinesFromLayoutAndLeavesTheTextAlone() throws {
        let editor = CodeEditorScrollView()
        editor.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let text = "root:\n  a: 1\n  b:\n    c: 2\n    d: 3\n  e: 4\nlast: 5\n"
        editor.setText(text)
        let layout = try #require(editor.textView.textLayoutManager)
        func fragmentCount() -> Int {
            var n = 0
            layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: [.ensuresLayout]) { _ in n += 1; return true }
            return n
        }
        let before = fragmentCount()
        editor.setFolds(ManifestFolding.ranges(in: text), collapsed: [3])      // `b:` closed: hides lines 4 and 5
        #expect(editor.collapsed == [3])
        #expect(editor.isLineHidden(4) && editor.isLineHidden(5) && !editor.isLineHidden(3) && !editor.isLineHidden(6))
        #expect(fragmentCount() == before - 2)
        #expect(editor.textView.string == text)
        editor.toggleFold(atLine: 3)
        #expect(fragmentCount() == before && editor.hiddenLines.isEmpty)
        editor.foldAll()
        #expect(editor.collapsed == [1, 3])
        editor.unfoldAll()
        #expect(editor.collapsed.isEmpty && fragmentCount() == before)
    }

    @Test func aCaretInsideAClosedFoldOpensIt() {
        let editor = CodeEditorScrollView()
        let text = "root:\n  a: 1\n  b: 2\nlast: 5\n"
        editor.setText(text)
        editor.setFolds(ManifestFolding.ranges(in: text), collapsed: [1])
        #expect(editor.collapsed == [1])
        editor.textView.setSelectedRange(NSRange(location: (text as NSString).range(of: "b: 2").location, length: 0))
        editor.selectionDidChange()
        #expect(editor.collapsed.isEmpty)
    }

    @Test func closedFoldsOpenWhenTheLineCountChanges() {
        let editor = CodeEditorScrollView()
        let text = "root:\n  a: 1\n  b: 2\nlast: 5\n"
        editor.setText(text)
        editor.setEditable(true)
        editor.setFolds(ManifestFolding.ranges(in: text), collapsed: [1])
        #expect(editor.collapsed == [1])
        editor.setText("new: 0\n" + text)                      // a line inserted above: line numbers moved
        #expect(editor.collapsed.isEmpty && editor.hiddenLines.isEmpty)
    }

    @Test func typingDeletingAcrossAClosedFoldAndUndoRestoreTheTextWithFoldsOpen() throws {
        let editor = CodeEditorScrollView()
        editor.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        let undoSource = OwnUndoManager()
        editor.textView.delegate = undoSource                          // an undo manager without a window
        let text = "root:\n  a: 1\n  b: 2\n  c: 3\nlast: 5\n"
        editor.setText(text)
        editor.setEditable(true)
        editor.setFolds(ManifestFolding.ranges(in: text), collapsed: [1])
        #expect(editor.collapsed == [1] && editor.isLineHidden(3))
        // Each edit is its own undo step (a real run loop pass would group them by event).
        let undo = undoSource.manager
        undo.groupsByEvent = false
        // Type at the end of the first line, then delete from there across the folded lines.
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        undo.beginUndoGrouping()
        editor.textView.insertText("!", replacementRange: NSRange(location: 5, length: 0))
        undo.endUndoGrouping()
        editor.textDidChange(editedAt: 6)
        let typed = editor.textView.string
        #expect(typed == "root:!\n  a: 1\n  b: 2\n  c: 3\nlast: 5\n")
        let across = NSRange(location: 6, length: (typed as NSString).range(of: "last").location - 6)
        undo.beginUndoGrouping()
        editor.textView.insertText("", replacementRange: across)
        undo.endUndoGrouping()
        editor.textDidChange(editedAt: 6)
        #expect(editor.textView.string == "root:!last: 5\n")
        #expect(editor.collapsed.isEmpty && editor.hiddenLines.isEmpty)
        // Undo brings back the deleted text; the folds stay open (they were never hidden text).
        undoSource.manager.undo()
        editor.textDidChange(editedAt: 6)
        #expect(editor.textView.string == typed)
        undoSource.manager.undo()
        editor.textDidChange(editedAt: 5)
        #expect(editor.textView.string == text && editor.collapsed.isEmpty)
    }

    @Test func theSystemListNarrowsAsTheUserTypesOn() {
        let editor = CodeEditorScrollView()
        editor.setText("re")
        let coordinator = YAMLCodeEditor(text: .constant("re"), isEditable: true, wraps: true, controller: CodeEditorController()).makeCoordinator()
        func item(_ s: String) -> ManifestCompletion { ManifestCompletion(label: s, insertText: s + ": ", detail: nil, documentation: nil, kind: .field) }
        editor.pendingCompletion = ManifestCompletionResult(range: NSRange(location: 0, length: 2), items: ["replicas", "revisionHistoryLimit", "imagePullPolicy"].map(item))
        var index = -1
        func ask(_ range: NSRange) -> [String] {
            coordinator.textView(editor.textView, completions: [], forPartialWordRange: range, indexOfSelectedItem: &index)
        }
        #expect(ask(NSRange(location: 0, length: 2)) == ["replicas: ", "revisionHistoryLimit: "])
        editor.setText("rep")                                                        // a longer query: the second ask
        #expect(ask(NSRange(location: 0, length: 3)) == ["replicas: "])
        editor.setText("pol")                                                        // substring-only matches still reach the list
        #expect(ask(NSRange(location: 0, length: 3)) == ["imagePullPolicy: "])
        editor.setText("zzz")
        #expect(ask(NSRange(location: 0, length: 3)).isEmpty)
        #expect(index == 0)
    }

    // MARK: Services

    private func session(_ config: ClusterConfig) -> ClusterSession { ClusterSession(config: config, client: DemoKubeClient(config: config)) }

    @Test func aRebuiltSessionNeverGetsTheOldStore() async throws {
        let services = SchemaServices()
        services.cacheRoot = nil
        let config = DemoFleet.configs[0]
        let first = session(config)
        let store1 = await services.store(for: first)
        #expect(await services.store(for: first) === store1)
        let rebuilt = session(config)                                  // same cluster, a new session and client
        let store2 = await services.store(for: rebuilt)
        #expect(store2 !== store1)
        #expect(services.storeCount == 1)
    }

    @Test func aRemovedClusterReleasesItsStore() async throws {
        let services = SchemaServices()
        services.cacheRoot = nil
        let a = session(DemoFleet.configs[0]), b = session(DemoFleet.configs[1])
        let storeA = await services.store(for: a)
        _ = await services.store(for: b)
        #expect(services.storeCount == 2)
        _ = await storeA.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment"))
        #expect(services.cache.totalCost > 0)
        services.drop(clusterID: a.id)
        #expect(services.storeCount == 1)
        for _ in 0..<50 where services.cache.keys.contains(where: { $0.hasPrefix("cluster:") }) { try await Task.sleep(for: .milliseconds(20)) }
        // The bundled documents (no cluster prefix) are shared; a cluster's own are gone.
        #expect(!services.cache.keys.contains { $0.hasPrefix("cluster:\(a.id)|") })
        // A session that no longer exists is pruned on the next call.
        do { let temporary = session(DemoFleet.configs[2]); _ = await services.store(for: temporary) }
        _ = await services.store(for: b)
        #expect(services.storeCount == 1)
    }

    @Test func everyStoreSharesTheSingleBudget() async throws {
        let services = SchemaServices()
        services.cacheRoot = nil
        let a = session(DemoFleet.configs[0]), b = session(DemoFleet.configs[1])
        let storeA = await services.store(for: a), storeB = await services.store(for: b)
        _ = await storeA.kindSchema(for: GroupVersionKind(group: "", version: "v1", kind: "Pod"))
        let costA = await storeA.memoryCost, costB = await storeB.memoryCost
        #expect(costA == services.cache.totalCost && costB == services.cache.totalCost)
        #expect(services.cache.limit == 32 * 1024 * 1024)
        services.editorOpened()
        services.editorOpened()
        services.editorClosed()
        #expect(services.cache.totalCost > 0)
        services.editorClosed()                                         // the last editor closing releases the parsed schemas
        #expect(services.cache.totalCost == 0)
    }

    @Test func activationOnASlowClusterRunsTheProbesSideBySideAndEndsWithFindings() async throws {
        SchemaServices.shared.cacheRoot = nil
        let slow = SlowClient(delay: .milliseconds(600))
        let model = ManifestAssistModel(session: ClusterSession(config: DemoFleet.configs[0], client: slow), namespace: nil)
        model.textChanged(deployment, immediately: true)
        for _ in 0..<100 where model.analyzedGeneration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.analysis.schemaIssues.isEmpty)
        let started = ContinuousClock.now
        let activation = Task { await model.activate() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.isLoadingSchema && !model.isActive)                           // "Loading schema…" while the cluster is slow
        await activation.value
        let took = ContinuousClock.now - started
        #expect(took < .milliseconds(1_150), "version and discovery ran one after the other (\(took))")
        #expect(!model.isLoadingSchema && model.isActive)
        // Never ends stale: the text is analysed again with the schema it found (the bundled one, as the client serves no OpenAPI).
        for _ in 0..<100 where model.analysis.schemaIssues.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.analysis.schemaIssues.map(\.message).contains { $0.hasPrefix("Unknown field “replica”") })
    }

    @Test func aKindNoSchemaKnowsEndsWithTheNoSchemaNote() async throws {
        SchemaServices.shared.cacheRoot = nil
        let model = ManifestAssistModel(session: ClusterSession(config: DemoFleet.configs[0], client: SlowClient(delay: .milliseconds(50))), namespace: nil)
        let text = "apiVersion: example.com/v1\nkind: Gizmo\nmetadata:\n  name: g\n"
        model.textChanged(text, immediately: true)
        await model.activate()
        for _ in 0..<100 where model.analysis.schemaNote == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.analysis.schemaNote == "No schema for Gizmo (example.com/v1): only the YAML is checked")
        #expect(model.analysis.schemaIssues.isEmpty)
    }

    @Test func viewingDoesNoSchemaWorkUntilEditOrFirstHover() async throws {
        SchemaServices.shared.cacheRoot = nil
        let model = ManifestAssistModel(session: session(DemoFleet.configs[0]), namespace: nil)
        #expect(!model.isActive)
        model.textChanged(deployment, immediately: true)
        for _ in 0..<100 where model.analyzedGeneration == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.isActive && model.analysis.schemaIssues.isEmpty)           // syntax, outline and folds only
        #expect(model.analysis.outline.map(\.title) == ["Deployment/web"])
        let hover = await model.hover(text: deployment, offset: (deployment as NSString).range(of: "replica").location + 1)
        #expect(model.isActive && hover == nil)
        for _ in 0..<100 where model.analysis.schemaIssues.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        #expect(model.analysis.schemaIssues.map(\.message).contains { $0.hasPrefix("Unknown field “replica”") })
    }

    @Test func managedFieldsStartClosed() {
        let text = "metadata:\n  name: x\n  managedFields:\n    - manager: kubectl\n      operation: Apply\nspec: {}\n"
        let folds = ManifestFolding.ranges(in: text)
        #expect(ManifestFolding.defaultCollapsed(in: text, folds: folds) == [3])
    }

    @Test func completionFeedsTheSystemList() {
        let editor = CodeEditorScrollView()
        editor.setText("sp")
        editor.setEditable(true)
        let view = YAMLCodeEditor(text: .constant("sp"), isEditable: true, wraps: true, controller: CodeEditorController())
        let coordinator = view.makeCoordinator()
        editor.pendingCompletion = ManifestCompletionResult(range: NSRange(location: 0, length: 2), items: [
            ManifestCompletion(label: "spec", insertText: "spec: ", detail: "SomeSpec", documentation: nil, kind: .field)])
        var index = -1
        let words = coordinator.textView(editor.textView, completions: [], forPartialWordRange: NSRange(location: 0, length: 2), indexOfSelectedItem: &index)
        #expect(words == ["spec: "] && index == 0)
        editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(editor.textView.rangeForUserCompletion == NSRange(location: 0, length: 2))      // from where the suggestions began to the caret
        editor.textView.insertCompletion("spec: ", forPartialWordRange: NSRange(location: 0, length: 2), movement: NSReturnTextMovement, isFinal: true)
        #expect(editor.pendingCompletion == nil, "completion should clear when final")
        #expect(editor.textView.string.contains("spec: "))        // the replacement itself is the system list's job; outside a live session it inserts
    }

    @Test func toggleCommentAddsAndRemovesAtTheShallowestIndent() {
        #expect(CodeEditorScrollView.toggledComment("a: 1\n  b: 2\n") == "# a: 1\n#   b: 2\n")
        #expect(CodeEditorScrollView.toggledComment("# a: 1\n#   b: 2\n") == "a: 1\n  b: 2\n")
        #expect(CodeEditorScrollView.toggledComment("  a: 1\n\n  b: 2") == "  # a: 1\n\n  # b: 2")
        #expect(CodeEditorScrollView.toggledComment("  # a\n  b\n") == "  # # a\n  # b\n")
    }

    @Test func toggleCommentWorksOnTheSelection() {
        let editor = CodeEditorScrollView()
        editor.setText("a: 1\nb: 2\nc: 3\n")
        editor.setEditable(true)
        editor.textView.setSelectedRange(NSRange(location: 5, length: 4))
        editor.toggleComment()
        #expect(editor.textView.string == "a: 1\n# b: 2\nc: 3\n")
        editor.toggleComment()
        #expect(editor.textView.string == "a: 1\nb: 2\nc: 3\n")
    }

    @Test func theGutterShowsWarningsAndErrorsOnTheirLines() {
        let editor = CodeEditorScrollView()
        editor.setText("a: 1\nb: 2\n")
        editor.setDiagnostics([YAMLDiagnostic(line: 2, column: 1, message: "bad")])
        editor.setSchemaDiagnostics([ManifestDiagnostic(span: YAMLSpan(line: 1, column: 0, endLine: 1, endColumn: 1), message: "w", severity: .warning, source: .schema, path: "a")])
        #expect(editor.diagnosticMessage(at: 0)?.1 == "w")
        #expect(editor.diagnosticMessage(at: 6)?.1 == "bad")
    }

    // MARK: The route

    @Test func theYAMLRouteOpensTheManifestEditorOnTheMac() {
        let ref = ResourceRef(clusterID: "c", kind: .deployment, namespace: "shop", name: "web")
        #expect(String(describing: type(of: YAMLEditorView(ref: ref).body)) == "ManifestEditorView")
    }

    @Test func theEditorRendersALiveObjectFromADemoCluster() async throws {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.manifest.tests") ?? .standard)
        registry.enterDemoMode(persist: false)
        let session = try #require(registry.session(for: registry.clusters[0].id))
        let list = try await session.client.listRaw(.deployment, namespace: nil, options: ListOptions())
        let first = try #require(list["items"]?.arrayValue?.first)
        let name = try #require(first.value(at: "metadata.name")?.stringValue)
        let ref = ResourceRef(clusterID: session.id, kind: .deployment, namespace: first.value(at: "metadata.namespace")?.stringValue, name: name)
        SchemaServices.shared.cacheRoot = FileManager.default.temporaryDirectory.appending(path: "wh-manifest-\(UUID().uuidString)")

        let hosting = NSHostingView(rootView: AnyView(ManifestEditorView(ref: ref).environment(registry).environment(AppPreferences(defaults: UserDefaults(suiteName: "wh.manifest.prefs") ?? .standard)).frame(width: 900, height: 600)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        var editor: CodeEditorScrollView?
        for _ in 0..<60 where editor == nil || editor?.textView.string.contains("kind: Deployment") != true {
            try await Task.sleep(for: .milliseconds(100))
            editor = Self.find(CodeEditorScrollView.self, in: hosting)
        }
        let text = try #require(editor?.textView.string)
        #expect(text.contains("kind: Deployment") && text.contains("name: \(name)"))
        #expect(editor?.textView.isEditable == false)                            // viewing until Edit is pressed
        // Folds were computed from the shown YAML.
        for _ in 0..<40 where editor?.hiddenLines == nil { try await Task.sleep(for: .milliseconds(50)) }
    }

    /// Records what an open editor costs: a 2,000-line multi-document file in the AppKit editor with its analysis and the bundled
    /// schemas loaded. Printed for `perf/baselines/M7.json`.
    @Test func theFootprintOfAnOpenEditorIsMeasured() async throws {
        func footprintMB() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let r = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
        }
        var docs: [String] = []
        for i in 0..<90 {
            docs.append("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web-\(i)\n  labels:\n    app: web-\(i)\nspec:\n  replicas: 2\n  selector:\n    matchLabels:\n      app: web-\(i)\n  template:\n    metadata:\n      labels:\n        app: web-\(i)\n    spec:\n      containers:\n        - name: web\n          image: nginx:1.27\n          ports:\n            - containerPort: 80\n          resources:\n            requests:\n              cpu: 100m\n              memory: 64Mi\n")
        }
        let text = docs.joined(separator: "---\n")
        #expect(text.split(separator: "\n").count >= 2_000)
        let before = footprintMB()
        let editor = CodeEditorScrollView()
        editor.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        let window = NSWindow(contentRect: editor.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        window.orderBack(nil)
        defer { window.close() }
        editor.setText(text)
        let model = ManifestAssistModel(schemas: ThreadSpy(), references: nil, namespace: nil)
        model.textChanged(text, immediately: true)
        for _ in 0..<100 where model.analyzedGeneration == 0 { try await Task.sleep(for: .milliseconds(30)) }
        editor.setSchemaDiagnostics(model.analysis.schemaIssues)
        editor.setFolds(model.analysis.folds, collapsed: [])
        editor.textView.layoutSubtreeIfNeeded()
        let after = footprintMB()
        print("MANIFEST footprint: editor open with \(model.analysis.outline.count) documents, +\(String(format: "%.1f", after - before)) MB")
        #expect(model.analysis.diagnostics.isEmpty, "\(model.analysis.diagnostics.prefix(2).map(\.message))")
        #expect(after - before < 60)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }
}


/// Gives a text view an undo manager when it has no window to supply one.
@MainActor
private final class OwnUndoManager: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}


/// A client whose version probe and discovery are slow (an unreachable cluster in miniature) and that serves no OpenAPI.
private final class SlowClient: KubeClientProtocol, @unchecked Sendable {
    let delay: Duration
    private let inner = DemoKubeClient(config: DemoFleet.configs[0])
    init(delay: Duration) { self.delay = delay }
    func version() async throws -> KubeVersion { try await Task.sleep(for: delay); return try await inner.version() }
    func discovery() async throws -> DiscoveryInfo { try await Task.sleep(for: delay); return try await inner.discovery() }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { try await inner.list(type, kind: kind, namespace: namespace, options: options) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { try await inner.get(type, kind: kind, name: name, namespace: namespace) }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { try await inner.listRaw(kind, namespace: namespace, options: options) }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { try await inner.getRaw(kind, name: name, namespace: namespace) }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { inner.watch(type, kind: kind, namespace: namespace, options: options) }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("slow") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("slow") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("slow") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("slow") }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("slow") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("slow") }
}
