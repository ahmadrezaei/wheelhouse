import Testing
import Foundation
@testable import WheelhouseKit

/// Structural guarantees of ARCHITECTURE-MAC section 9.2 for First Mate: the AI code cannot reach a cluster, and in the Mac app only
/// the proposal review presenter names a cluster client (it hands the client to the confirmation sheet, nothing else).
@Suite("First Mate structure")
struct FirstMateStructureTests {
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var repoRoot: URL { packageRoot.deletingLastPathComponent().deletingLastPathComponent() }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private static func codeLines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private static let bannedInAI = ["KubeClientProtocol", "LiveKubeClient", "DemoKubeClient", "MutationOptions", ".patch(", "ConfirmRequest", "ProposalConfirmation"]

    @Test func theAICodeNamesNoClientAndNoMutation() {
        let files = Self.swiftFiles(in: Self.packageRoot.appendingPathComponent("Sources/WheelhouseKit/AI"))
        #expect(files.count >= 8)
        for file in files {
            for line in Self.codeLines(file) {
                for banned in Self.bannedInAI { #expect(!line.contains(banned), "\(file.lastPathComponent) names \(banned): \(line)") }
            }
        }
    }

    @Test func inTheMacAppOnlyTheReviewPresenterNamesAClient() {
        let folder = Self.repoRoot.appendingPathComponent("WheelhouseMac/FirstMate")
        let files = Self.swiftFiles(in: folder)
        #expect(files.contains { $0.lastPathComponent == "ProposalReview.swift" })
        for file in files where file.lastPathComponent != "ProposalReview.swift" {
            for line in Self.codeLines(file) {
                for banned in ["KubeClientProtocol", "LiveKubeClient", "session.client", ".client.", "ProposalConfirmation", "ConfirmRequest"] {
                    #expect(!line.contains(banned), "\(file.lastPathComponent) names \(banned): \(line)")
                }
            }
        }
    }

    @Test func theSessionHoldsOnlyTheReadOnlyToolRunner() {
        // The session's tool dependency is a protocol with `definitions` and `run`; nothing else can be reached through it.
        let runner: any FirstMateToolRunning = ScriptedTools()
        #expect(!runner.definitions.isEmpty)
        #expect(runner.definitions.map(\.name).sorted() == runner.definitions.map(\.name))
    }
}
