import Testing
import Foundation
@testable import WheelhouseKit

/// Structural guarantees of ARCHITECTURE-MAC section 9.2. The strongest check is compile-time and lives in
/// `scripts/check-toolbox-readonly.sh` (the compiler rejects every mutation through the toolbox types). These tests add what
/// a compiler cannot say: which files may name a client, and that the AI and MCP app code never touches `LiveKubeClient`.
@Suite("Toolbox structure")
struct ToolboxStructureTests {
    private static var packageRoot: URL {
        // <repo>/Packages/WheelhouseKit/Tests/WheelhouseKitTests/<this file>
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }
    private static var repoRoot: URL { packageRoot.deletingLastPathComponent().deletingLastPathComponent() }

    private static func swiftFiles(in directory: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Code lines only: comments are skipped.
    private static func codeLines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    private static var toolboxFiles: [URL] { swiftFiles(in: packageRoot.appendingPathComponent("Sources/WheelhouseKit/Toolbox")) }

    @Test func theToolboxFolderIsFoundAndNotEmpty() {
        #expect(Self.toolboxFiles.count >= 8)
    }

    @Test func onlyReadOnlyKubeAccessMayNameAClientType() {
        for file in Self.toolboxFiles where file.lastPathComponent != "ReadOnlyKubeAccess.swift" {
            for line in Self.codeLines(file) {
                for banned in ["KubeClientProtocol", "LiveKubeClient", "DemoKubeClient", "SecretStrippingClient"] {
                    #expect(!line.contains(banned), "\(file.lastPathComponent) names \(banned): \(line)")
                }
            }
        }
    }

    @Test func noToolboxFileCallsAMutatingOrStreamingClientFunction() {
        let banned = ["client.create(", "client.replace(", "client.patch(", "client.delete(", "client.scale(", "client.restartRollout(", "client.evict(", "execWebSocket", "portForwardWebSocket", "proxyRequest", "proxyGET"]
        for file in Self.toolboxFiles {
            for line in Self.codeLines(file) {
                for token in banned {
                    if file.lastPathComponent == "ReadOnlyKubeAccess.swift", token == "client.create(", line.contains("client.create(.selfSubjectAccessReview") { continue }
                    #expect(!line.contains(token), "\(file.lastPathComponent) contains \(token): \(line)")
                }
            }
        }
    }

    @Test func readOnlyKubeAccessMakesExactlyOneNonReadCallAndItIsAnAccessReview() throws {
        let file = try #require(Self.toolboxFiles.first { $0.lastPathComponent == "ReadOnlyKubeAccess.swift" })
        let creates = Self.codeLines(file).filter { $0.contains("client.create(") }
        #expect(creates.count == 1)
        #expect(creates.first?.contains(".selfSubjectAccessReview") == true)
        for token in ["client.patch(", "client.replace(", "client.delete(", "execWebSocket", "portForwardWebSocket"] {
            #expect(!Self.codeLines(file).contains { $0.contains(token) }, Comment(rawValue: token))
        }
    }

    @Test func theProposalCoordinatorHasNoWayToReachACluster() throws {
        let file = try #require(Self.toolboxFiles.first { $0.lastPathComponent == "ProposalCoordinator.swift" })
        let text = Self.codeLines(file).joined(separator: "\n")
        for banned in ["KubeClient", "ReadOnlyKubeAccess", "ToolboxClusterSource", "URLSession", "@escaping"] {
            #expect(!text.contains(banned), Comment(rawValue: banned))
        }
    }

    @Test @MainActor func toolboxHoldsNoClientInAnyStoredProperty() {
        let toolbox = ClusterToolbox(source: FakeToolboxSource([]), policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        for child in Mirror(reflecting: toolbox).children { #expect(!(child.value is any KubeClientProtocol), "\(child.label ?? "?")") }
        let tools = ProposalTools(source: FakeToolboxSource([]), policy: ToolboxPolicy(caller: .firstMate(conversation: "c")), coordinator: .init())
        for child in Mirror(reflecting: tools).children { #expect(!(child.value is any KubeClientProtocol), "\(child.label ?? "?")") }
    }

    @Test func theAppCodeForFirstMateAndBeaconNeverNamesLiveKubeClient() {
        for folder in ["WheelhouseMac/FirstMate", "WheelhouseMac/Beacon"] {
            for file in Self.swiftFiles(in: Self.repoRoot.appendingPathComponent(folder)) {
                for line in Self.codeLines(file) { #expect(!line.contains("LiveKubeClient"), "\(file.lastPathComponent): \(line)") }
            }
        }
    }

    @Test func everyReadToolHasADefinitionAndAProposalToolIsNeverRead() {
        for tool in ReadTool.allCases {
            let definition = ToolCatalog.definition(tool)
            #expect(definition.name == tool.rawValue && !definition.isProposal)
        }
        for tool in ProposalTool.allCases { #expect(ToolCatalog.definition(tool).isProposal) }
        let readNames = Set(ReadTool.allCases.map(\.rawValue))
        #expect(readNames.isDisjoint(with: ProposalTool.allCases.map(\.rawValue)))
        // No read tool name looks like a verb that changes something.
        for name in readNames {
            for verb in ["create", "delete", "patch", "apply", "scale", "restart", "exec", "propose", "request"] { #expect(!name.contains(verb), Comment(rawValue: name)) }
        }
    }
}
