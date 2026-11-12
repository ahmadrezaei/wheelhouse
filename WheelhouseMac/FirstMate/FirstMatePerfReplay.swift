import Foundation
import WheelhouseDesktop
import WheelhouseKit

/// The replayed 50-turn conversation of the `soak-5` gate (ARCHITECTURE-MAC section 15.1, M11b): `-WHPerfFirstMate YES` with a soak
/// scenario, honoured only while the safety gate is active.
///
/// The real session, view and tool loop run over a scripted transport, so the run exercises streaming into the view, the 4 updates a
/// second gate, tool calls through the real read-only toolbox (`list_clusters`), the lazily built transcript and the encrypted store.
/// It never reaches the network: the key is an in-memory stand-in, the conversation folder is temporary, and the usage in the script
/// stays far below the cost caps. One conversation of 50 turns is replayed over each 5-minute soak cycle and deleted at its end, so
/// what the soak measures is the churn of building and tearing down a long conversation, not one conversation growing for an hour.
@MainActor
enum FirstMatePerfReplay {
    static let turnsPerCycle = 50

    static func isRequested(arguments: [String] = ProcessInfo.processInfo.arguments, gateActive: Bool = DevSafety.isActive) -> Bool {
        guard gateActive, let index = arguments.firstIndex(of: "-WHPerfFirstMate") else { return false }
        return arguments.indices.contains(index + 1) && arguments[index + 1] == "YES"
    }

    /// The client the replay hub uses.
    static func client(pace: Duration = .milliseconds(12)) -> AnthropicClient {
        AnthropicClient(transport: PerfReplayTransport(pace: pace), keyProvider: { "replay-key" }, sleeper: { _ in })
    }

    private static var driver: Task<Void, Never>?

    /// Starts the driver once the first window exists. Does nothing unless the replay was requested.
    static func startIfRequested(env: MacAppEnvironment, cycleSeconds: TimeInterval) {
        guard isRequested(), driver == nil else { return }
        driver = Task { @MainActor in
            for _ in 0..<120 where env.workspace.activeModel == nil { try? await Task.sleep(for: .milliseconds(500)) }
            guard let model = env.workspace.activeModel else { return }
            model.isInspectorOpen = true
            model.mutate { $0.inspector.segment = .firstMate }
            let hub = env.firstMate
            while !Task.isCancelled {
                let session = hub.newConversation(in: "inspector")
                let start = Date()
                let gap = cycleSeconds / Double(turnsPerCycle + 2)
                for turn in 1...turnsPerCycle {
                    session.send(prompt(turn))
                    while session.isBusy, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
                    let due = start.addingTimeInterval(Double(turn) * gap)
                    let wait = due.timeIntervalSinceNow
                    if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                }
                let next = hub.newConversation(in: "inspector")
                await hub.delete(session.id)
                _ = next
            }
        }
    }

    static func prompt(_ turn: Int) -> String {
        turn.isMultiple(of: 2) ? "Turn \(turn): which workloads look unhealthy in this cluster, and why?" : "Turn \(turn): list the clusters you can see and summarise their state."
    }
}

/// Answers each request with a scripted stream, paced so the view sees many more deltas than it may show: every other user turn calls
/// `list_clusters` first, and the usage grows a little with the conversation and always reads most of the prompt from cache.
struct PerfReplayTransport: AITransport {
    var pace: Duration = .milliseconds(12)

    func open(_ request: URLRequest) async throws -> AITransportResponse {
        let body = request.httpBody.flatMap { try? JSONValue.parse($0) } ?? [:]
        let messages = body["messages"]?.arrayValue ?? []
        let userTurns = messages.filter { $0["role"]?.stringValue == "user" && !($0["content"]?.arrayValue?.contains { $0["type"]?.stringValue == "tool_result" } ?? false) }.count
        let afterTools = messages.last?["content"]?.arrayValue?.contains { $0["type"]?.stringValue == "tool_result" } ?? false
        let cacheRead = min(8_000 + userTurns * 150, 40_000)
        let lines: [String]
        if !afterTools, userTurns.isMultiple(of: 2) == false {
            lines = SSEScript.response(toolCalls: [.init(id: "toolu_\(userTurns)", name: "list_clusters", input: [:])], input: 900, cacheRead: cacheRead, output: 40)
        } else {
            let words = (0..<70).map { "word\($0 % 9) " }
            lines = SSEScript.response(thinking: "Looking at the evidence before answering.", text: ["**Summary.** "] + words + ["\n\n- first finding\n- second finding\n"],
                                       input: 900, cacheRead: cacheRead, output: 160)
        }
        return AITransportResponse(status: 200, lines: AsyncThrowingStream { continuation in
            let task = Task {
                for line in lines {
                    try? await Task.sleep(for: pace)
                    if Task.isCancelled { break }
                    continuation.yield(line)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        })
    }
}
