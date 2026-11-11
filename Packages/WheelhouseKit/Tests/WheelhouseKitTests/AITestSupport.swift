import Foundation
import Synchronization
@testable import WheelhouseKit

/// Replayed server-sent-event fixtures (`Fixtures/ai/*.sse`). Nothing in the AI tests reaches the network.
enum AIFixtures {
    static func lines(_ name: String) throws -> [String] {
        guard let url = Bundle.module.url(forResource: name, withExtension: "sse", subdirectory: "Fixtures/ai") else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }
}

/// A stand-in key built at run time (no literal that looks like a real key).
let testKey = ["test", "key", String(repeating: "x", count: 12)].joined(separator: "-")

/// Runs the tool calls a test scripts and records them.
final class ScriptedTools: FirstMateToolRunning {
    let definitions: [ToolDefinition]
    private let handler: @Sendable (String, JSONValue) -> ToolOutput
    private let calls = Mutex<[String]>([])

    init(definitions: [ToolDefinition]? = nil, handler: @escaping @Sendable (String, JSONValue) -> ToolOutput = { _, _ in ToolOutput(json: ["ok": true]) }) {
        self.definitions = definitions ?? ToolCatalog.definitions(for: .firstMate(conversation: "c"), includeProposals: true)
        self.handler = handler
    }

    var callNames: [String] { calls.withLock { $0 } }

    func run(name: String, input: JSONValue) async -> ToolOutput {
        calls.withLock { $0.append(name) }
        return handler(name, input)
    }
}

/// A client with the replay transport and no waiting between retries.
func replayClient(_ transport: ReplayTransport, key: String? = testKey) -> AnthropicClient {
    AnthropicClient(transport: transport, keyProvider: { key }, sleeper: { _ in })
}

func tempDirectory(_ name: String = "ai") -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "wh-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
func makeSession(_ transport: ReplayTransport, tools: (any FirstMateToolRunning)? = nil, coordinator: ProposalCoordinator = ProposalCoordinator(),
                 store: ConversationStore? = nil, cap: Double = 2, profile: AIModelChoice = .standard) -> FirstMateSession {
    FirstMateSession(id: "c", client: replayClient(transport), tools: tools ?? ScriptedTools(), coordinator: coordinator, store: store,
                     daily: DailySpendStore(url: nil), profile: profile, capDollars: cap)
}

/// Waits until the session is no longer busy.
@MainActor
func settle(_ session: FirstMateSession) async {
    for _ in 0..<2_000 {
        if !session.isBusy { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
