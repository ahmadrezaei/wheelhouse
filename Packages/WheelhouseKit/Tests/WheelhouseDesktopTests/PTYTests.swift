#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop

/// Compiles `Helpers/wh-pty-exec/main.c` once per test run (the app target builds it into Contents/Helpers).
enum PTYHelper {
    private static let built = Mutex<URL?>(nil)

    static func url(file: StaticString = #filePath) throws -> URL {
        if let existing = built.withLock({ $0 }) { return existing }
        // .../Packages/WheelhouseKit/Tests/WheelhouseDesktopTests/PTYTests.swift -> repository root
        var root = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let source = root.appending(path: "Helpers/wh-pty-exec/main.c")
        let out = FileManager.default.temporaryDirectory.appending(path: "wh-pty-exec-\(UUID().uuidString)")
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        cc.arguments = [source.path, "-o", out.path]
        try cc.run()
        cc.waitUntilExit()
        guard cc.terminationStatus == 0 else { throw PTYError.spawnFailed("cc failed for \(source.path)") }
        built.withLock { $0 = out }
        return out
    }
}

private func ptySpec(_ script: String, env: [String: String] = ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"]) -> ProcessSpec {
    ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: env)
}

private func collect(_ stream: AsyncStream<Data>, until done: @escaping @Sendable (String) -> Bool = { _ in false },
                     timeout: Duration = .seconds(10)) async -> String {
    await withTaskGroup(of: String.self) { group in
        group.addTask {
            var text = ""
            for await chunk in stream {
                text += String(decoding: chunk, as: UTF8.self)
                if done(text) { break }
            }
            return text
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return "<timeout>"
        }
        let first = await group.next() ?? ""
        group.cancelAll()
        return first
    }
}

@Suite("PTYProcess", .serialized)
struct PTYTests {
    @Test func theChildHasAControllingTerminalAndTheRequestedSize() async throws {
        let pty = try PTYProcess(spec: ptySpec("ps -o tty= -p $$; stty size"), size: (cols: 100, rows: 30), helper: try PTYHelper.url())
        let text = await collect(pty.output, until: { $0.contains("30 100") })
        #expect(text.contains("30 100"))
        // `ps` shows a tty name (ttysNNN), not `??`, so the session has a controlling terminal.
        #expect(text.contains("ttys"))
        #expect(!text.contains("??"))
        let exit = await pty.waitForExit()
        #expect(exit.code == 0)
    }

    @Test func inputIsOrderedAndEchoed() async throws {
        let pty = try PTYProcess(spec: ptySpec("read a; read b; echo \"got:$a:$b\""), size: (80, 24), helper: try PTYHelper.url())
        pty.write(Data("one\n".utf8))
        pty.write(Data("two\n".utf8))
        let text = await collect(pty.output, until: { $0.contains("got:one:two") })
        #expect(text.contains("got:one:two"))
    }

    @Test func resizeDeliversSIGWINCH() async throws {
        let script = "trap 'stty size' WINCH; stty size; echo ready; while :; do sleep 0.05; done"
        let pty = try PTYProcess(spec: ptySpec(script), size: (80, 24), helper: try PTYHelper.url())
        _ = await collect(pty.output, until: { $0.contains("ready") })
        pty.resize(cols: 132, rows: 43)
        let text = await collect(pty.output, until: { $0.contains("43 132") })
        #expect(text.contains("43 132"))
        await pty.terminate(gracePeriod: .seconds(1))
    }

    @Test func stdoutPipeKeepsTheCredentialApartFromThePrompts() async throws {
        let pty = try PTYProcess(spec: ptySpec("printf 'Enter code: ' >&2; read c; printf '{\"code\":\"%s\"}' \"$c\""), size: (80, 24), stdoutPipe: true,
                                 helper: try PTYHelper.url())
        let prompt = await collect(pty.output, until: { $0.contains("Enter code:") })
        #expect(prompt.contains("Enter code:"))
        pty.write(Data("123456\n".utf8))
        let json = await collect(pty.stdout)
        #expect(json == "{\"code\":\"123456\"}")
        let exit = await pty.waitForExit()
        #expect(exit.code == 0)
    }

    @Test func terminateSendsSIGHUPToTheGroup() async throws {
        let pty = try PTYProcess(spec: ptySpec("sleep 60"), size: (80, 24), helper: try PTYHelper.url())
        try await Task.sleep(for: .milliseconds(200))
        let started = ContinuousClock.now
        await pty.terminate(gracePeriod: .seconds(2))
        #expect(pty.hasExited)
        #expect(started.duration(to: .now) < .seconds(5))
    }

    @Test func aMissingProgramReportsThroughTheTerminalWithExit127() async throws {
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/nonexistent/prog"), arguments: [], environment: ["PATH": "/usr/bin"])
        let pty = try PTYProcess(spec: spec, size: (80, 24), helper: try PTYHelper.url())
        let exit = await pty.waitForExit()
        #expect(exit.code == 127)
    }

    @Test func aMissingHelperThrows() {
        #expect(throws: PTYError.self) {
            _ = try PTYProcess(spec: ptySpec("true"), size: (80, 24), helper: URL(fileURLWithPath: "/nonexistent/wh-pty-exec"))
        }
    }

    @Test func outputIsCoalescedIntoFewChunks() async throws {
        let pty = try PTYProcess(spec: ptySpec("i=0; while [ $i -lt 500 ]; do echo line-$i; i=$((i+1)); done"), size: (80, 24), helper: try PTYHelper.url())
        var chunks = 0
        var total = ""
        for await d in pty.output { chunks += 1; total += String(decoding: d, as: UTF8.self) }
        #expect(total.contains("line-499"))
        #expect(chunks < 200)
    }
}
#endif
