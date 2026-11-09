import Foundation
import Testing
@testable import WheelhouseKit

/// The exit criterion of M7: validating a 2,000-line multi-document file takes under 100 ms after the debounce.
@Suite("Manifest editor performance", .serialized)
struct ManifestPerformanceTests {
    static func bigFile() -> String {
        var docs: [String] = []
        var i = 0
        while docs.joined(separator: "\n---\n").split(separator: "\n", omittingEmptySubsequences: false).count < 2_000 {
            docs.append(validDeployment.replacingOccurrences(of: "name: web", with: "name: web-\(i)").replacingOccurrences(of: "app: web", with: "app: web-\(i)"))
            docs.append("apiVersion: v1\nkind: Service\nmetadata:\n  name: web-\(i)\nspec:\n  selector:\n    app: web-\(i)\n  ports:\n    - port: 80\n      targetPort: 80\n")
            docs.append("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: cfg-\(i)\ndata:\n  a: \"1\"\n  b: two\n")
            i += 1
        }
        return docs.joined(separator: "\n---\n")
    }

    @Test func twoThousandLinesValidateUnderTheBudget() async throws {
        let text = Self.bigFile()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect(lines >= 2_000)
        let analyzer = ManifestAnalyzer(schemas: bundledStore())
        let warm = await analyzer.analyze(text)        // loads and decodes the schemas once, as the first open does
        #expect(warm.diagnostics.isEmpty, "\(warm.diagnostics.prefix(3).map(\.message))")
        #expect(warm.outline.count >= 9)
        var best = Double.infinity
        for _ in 0..<7 {
            let start = ContinuousClock.now
            let a = await analyzer.analyze(text)
            let elapsed = ContinuousClock.now - start
            let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
            best = min(best, ms)
            #expect(a.outline.count == warm.outline.count)
        }
        print("MANIFEST perf: \(lines) lines, \(warm.outline.count) documents, best \(String(format: "%.1f", best)) ms")
        // The budget is for the shipped (optimised) build. An unoptimised test build is several times slower and runs beside other
        // builds, so it gets a wider bound; `swift test -c release` checks the real figure.
        #if DEBUG
        #expect(best < 250, "validation took \(best) ms")
        #else
        #expect(best < 100, "validation took \(best) ms")
        #endif
    }

    @Test func decodingTheSchemaIsMeasuredSeparately() async throws {
        let start = ContinuousClock.now
        let store = bundledStore()
        _ = await store.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment"))
        let d = ContinuousClock.now - start
        print("MANIFEST perf: first bundled schema load \(d)")
        #expect(await store.memoryCost > 0)
        #expect(await store.memoryCost <= 32 * 1024 * 1024)
    }

    /// `analyze` is `@concurrent`: awaited from the main actor it runs on the global executor and the main actor keeps ticking.
    @MainActor @Test func analysisRunsOffTheMainActor() async {
        let text = Self.bigFile()
        let analyzer = ManifestAnalyzer(schemas: bundledStore())
        _ = await analyzer.analyze(text)
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(1)) }
        }
        for _ in 0..<5 { _ = await analyzer.analyze(text) }
        ticker.cancel()
        #expect(ticks >= 5, "the main actor was blocked (\(ticks) ticks)")
    }
}
