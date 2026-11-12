import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Diff tab of a Flux Kustomization: its states, with a scripted run in place of flux and Gangway.
@MainActor
struct FluxDiffModelTests {
    private func mappings() -> (FluxFolderMappings, () -> Void) {
        let suite = "flux-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (FluxFolderMappings(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    private func model(_ maps: FluxFolderMappings, run: @escaping @MainActor (URL) async throws -> FluxDiffOutput) -> FluxDiffModel {
        FluxDiffModel(cluster: "c1", namespace: "flux-system", name: "apps", mappings: maps, runDiff: run)
    }

    @Test func unmappedDoesNotRun() async {
        let (maps, cleanup) = mappings()
        defer { cleanup() }
        var calls = 0
        let m = model(maps) { _ in calls += 1; return FluxDiffOutput(text: "", hasChanges: false) }
        #expect(!m.isMapped)
        m.run()
        await m.finish()
        #expect(calls == 0)
        #expect(m.phase == .idle)
    }

    @Test func mappingPersistsAndClears() {
        let (maps, cleanup) = mappings()
        defer { cleanup() }
        let m = model(maps) { _ in FluxDiffOutput(text: "", hasChanges: false) }
        m.map(URL(fileURLWithPath: "/tmp/repo/apps", isDirectory: true))
        #expect(m.folder?.path == "/tmp/repo/apps")
        #expect(model(maps) { _ in FluxDiffOutput(text: "", hasChanges: false) }.folder?.path == "/tmp/repo/apps", "a new model reads the stored mapping")
        m.map(nil)
        #expect(!m.isMapped)
    }

    @Test func resultsFailuresAndMissingFlux() async {
        let (maps, cleanup) = mappings()
        defer { cleanup() }
        let folder = URL(fileURLWithPath: "/tmp/repo/apps", isDirectory: true)
        let outcomes: [(Result<FluxDiffOutput, Error>, FluxDiffModel.Phase)] = [
            (.success(FluxDiffOutput(text: "", hasChanges: false)), .noChanges),
            (.success(FluxDiffOutput(text: "-a\n+b\n", hasChanges: true)), .changes("-a\n+b\n")),
            (.failure(FluxDiffError.notInstalled), .notInstalled),
            (.failure(FluxDiffError.timedOut(120)), .failed("flux diff did not finish within 120 s.")),
            (.failure(FluxDiffError.failed(code: 1, message: "boom")), .failed("flux diff failed: boom")),
        ]
        for (outcome, expected) in outcomes {
            let m = model(maps) { _ in try outcome.get() }
            m.map(folder)
            m.run()
            #expect(m.isRunning)
            await m.finish()
            #expect(m.phase == expected)
        }
    }

    @Test func cancelEndsTheRun() async {
        let (maps, cleanup) = mappings()
        defer { cleanup() }
        let m = model(maps) { _ in try await Task.sleep(for: .seconds(60)); return FluxDiffOutput(text: "", hasChanges: false) }
        m.map(URL(fileURLWithPath: "/tmp/repo/apps", isDirectory: true))
        m.run()
        m.run()                                     // a second press while running does nothing
        m.cancel()
        await m.finish()
        #expect(m.phase == .cancelled)
    }
}
