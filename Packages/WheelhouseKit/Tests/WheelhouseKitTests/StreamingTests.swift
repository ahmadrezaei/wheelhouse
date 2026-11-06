import Testing
import Foundation
@testable import WheelhouseKit

@Suite("Channel protocol")
struct ChannelProtocolTests {
    @Test func frameRoundTrip() {
        let f = ChannelFrame(channel: 1, payload: Data("hello".utf8))
        let wire = f.encoded()
        #expect(wire.first == 1)
        #expect(wire.count == 6)
        #expect(ChannelFrame.decode(wire) == f)
        #expect(ChannelFrame.decode(Data()) == nil)
        #expect(ChannelFrame.decode(Data([3]))?.payload.isEmpty == true)
    }

    @Test func stdinAndResizeFrames() {
        #expect(ChannelFrame.stdin(Data("ls\r".utf8)).encoded() == Data([0, 0x6C, 0x73, 0x0D]))
        let r = ChannelFrame.resize(cols: 120, rows: 40)
        #expect(r.channel == 4)
        #expect(String(decoding: r.payload, as: UTF8.self) == "{\"Width\":120,\"Height\":40}")
        #expect(ChannelFrame.closeStdin.encoded() == Data([255, 0]))
    }

    @Test func statusSuccess() {
        let s = ExecStatus.parse(Data(#"{"metadata":{},"status":"Success"}"#.utf8))
        #expect(s?.outcome == .success)
        #expect(s?.exitCode == 0)
    }

    @Test func statusExitCode() {
        let json = #"{"metadata":{},"status":"Failure","message":"command terminated with non-zero exit code: Error executing in Docker Container: 137","reason":"NonZeroExitCode","details":{"causes":[{"reason":"ExitCode","message":"137"}]}}"#
        let s = ExecStatus.parse(Data(json.utf8))
        #expect(s?.outcome == .exited(code: 137))
        #expect(s?.message?.contains("non-zero") == true)
    }

    @Test func statusOtherFailure() {
        let s = ExecStatus.parse(Data(#"{"status":"Failure","message":"oci runtime error","reason":"InternalError"}"#.utf8))
        #expect(s?.outcome == .failure(reason: "InternalError"))
        #expect(s?.exitCode == nil)
        #expect(ExecStatus.parse(Data("nope".utf8)) == nil)
    }

    @Test func shellCommands() {
        #expect(ShellChoice.sh.command == ["/bin/sh"])
        #expect(ShellChoice.auto.command.first == "/bin/sh")
        #expect(ShellChoice.custom("/bin/zsh -l").command == ["/bin/zsh", "-l"])
        #expect(ShellChoice.custom("sh -c 'echo hi there'").command == ["sh", "-c", "echo hi there"])
    }
}

@Suite("Port-forward framing")
struct PortForwardFramingTests {
    @Test func stripsPortPrefixOncePerChannel() {
        var d = PortForwardDemux(port: 80)
        let prefix = PortForwardDemux.portPrefix(80)
        #expect(prefix == Data([80, 0]))
        // Server: [0, 80, 0] (data channel prefix), [1, 80, 0] (error channel prefix)
        #expect(d.process(Data([0]) + prefix) == .none)
        #expect(d.process(Data([1]) + prefix) == .none)
        #expect(d.process(Data([0]) + Data("HTTP/1.1 200".utf8)) == .data(Data("HTTP/1.1 200".utf8)))
        // Second frame must NOT be stripped again, even if it starts with bytes that look like a port.
        #expect(d.process(Data([0, 80, 0, 65])) == .data(Data([80, 0, 65])))
        #expect(d.process(Data([1]) + Data("connection refused".utf8)) == .error("connection refused"))
    }

    @Test func prefixAndDataInSameFrame() {
        var d = PortForwardDemux(port: 8080)
        let frame = Data([0]) + PortForwardDemux.portPrefix(8080) + Data("abc".utf8)
        #expect(d.process(frame) == .data(Data("abc".utf8)))
    }

    @Test func littleEndianPortEncoding() {
        #expect(PortForwardDemux.portPrefix(8080) == Data([0x90, 0x1F]))
        #expect(PortForwardDemux.portPrefix(443) == Data([0xBB, 0x01]))
    }

    @Test func secondPortUsesChannels2And3() {
        var d = PortForwardDemux(port: 9000, index: 1)
        #expect(d.dataChannel == 2 && d.errorChannel == 3)
        #expect(d.outgoing(Data([1, 2])) == Data([2, 1, 2]))
        #expect(d.process(Data([0, 1, 2, 3])) == .none) // belongs to port index 0
        #expect(d.process(Data([2, 40, 35, 9])) == .data(Data([9])))
    }

    @Test func outgoingData() {
        let d = PortForwardDemux(port: 80)
        #expect(d.outgoing(Data("GET /".utf8)) == Data([0]) + Data("GET /".utf8))
    }

    @Test func freePortSuggestion() {
        let p = LocalPort.suggest(preferred: 80)
        #expect(p >= 1024)
        #expect(LocalPort.isFree(p))
        let other = LocalPort.suggest(preferred: p, excluding: [p])
        #expect(other != p)
    }
}

@Suite("Log parsing")
struct LogParsingTests {
    @Test func splitsTimestamp() {
        let (ts, msg) = LogParser.splitTimestamp("2026-11-05T10:11:12.123456789Z level=info msg=\"ok\"")
        #expect(ts == "2026-11-05T10:11:12.123456789Z")
        #expect(msg == "level=info msg=\"ok\"")
        #expect(LogParser.splitTimestamp("plain line without time").timestamp == nil)
    }

    @Test func timestampParsing() throws {
        let a = try #require(LogTimestamp.parse("2026-11-05T10:11:12.5Z"))
        let b = try #require(LogTimestamp.parse("2026-11-05T10:11:13Z"))
        #expect(abs((b - a) - 0.5) < 1e-6)
        let c = try #require(LogTimestamp.parse("1970-01-02T00:00:00Z"))
        #expect(c == 86400)
        let z = try #require(LogTimestamp.parse("2026-11-05T12:00:00+02:00"))
        let u = try #require(LogTimestamp.parse("2026-11-05T10:00:00Z"))
        #expect(z == u)
    }

    @Test func levelDetection() {
        #expect(LogLevelDetector.detect(#"{"level":"error","msg":"boom"}"#) == .error)
        #expect(LogLevelDetector.detect(#"{"severity":"WARNING","message":"slow"}"#) == .warn)
        #expect(LogLevelDetector.detect(#"{"level":30,"msg":"pino"}"#) == .info)
        #expect(LogLevelDetector.detect(#"{"msg":"no level"}"#) == .none)
        #expect(LogLevelDetector.detect("level=warn msg=\"slow query\"") == .warn)
        #expect(LogLevelDetector.detect("ts=1 level=debug caller=x") == .debug)
        #expect(LogLevelDetector.detect("E1105 10:11:12.000 controller.go:12] failed") == .error)
        #expect(LogLevelDetector.detect("I1105 10:11:12.000 controller.go:12] ok") == .info)
        #expect(LogLevelDetector.detect("2026-11-05 10:11:12 ERROR [app] failed") == .error)
        #expect(LogLevelDetector.detect("[WARN] disk almost full") == .warn)
        #expect(LogLevelDetector.detect("INFO  starting server") == .info)
        #expect(LogLevelDetector.detect("error: DATABASE_URL not set") == .error)
        #expect(LogLevelDetector.detect("GET /index.html 200 3ms") == .none)
        #expect(LogLevelDetector.detect("") == .none)
    }

    @Test func ringBufferDropsOldest() {
        var buf = LogRingBuffer(capacity: 5)
        let lines = (0..<8).map { LogLine(id: $0, message: "l\($0)") }
        #expect(buf.append(contentsOf: Array(lines[0..<3])) == 0)
        #expect(buf.append(contentsOf: Array(lines[3..<8])) == 3)
        #expect(buf.count == 5)
        #expect(buf[0].id == 3)
        #expect(buf[4].id == 7)
        #expect(buf.droppedCount == 3)
        // Long run stays bounded and ordered.
        for i in 8..<200 { buf.append(contentsOf: [LogLine(id: i, message: "x")]) }
        #expect(buf.count == 5)
        #expect(buf.lines.map(\.id) == [195, 196, 197, 198, 199])
    }

    @MainActor @Test func streamCollectsLinesFromClient() async throws {
        let stream = LogStream(capacity: 100)
        stream.start(client: StubLogClient(lines: (0..<250).map { "2026-11-05T10:00:\(String(format: "%02d", $0 % 60)).000Z level=info n=\($0)" }),
                     namespace: "ns", pod: "p", containers: [nil], options: LogOptions(follow: false))
        for _ in 0..<50 where stream.state != .finished { try await Task.sleep(for: .milliseconds(50)) }
        #expect(stream.state == .finished)
        #expect(stream.count == 100)
        #expect(stream.totalReceived == 250)
        #expect(stream.buffer[99].message.hasSuffix("n=249"))
        #expect(stream.buffer[0].level == .info)
        #expect(stream.buffer[0].timestamp != nil)
    }
}

@Suite("Terminal emulator")
struct TerminalEmulatorTests {
    @Test func printsAndWraps() {
        let t = TerminalEmulator(cols: 5, rows: 3)
        t.feed("hello world")
        #expect(t.text(ofLine: 0 + t.scrollback.count) == "hello")
        #expect(t.screenText().contains(" worl"))
    }

    @Test func carriageReturnLineFeedBackspace() {
        let t = TerminalEmulator(cols: 20, rows: 4)
        t.feed("abc\r\ndef\u{8}X")
        #expect(t.screenText().split(separator: "\n", omittingEmptySubsequences: false)[0] == "abc")
        #expect(t.screenText().split(separator: "\n", omittingEmptySubsequences: false)[1] == "deX")
        t.feed("\rZ")
        #expect(t.text(ofLine: t.scrollback.count + 1) == "ZeX")
    }

    @Test func cursorMovementAndErase() {
        let t = TerminalEmulator(cols: 10, rows: 5)
        t.feed("\u{1B}[2;3Hx")
        #expect(t.cursorY == 1 && t.cursorX == 3)
        #expect(t.text(ofLine: 1) == "  x")
        t.feed("\u{1B}[2Dy") // back 2 → col 1, write y
        #expect(t.text(ofLine: 1) == " yx")
        t.feed("\u{1B}[K")
        #expect(t.text(ofLine: 1) == " y")
        t.feed("\u{1B}[H\u{1B}[2J")
        #expect(t.screenText().allSatisfy { $0 == "\n" })
        #expect(t.cursorX == 0 && t.cursorY == 0)
    }

    @Test func utf8SplitAcrossChunks() {
        let t = TerminalEmulator(cols: 10, rows: 2)
        let bytes = Array("é€".utf8)
        t.feed(Array(bytes[0..<1]))
        t.feed(Array(bytes[1..<3]))
        t.feed(Array(bytes[3...]))
        #expect(t.text(ofLine: 0) == "é€")
    }

    @Test func sgrColours() {
        let t = TerminalEmulator(cols: 20, rows: 2)
        t.feed("\u{1B}[1;31mR\u{1B}[0m\u{1B}[38;5;82mG\u{1B}[48;2;1;2;3mB\u{1B}[0mN")
        let row = t.grid[0]
        #expect(row[0].style.fg == .indexed(1) && row[0].style.attrs.contains(.bold))
        #expect(row[1].style.fg == .indexed(82))
        #expect(row[2].style.bg == .rgb(1, 2, 3))
        #expect(row[3].style == TermStyle())
        t.feed("\u{1B}[93mY")
        #expect(t.grid[0][4].style.fg == .indexed(11))
    }

    @Test func scrollingFillsScrollback() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        t.feed("1\r\n2\r\n3\r\n4\r\n5")
        #expect(t.scrollback.count == 2)
        #expect(t.text(ofLine: 0) == "1")
        #expect(t.screenText() == "3\n4\n5")
        #expect(t.allText() == "1\n2\n3\n4\n5")
    }

    @Test func scrollRegion() {
        let t = TerminalEmulator(cols: 6, rows: 5)
        t.feed("top\r\n")
        t.feed("\u{1B}[2;4r") // region rows 2-4, cursor homes
        t.feed("\u{1B}[2;1HA\r\nB\r\nC\r\nD") // D forces scroll within region
        #expect(t.text(ofLine: 0) == "top")
        #expect(t.text(ofLine: 1) == "B")
        #expect(t.text(ofLine: 2) == "C")
        #expect(t.text(ofLine: 3) == "D")
        #expect(t.scrollback.isEmpty)
    }

    @Test func alternateScreenRestoresMain() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        t.feed("main")
        t.feed("\u{1B}[?1049h")
        #expect(t.usingAlternateScreen)
        #expect(t.screenText().replacingOccurrences(of: "\n", with: "").isEmpty)
        t.feed("vi!")
        t.feed("\u{1B}[?1049l")
        #expect(!t.usingAlternateScreen)
        #expect(t.text(ofLine: 0) == "main")
        #expect(t.cursorX == 4)
    }

    @Test func modesAndResponses() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        var replies: [String] = []
        t.onResponse = { replies.append(String(decoding: $0, as: UTF8.self)) }
        t.feed("\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l")
        #expect(t.applicationCursorKeys && t.bracketedPaste && !t.cursorVisible)
        t.feed("ab\u{1B}[6n")
        #expect(replies == ["\u{1B}[1;3R"])
        t.feed("\u{1B}]0;my title\u{07}")
        #expect(t.title == "my title")
    }

    @Test func insertDeleteChars() {
        let t = TerminalEmulator(cols: 10, rows: 2)
        t.feed("abcdef\r\u{1B}[2C\u{1B}[2P")
        #expect(t.text(ofLine: 0) == "abef")
        t.feed("\u{1B}[@Z")
        #expect(t.text(ofLine: 0) == "abZef")
    }

    @Test func resizeKeepsContent() {
        let t = TerminalEmulator(cols: 10, rows: 3)
        t.feed("one\r\ntwo\r\nthree")
        t.resize(cols: 6, rows: 2)
        #expect(t.rows == 2 && t.cols == 6)
        #expect(t.screenText() == "two\nthree")
        t.resize(cols: 12, rows: 4)
        #expect(t.grid.count == 4 && t.grid[0].count == 12)
    }
}

@Suite("Terminal keys")
struct TerminalKeyTests {
    @Test func arrows() {
        #expect(TerminalKeyEncoder.bytes(for: .up) == Array("\u{1B}[A".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .left, applicationCursor: true) == Array("\u{1B}OD".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .right, modifiers: [.control]) == Array("\u{1B}[1;5C".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .pageDown) == Array("\u{1B}[6~".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .function(1)) == Array("\u{1B}OP".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .function(5)) == Array("\u{1B}[15~".utf8))
        #expect(TerminalKeyEncoder.bytes(for: .escape) == [0x1B])
        #expect(TerminalKeyEncoder.bytes(for: .tab) == [0x09])
    }

    @Test func controlCharacters() {
        #expect(TerminalKeyEncoder.control("c") == 3)
        #expect(TerminalKeyEncoder.control("D") == 4)
        #expect(TerminalKeyEncoder.control("[") == 0x1B)
        #expect(TerminalKeyEncoder.control("5") == nil)
        #expect(TerminalKeyEncoder.bytes(forText: "c", modifiers: .control) == [3])
        #expect(TerminalKeyEncoder.bytes(forText: "x", modifiers: .alt) == [0x1B, 0x78])
    }

    @Test func bracketedPaste() {
        #expect(String(decoding: TerminalKeyEncoder.paste("a\nb", bracketed: false), as: UTF8.self) == "a\rb")
        #expect(String(decoding: TerminalKeyEncoder.paste("x", bracketed: true), as: UTF8.self) == "\u{1B}[200~x\u{1B}[201~")
    }
}

/// Minimal client that only implements `logs`.
struct StubLogClient: KubeClientProtocol {
    var lines: [String]
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> {
        let lines = lines
        return AsyncThrowingStream { c in
            for l in lines { c.yield(l) }
            c.finish()
        }
    }
    func version() async throws -> KubeVersion { throw KubeError.unsupported("stub") }
    func discovery() async throws -> DiscoveryInfo { throw KubeError.unsupported("stub") }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { throw KubeError.unsupported("stub") }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("stub") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("stub") }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
}

// MARK: - Live cluster tests
//
// Run against the isolated test cluster only:
//   TEST_RUNNER_WH_TEST_TOKEN=$(cat .testcluster/admin.token) TEST_RUNNER_WH_TEST_SERVER=https://127.0.0.1:60561 xcodebuild … test
// Without the environment variable these tests are skipped.

private enum LiveEnv {
    static var token: String? { ProcessInfo.processInfo.environment["WH_TEST_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }
    static var server: URL { URL(string: ProcessInfo.processInfo.environment["WH_TEST_SERVER"] ?? "https://127.0.0.1:60561")! }
    static func client() -> LiveKubeClient {
        let config = ClusterConfig(name: "wheelhouse-test", server: server, authKind: .token, environment: .development, skipTLSVerify: true)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: token))
    }
    static func pod(_ client: LiveKubeClient, app: String) async throws -> String {
        let pods = try await client.list(Pod.self, namespace: "shop", options: ListOptions(labelSelector: "app=\(app)"))
        let running = pods.items.first { $0.status?.phase == "Running" } ?? pods.items.first
        return try #require(running).metadata.name
    }
}

@Suite("Live cluster streaming", .enabled(if: LiveEnv.token != nil), .serialized)
struct LiveStreamingTests {
    @Test func execEchoNonTTY() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let session = ExecSession(client: client, namespace: "shop", pod: pod,
                                  options: ExecOptions(command: ["/bin/sh", "-c", "echo hi"], tty: false, stdin: false))
        try await session.start()
        var output = Data(); var status: ExecStatus?
        for await event in session.events {
            switch event {
            case .output(let d): output.append(d)
            case .exited(let s): status = s
            case .closed(let err): #expect(err == nil || status != nil)
            case .opened: break
            }
            if status != nil { break }
        }
        await session.close()
        #expect(String(decoding: output, as: UTF8.self) == "hi\n")
        #expect(status?.outcome == .success)
        print("EXEC non-tty ok, protocol:", await session.negotiatedProtocol ?? "nil")
    }

    @MainActor @Test func execInteractiveTTYAndExitCode() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let session = ExecSession(client: client, namespace: "shop", pod: pod, options: ExecOptions(command: ["/bin/sh"], tty: true, stdin: true))
        try await session.start(cols: 100, rows: 30)
        var output = Data(); var status: ExecStatus?
        let term = TerminalEmulator(cols: 100, rows: 30)
        let reader = Task { @MainActor () -> Void in
            for await event in session.events {
                switch event {
                case .output(let d): output.append(d); term.feed(d)
                case .exited(let s): status = s
                default: break
                }
            }
        }
        try await Task.sleep(for: .milliseconds(800))
        session.resize(cols: 120, rows: 40)
        session.send(Data("echo marker-$((20+22)); stty size\r".utf8))
        try await Task.sleep(for: .milliseconds(800))
        session.send(Data("exit 7\r".utf8))
        await reader.value
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("marker-42"))
        #expect(term.allText().contains("marker-42"))
        #expect(term.allText().contains("40 120"))
        #expect(status?.outcome == .exited(code: 7))
        print("EXEC tty screen:\n" + term.screenText())
    }

    /// Types a long line one byte at a time without pausing; the shell must receive it intact and in order.
    @Test func execRapidKeystrokesStayOrdered() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let session = ExecSession(client: client, namespace: "shop", pod: pod, options: ExecOptions(command: ["/bin/sh"], tty: true, stdin: true))
        try await session.start(cols: 120, rows: 30)
        let reader = Task { () -> String in
            var out = Data()
            for await event in session.events { if case .output(let d) = event { out.append(d) } }
            return String(decoding: out, as: UTF8.self)
        }
        try await Task.sleep(for: .milliseconds(800))
        let payload = "abcdefghijklmnopqrstuvwxyz0123456789"
        for b in Array("echo RESULT:\(payload)\r".utf8) { session.send(Data([b])) }
        try await Task.sleep(for: .milliseconds(1200))
        session.send(Data("exit\r".utf8))
        let text = await reader.value
        await session.close()
        #expect(text.contains("RESULT:\(payload)\r\n"))
    }

    @Test func execFailureForBadContainer() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let session = ExecSession(client: client, namespace: "shop", pod: pod,
                                  options: ExecOptions(container: "nope", command: ["/bin/sh"], tty: true, stdin: true))
        try await session.start()
        var closedError: KubeError?
        for await event in session.events { if case .closed(let e) = event { closedError = e } }
        #expect(closedError != nil)
        print("EXEC bad container ->", closedError?.summary ?? "nil")
    }

    @MainActor @Test func logsOfCrashingAPI() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "api")
        let stream = LogStream(capacity: 1000)
        stream.start(client: client, namespace: "shop", pod: pod, containers: [nil], options: LogOptions(previous: true, tailLines: 100))
        for _ in 0..<100 {
            if stream.state != .connecting && stream.state != .streaming { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let messages = stream.buffer.lines.map(\.message)
        print("LOGS api previous:", messages, stream.state)
        #expect(messages.contains { $0.contains("starting api") })
        #expect(stream.buffer.lines.contains { $0.level == .error || $0.message.contains("error") })
        #expect(stream.buffer.isEmpty == false && stream.buffer[0].timestamp != nil)
    }

    @Test func portForwardWebService() async throws {
        let client = LiveEnv.client()
        let manager = PortForwardManager()
        let info = try await manager.start(clusterID: "test", clusterName: "wheelhouse-test", client: client,
                                           target: PortForwardTarget(kind: .service, namespace: "shop", name: "web", remotePort: 80),
                                           localPort: LocalPort.suggest(preferred: 18080))
        #expect(info.state == .active)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        let http = URLSession(configuration: cfg)
        for round in 0..<3 {
            let (data, response) = try await http.data(from: URL(string: "http://127.0.0.1:\(info.localPort)/")!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self).contains("nginx"))
            print("PF round", round, "bytes", data.count)
        }
        // Parallel requests share the listener.
        try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<5 { group.addTask { try await http.data(from: URL(string: "http://127.0.0.1:\(info.localPort)/")!).0.count } }
            for try await n in group { #expect(n > 100) }
        }
        let snap = try #require(await manager.info(id: info.id))
        #expect(snap.bytesDown > 0 && snap.bytesUp > 0)
        #expect(snap.totalConnections >= 1) // URLSession keeps connections alive
        #expect(snap.resolvedPod?.hasPrefix("web-") == true)
        print("PF counters down", snap.bytesDown, "up", snap.bytesUp, "conns", snap.totalConnections, "pod", snap.resolvedPod ?? "")

        // Pause (background) releases the port; resume re-binds the same one.
        await manager.pauseAll()
        #expect(await manager.info(id: info.id)?.state == .suspended)
        try await Task.sleep(for: .milliseconds(300))
        await manager.resumeAll()
        #expect(await manager.info(id: info.id)?.state == .active)
        let (again, _) = try await http.data(from: URL(string: "http://127.0.0.1:\(info.localPort)/")!)
        #expect(String(decoding: again, as: UTF8.self).contains("nginx"))

        await manager.stop(info.id)
        #expect(await manager.info(id: info.id)?.state == .stopped)
        try await Task.sleep(for: .milliseconds(200))
        #expect(LocalPort.isFree(info.localPort))
    }

    @Test func portForwardToPodDirect() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let manager = PortForwardManager()
        let info = try await manager.start(clusterID: "test", clusterName: "t", client: client,
                                           target: PortForwardTarget(kind: .pod, namespace: "shop", name: pod, remotePort: 80), localPort: 0)
        #expect(info.localPort != 0)
        let (data, _) = try await URLSession(configuration: { let c = URLSessionConfiguration.ephemeral; c.connectionProxyDictionary = [:]; return c }())
            .data(from: URL(string: "http://127.0.0.1:\(info.localPort)/")!)
        #expect(String(decoding: data, as: UTF8.self).contains("nginx"))
        await manager.stopAll()
    }

    @Test func portForwardToClosedPortReportsError() async throws {
        let client = LiveEnv.client()
        let pod = try await LiveEnv.pod(client, app: "web")
        let manager = PortForwardManager()
        let info = try await manager.start(clusterID: "test", clusterName: "t", client: client,
                                           target: PortForwardTarget(kind: .pod, namespace: "shop", name: pod, remotePort: 9999), localPort: 0)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.connectionProxyDictionary = [:]
        cfg.timeoutIntervalForRequest = 8
        _ = try? await URLSession(configuration: cfg).data(from: URL(string: "http://127.0.0.1:\(info.localPort)/")!)
        try await Task.sleep(for: .milliseconds(600))
        let snap = try #require(await manager.info(id: info.id))
        print("PF closed port lastError:", snap.lastError ?? "nil")
        #expect(snap.lastError != nil)
        await manager.stopAll()
    }
}
