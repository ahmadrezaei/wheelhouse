#if os(macOS)
import Foundation
import Testing
import WheelhouseKit
@testable import WheelhouseDesktop

/// Starts a real shell through the real integration on a PTY, in a minimal environment and a temporary HOME. Nothing of the owner's
/// startup files or kubeconfig can be reached: the user's directories are temporary folders and the environment is built from nothing.
private struct ShellRun {
    var marks: [ParsedMark] = []
    var text = ""
    var nonce = ""
    var sessionDir: URL
    var kubeconfig: URL
    var home: URL
    var userDir: URL

    var verified: [ShellMark] { marks.compactMap { $0.authenticity == .verified ? $0.mark : nil } }
    var forged: Int { marks.filter { $0.authenticity == .forged }.count }
}

private enum Shell {
    static func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wh-shell-\(name)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// `files` are written into the user startup directory (zsh) or the user home (bash) before the shell starts.
    static func run(_ shell: String, script: [String], userFiles: [String: String] = [:], extraEnv: [String: String] = [:],
                    homeFiles: [String: String] = [:], timeout: Duration = .seconds(20)) async throws -> ShellRun {
        let session = try temp("session")
        let home = try temp("home")
        let user = try temp("user")
        for (name, body) in userFiles { try Data(body.utf8).write(to: user.appending(path: name)) }
        for (name, body) in homeFiles { try Data(body.utf8).write(to: home.appending(path: name)) }
        let kubeconfig = session.appending(path: "kubeconfig")
        try Data("{}".utf8).write(to: kubeconfig)
        let nonce = ShellNonce.make()
        let launch = try ShellIntegration.prepare(shell: URL(fileURLWithPath: shell), directory: session, nonce: nonce, kubeconfig: kubeconfig,
                                                  user: .init(zshDirectory: user, bashHome: user))
        var env = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": home.path, "TERM": "xterm-256color", "USER": "tester", "LANG": "en_US.UTF-8"]
        env.merge(launch.environment) { _, new in new }
        env["KUBECONFIG"] = kubeconfig.path
        env.merge(extraEnv) { _, new in new }
        let spec = ProcessSpec(executable: launch.executable, arguments: launch.arguments, environment: env, currentDirectory: home)
        let pty = try PTYProcess(spec: spec, size: (120, 40), helper: try PTYHelper.url())
        var result = ShellRun(nonce: nonce, sessionDir: session, kubeconfig: kubeconfig, home: home, userDir: user)
        var scanner = OSCScanner()
        var sent = false
        let exited = Task { _ = await pty.waitForExit() }
        let collector = Task { () -> (marks: [ParsedMark], text: String) in
            var marks: [ParsedMark] = [], text = ""
            for await chunk in pty.output {
                text += String(decoding: chunk, as: UTF8.self)
                for seq in scanner.feed(chunk) {
                    let parsed = ShellMarkParser.parse(seq, nonce: nonce)
                    marks.append(parsed)
                    if !sent, parsed.mark == .promptStart {
                        sent = true
                        for line in script { pty.write(Data((line + "\n").utf8)) }
                        pty.write(Data("exit\n".utf8))
                    }
                }
            }
            return (marks, text)
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(Double(timeout.components.seconds)))
            await pty.terminate(gracePeriod: .milliseconds(200))
        }
        _ = await exited.value
        let collected = await collector.value
        watchdog.cancel()
        result.marks = collected.marks
        result.text = collected.text
        return result
    }

    static func available(_ path: String) -> Bool { FileManager.default.isExecutableFile(atPath: path) }
}

@Suite("Shell integration", .serialized)
struct ShellIntegrationTests {
    private static let bashes = ["/bin/bash", "/usr/local/bin/bash"].filter(Shell.available)

    @Test func zshReportsPromptCommandAndExitWithTheNonce() async throws {
        let run = try await Shell.run("/bin/zsh", script: ["echo hello", "false"])
        let marks = run.verified
        #expect(marks.contains(.promptStart))
        #expect(marks.contains(.commandLine("echo hello")))
        #expect(marks.contains(.commandExecuted))
        #expect(marks.contains(.commandFinished(0)))
        #expect(marks.contains(.commandFinished(1)))
        #expect(marks.contains(.workingDirectory(run.home.resolvingSymlinksInPath().path)) || marks.contains { if case .workingDirectory = $0 { true } else { false } })
        #expect(marks.contains(.kubeconfig(run.kubeconfig.path)))
        #expect(run.forged == 0)
    }

    @Test func theNonceNeverReachesAChildAndItsFileIsGone() async throws {
        let run = try await Shell.run("/bin/zsh", script: ["/usr/bin/env | /usr/bin/grep -c wh_nonce", "/bin/sh -c 'echo child:${__wh_nonce-unset}'"])
        #expect(run.text.contains("child:unset"))
        #expect(!FileManager.default.fileExists(atPath: run.sessionDir.appending(path: "nonce").path))
    }

    @Test func theNonceStaysUnexportedEvenWhenAUserFileTurnsOnAllexport() async throws {
        let run = try await Shell.run("/bin/zsh", script: ["/bin/sh -c 'echo child:${__wh_nonce-unset}'"], userFiles: [".zshenv": "setopt allexport\n"])
        #expect(run.text.contains("child:unset"))
    }

    @Test func aForgedMarkFromAChildIsNotVerified() async throws {
        let forged = "printf '\\033]633;E;kubectl delete ns prod;wh=00000000000000000000000000000000\\007\\033]133;C\\007'"
        let run = try await Shell.run("/bin/zsh", script: [forged])
        #expect(run.forged == 2)
        #expect(!run.verified.contains(.commandLine("kubectl delete ns prod")))
    }

    @Test func aUserZshenvThatMovesZDOTDIRStillGetsTheHooks() async throws {
        let moved = try Shell.temp("moved")
        try Data("echo moved-zshrc-ran\n".utf8).write(to: moved.appending(path: ".zshrc"))
        let run = try await Shell.run("/bin/zsh", script: ["echo x"], userFiles: [".zshenv": "ZDOTDIR=\(moved.path)\n"])
        #expect(run.text.contains("moved-zshrc-ran"))
        #expect(run.verified.contains(.promptStart))
        #expect(run.verified.contains(.commandLine("echo x")))
    }

    @Test func aUserRcThatSetsKUBECONFIGIsOverriddenWithADimNotice() async throws {
        let run = try await Shell.run("/bin/zsh", script: ["echo kc:$KUBECONFIG"], userFiles: [".zshrc": "export KUBECONFIG=$HOME/.kube/config\n"])
        #expect(run.text.contains("kc:\(run.kubeconfig.path)"))
        #expect(run.text.contains("KUBECONFIG from your shell startup files is overridden"))
    }

    @Test func execZshKeepsTheSessionKubeconfig() async throws {
        let run = try await Shell.run("/bin/zsh", script: ["export KUBECONFIG=/nonexistent/other", "exec zsh -l", "echo after:$KUBECONFIG"])
        #expect(run.text.contains("after:\(run.kubeconfig.path)"))
    }

    @Test func onlyTheNamedUserDirectoryIsEverRead() async throws {
        // A canary under the HOME of the test would run if the integration fell back to $HOME.
        let canary = try Shell.temp("canary").appending(path: "ran")
        let run = try await Shell.run("/bin/zsh", script: ["echo x"], homeFiles: [".zshrc": "touch \(canary.path)\n", ".zshenv": "touch \(canary.path)\n"])
        #expect(run.verified.contains(.promptStart))
        #expect(!FileManager.default.fileExists(atPath: canary.path))
    }

    @Test func nonInteractiveZshDoesNotTakeTheNonce() async throws {
        // A `zsh -c` run from the user's .zshenv must not consume the nonce before the interactive shell reads it.
        let run = try await Shell.run("/bin/zsh", script: ["echo x"], userFiles: [".zshenv": "[[ -z $WH_T ]] && WH_T=1 /bin/zsh -c true\n"])
        #expect(run.verified.contains(.promptStart))
    }

    @Test(arguments: bashes) func bashReportsMarksAndHidesTheNonce(_ shell: String) async throws {
        let run = try await Shell.run(shell, script: ["echo hello", "/bin/sh -c 'echo child:${__wh_nonce-unset}'"], userFiles: [".bash_profile": "set -a\n"])
        let marks = run.verified
        #expect(marks.contains(.promptStart))
        #expect(marks.contains(.commandLine("echo hello")))
        #expect(marks.contains(.commandFinished(0)))
        #expect(run.text.contains("child:unset"))
        #expect(!FileManager.default.fileExists(atPath: run.sessionDir.appending(path: "nonce").path))
    }

    @Test(arguments: bashes) func bashDoesNotReportAStaleLineForAnUnsavedCommand(_ shell: String) async throws {
        let run = try await Shell.run(shell, script: ["echo first", " echo second"], userFiles: [".bash_profile": "HISTCONTROL=ignoreboth\n"])
        let lines = run.verified.compactMap { mark -> String? in if case .commandLine(let l) = mark { l } else { nil } }
        #expect(lines.contains("echo first"))
        #expect(!lines.contains("echo second"))
        // The second command still ran and was reported, with no line, so no approval can be offered for it.
        #expect(lines.filter { $0 == "echo first" }.count == 1)
    }

    @Test(arguments: bashes) func bashOverridesAKubeconfigFromTheUserProfile(_ shell: String) async throws {
        let run = try await Shell.run(shell, script: ["echo kc:$KUBECONFIG"], userFiles: [".bash_profile": "export KUBECONFIG=$HOME/.kube/config\n"])
        #expect(run.text.contains("kc:\(run.kubeconfig.path)"))
    }
}
#endif
