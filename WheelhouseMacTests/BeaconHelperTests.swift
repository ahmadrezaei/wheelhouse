import Testing
import AppKit
import Foundation
import Synchronization
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The real `wheelhouse-mcp` helper from the built app bundle, against a Beacon hub in this process (the test host is the signed Debug
/// app, so both code-signature checks run for real: the app checks the helper, and the helper checks the app before it sends a hello).
/// A small MCP client in this file speaks the stdio protocol to the helper, as MCP Inspector or Claude Code would. It never starts
/// `claude`, never reads a real configuration and never prompts for Touch ID.
@Suite("Beacon helper", .serialized)
struct BeaconHelperTests {
    struct Source: ToolboxClusterSource {
        func clusters() async -> [ClusterConfig] {
            [ClusterConfig(id: "dev", name: "dev", server: URL(string: "https://dev.example.com")!, environment: .development),
             ClusterConfig(id: "prod", name: "prod", server: URL(string: "https://prod.example.com")!, environment: .production)]
        }
        func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? { nil }
    }
    struct AutoApprove: BeaconApproving {
        func approve(_ request: BeaconApprovalRequest) async -> BeaconApprovalDecision { .allow(readClusters: ["dev", "prod"], remember: false) }
    }
    struct NoAuth: BeaconAuthenticating { func authenticate(reason: String) async throws {} }

    /// An MCP stdio client over a child process.
    final class StdioClient: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        private var buffer = Data()

        init(helper: URL, socket: String, secret: String?) throws {
            process.executableURL = helper
            var env = ProcessInfo.processInfo.environment
            env["WH_BEACON_SOCKET_OVERRIDE"] = socket
            if let secret { env["WHEELHOUSE_BEACON_SECRET"] = secret } else { env["WHEELHOUSE_BEACON_SECRET"] = nil }
            process.environment = env
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func send(_ value: JSONValue) {
            var data = (try? value.data()) ?? Data()
            data.append(0x0A)
            try? input.fileHandleForWriting.write(contentsOf: data)
        }

        func readLine(timeout: TimeInterval = 8) -> JSONValue? {
            let end = Date().addingTimeInterval(timeout)
            let fd = output.fileHandleForReading.fileDescriptor
            while Date() < end {
                if let i = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[..<i]
                    buffer.removeSubrange(...i)
                    return try? JSONValue.parse(Data(line))
                }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 100) > 0 {
                    var chunk = [UInt8](repeating: 0, count: 65_536)
                    let n = read(fd, &chunk, chunk.count)
                    if n <= 0 { return nil }
                    buffer.append(contentsOf: chunk.prefix(n))
                }
            }
            return nil
        }

        func request(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> JSONValue? {
            send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
            while let message = readLine() { if message["id"]?.intValue == id { return message } }
            return nil
        }

        func stop() { try? input.fileHandleForWriting.close(); if process.isRunning { process.terminate() } }
    }

    private var helper: URL { Bundle.main.bundleURL.appending(path: "Contents/Helpers/wheelhouse-mcp") }

    private func rig() -> (BeaconHub, ShortTemp) {
        let temp = ShortTemp()
        let store = BeaconClientStore(fileURL: temp.url.appending(path: "clients.json"), secrets: InMemoryBeaconSecrets())
        let hub = BeaconHub(store: store, source: Source(), socketURL: temp.url.appending(path: "b/s"),
                            verifier: SecurityPeerVerifier(requirement: BeaconRequirements.helper(identifier: "com.ahmadrezaei.wheelhouse.mac.mcp.debug")),
                            approver: AutoApprove(), authenticator: NoAuth())
        return (hub, temp)
    }

    final class ShortTemp: @unchecked Sendable {
        let url = URL(fileURLWithPath: "/tmp/whbh-\(UUID().uuidString.prefix(8))", isDirectory: true)
        init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        func cleanup() { try? FileManager.default.removeItem(at: url) }
    }

    @Test func theSignedHelperConnectsInitializesAndListsTools() async throws {
        try #require(FileManager.default.fileExists(atPath: helper.path), "the helper is embedded in the app")
        let (hub, temp) = rig()
        defer { hub.turnOff(); temp.cleanup() }
        try await hub.turnOn()
        let client = try StdioClient(helper: helper, socket: hub.socketPath, secret: nil)
        defer { client.stop() }
        let initialized = client.request(1, "initialize", ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "test-client", "version": "1"]])
        #expect(initialized?.value(at: "result.serverInfo.name")?.stringValue == "wheelhouse")
        client.send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        // Approval is automatic here; wait until the tools appear.
        var names: [String] = []
        for _ in 0..<40 where names.isEmpty {
            names = client.request(2, "tools/list")?.value(at: "result.tools")?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
            if names.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(names.contains("list_clusters"))
        // Production change tools never appear.
        #expect(!names.contains { $0.hasPrefix("request_") })
        let call = client.request(3, "tools/call", ["name": "list_clusters", "arguments": [:]])
        #expect(call?.value(at: "result.structuredContent.untrusted_cluster_data")?.boolValue == true)
        #expect(call?.value(at: "result.structuredContent.data").map { $0.jsonString().contains("dev") } == true)
    }

    @Test func aHelperWithTheWrongSignatureIsRejected() async throws {
        // The hub requires a different identifier than the helper's, so its signature check fails and the connection is dropped.
        let temp = ShortTemp()
        defer { temp.cleanup() }
        let store = BeaconClientStore(fileURL: temp.url.appending(path: "clients.json"), secrets: InMemoryBeaconSecrets())
        let log = Recorder()
        let hub = BeaconHub(store: store, source: Source(), socketURL: temp.url.appending(path: "b/s"),
                            verifier: SecurityPeerVerifier(requirement: BeaconRequirements.helper(identifier: "com.example.not-the-helper.debug")),
                            approver: AutoApprove(), authenticator: NoAuth(), activity: log)
        try await hub.turnOn()
        defer { hub.turnOff() }
        let client = try StdioClient(helper: helper, socket: hub.socketPath, secret: nil)
        defer { client.stop() }
        let reply = client.request(1, "initialize", ["protocolVersion": "2025-11-25"])
        #expect(reply?.value(at: "error.message")?.stringValue != nil)   // the helper reports it was refused; no session exists
        #expect(hub.sessionCount == 0)
        #expect(log.list.withLock { $0 }.contains { $0.contains("rejected") })
    }

    final class Recorder: ActivityLogging, @unchecked Sendable {
        let list = Mutex<[String]>([])
        func record(_ entry: ActivityEntry) { list.withLock { $0.append("\(entry.verb) \(entry.result)") } }
    }

    @Test func theHelperAnswersWithAnErrorWhenNothingListens() throws {
        let temp = ShortTemp()
        defer { temp.cleanup() }
        let client = try StdioClient(helper: helper, socket: temp.url.appending(path: "none").path, secret: nil)
        defer { client.stop() }
        // 10 s of retries (the helper starts no app while the socket override is in use).
        client.send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:]])
        let reply = client.readLine(timeout: 20)
        #expect(reply?.value(at: "error.message")?.stringValue?.contains("not running") == true)
    }
}
