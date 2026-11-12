#if os(macOS)
import Foundation
import Testing
import WheelhouseKit
@testable import WheelhouseDesktop

@Suite("OSC scanner")
struct OSCScannerTests {
    private let nonce = "0123456789abcdef0123456789abcdef"

    private func scan(_ chunks: [Data]) -> [OSCSequence] {
        var s = OSCScanner()
        return chunks.flatMap { s.feed($0) }
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    @Test func findsABelAndAnStTerminatedSequence() {
        let found = scan([bytes("x\u{1B}]133;A;wh=\(nonce)\u{07}y\u{1B}]633;E;ls;wh=\(nonce)\u{1B}\\z")])
        #expect(found.map(\.code) == [133, 633])
        #expect(found[1].payload == "E;ls;wh=\(nonce)")
    }

    @Test func aSequenceSplitAtEveryByteIsStillFound() {
        let whole = bytes("a\u{1B}]633;E;echo hi;wh=\(nonce)\u{07}b")
        for cut in 1..<whole.count {
            let found = scan([whole.prefix(cut), whole.suffix(from: cut)])
            #expect(found.count == 1, "cut at \(cut)")
        }
        let single = scan(whole.map { Data([$0]) })
        #expect(single.count == 1)
    }

    @Test func otherCodesAreSkipped() {
        #expect(scan([bytes("\u{1B}]0;title\u{07}\u{1B}]7;file:///tmp\u{07}")]).isEmpty)
    }

    @Test func canAndSubAbortASequence() {
        #expect(scan([bytes("\u{1B}]133;A\u{18}rest\u{07}")]).isEmpty)
        #expect(scan([bytes("\u{1B}]133;A\u{1A}rest\u{07}")]).isEmpty)
    }

    @Test func aLoneEscapeBracketDoesNotSwallowTheNextRealMark() {
        // A program printed ESC ] and nothing else; the next real mark arrives after an ESC that is not a string terminator.
        let found = scan([bytes("\u{1B}]junk\u{1B}[0m\u{1B}]133;D;0;wh=\(nonce)\u{07}")])
        #expect(found.count == 1)
        #expect(found.first?.payload.hasPrefix("D;0") == true)
    }

    @Test func aNewOscStartsOverAnUnterminatedOne() {
        let found = scan([bytes("\u{1B}]133;A\u{1B}]133;D;0;wh=\(nonce)\u{07}")])
        #expect(found.count == 1)
        #expect(found.first?.payload.hasPrefix("D;0") == true)
    }

    @Test func anOverlongSequenceIsDroppedAndTheScannerRecovers() {
        let long = bytes("\u{1B}]133;" + String(repeating: "x", count: OSCScanner.maxLength + 10) + "\u{07}\u{1B}]133;A;wh=\(nonce)\u{07}")
        let found = scan([long])
        #expect(found.count == 1)
        #expect(found.first?.payload == "A;wh=\(nonce)")
    }
}

@Suite("OSC filtering")
struct OSCFilterTests {
    private let nonce = "0123456789abcdef0123456789abcdef"

    private func run(_ chunks: [Data]) -> (marks: Int, output: String) {
        var scanner = OSCScanner()
        var marks = 0
        var out = Data()
        for chunk in chunks {
            let r = scanner.process(chunk)
            marks += r.sequences.count
            out.append(r.output)
        }
        return (marks, String(decoding: out, as: UTF8.self))
    }

    @Test func marksAreRemovedAndEverythingElseIsUnchangedAtEveryChunkBoundary() {
        let text = "a\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{07}b\u{1B}]133;A;wh=\(nonce)\u{07}c\u{1B}]633;E;ls;wh=\(nonce)\u{1B}\\d\u{1B}]8;;http://x\u{07}link\u{1B}]8;;\u{07}e"
        let expected = "a\u{1B}[31mred\u{1B}[0m\u{1B}]0;title\u{07}bc" + "d\u{1B}]8;;http://x\u{07}link\u{1B}]8;;\u{07}e"
        let whole = Data(text.utf8)
        let unsplit = run([whole])
        #expect(unsplit.marks == 2)
        #expect(unsplit.output == expected)
        for cut in 1..<whole.count {
            let split = run([whole.prefix(cut), whole.suffix(from: cut)])
            #expect(split.marks == 2, "cut \(cut)")
            #expect(split.output == expected, "cut \(cut)")
        }
        #expect(run(whole.map { Data([$0]) }).output == expected)
    }

    @Test func aMarkThatIsCutShortIsDroppedNotPassedOn() {
        // The terminal acts on an OSC 133 when an ESC ends it, so a cut-short mark must never reach it.
        #expect(run([Data("\u{1B}]133;A\u{1B}[0m".utf8)]).output == "\u{1B}[0m")
        #expect(run([Data("x\u{1B}]633;E;ls\u{1B}]0;t\u{07}y".utf8)]).output == "x\u{1B}]0;t\u{07}y")
        #expect(run([Data("a\u{1B}]133;A\u{18}b".utf8)]).output == "ab")
        // Other sequences, short ones included, are never touched.
        let other = "x\u{1B}]1\u{07}y\u{1B}]0;t\u{1B}[0mz"
        #expect(run([Data(other.utf8)]).output == other)
    }

    @Test func anOverlongMarkIsSwallowedUpToItsTerminator() {
        let long = "p\u{1B}]133;" + String(repeating: "x", count: OSCScanner.maxLength + 50) + "\u{07}q"
        let result = run([Data(long.utf8)])
        #expect(result.output == "pq" && result.marks == 0)
    }
}

@Suite("Shell marks")
struct ShellMarkTests {
    private let nonce = "0123456789abcdef0123456789abcdef"

    @Test func verifiedMarksParse() {
        func parse(_ code: Int, _ payload: String) -> ParsedMark { ShellMarkParser.parse(OSCSequence(code: code, payload: payload), nonce: nonce) }
        #expect(parse(133, "A;wh=\(nonce)").mark == .promptStart)
        #expect(parse(133, "C;wh=\(nonce)").mark == .commandExecuted)
        #expect(parse(133, "D;2;wh=\(nonce)").mark == .commandFinished(2))
        #expect(parse(633, "E;kubectl get pods\\x3b ls;wh=\(nonce)").mark == .commandLine("kubectl get pods; ls"))
        #expect(parse(633, "E;a\\\\b;wh=\(nonce)").mark == .commandLine("a\\b"))
        #expect(parse(633, "P;KubeConfig=/tmp/x;wh=\(nonce)").mark == .kubeconfig("/tmp/x"))
        #expect(parse(633, "P;KubeConfigUnset=1;wh=\(nonce)").mark == .kubeconfig(nil))
        #expect(parse(633, "P;Cwd=/Users/a;wh=\(nonce)").mark == .workingDirectory("/Users/a"))
    }

    @Test func aMissingOrWrongNonceIsForged() {
        for payload in ["A", "A;wh=", "A;wh=ffffffffffffffffffffffffffffffff", "A;wh=\(nonce)x", "wh=\(nonce);A"] {
            let parsed = ShellMarkParser.parse(OSCSequence(code: 133, payload: payload), nonce: nonce)
            #expect(parsed.authenticity == .forged, "\(payload)")
            #expect(parsed.mark == nil)
        }
    }

    @Test func theNonceIs128BitsOfHexAndDiffers() {
        let a = ShellNonce.make(), b = ShellNonce.make()
        #expect(a.count == 32 && a.allSatisfy(\.isHexDigit))
        #expect(a != b)
    }
}

@Suite("Terminal safety helpers")
@MainActor
struct TerminalSafetyTests {
    @Test func bypassFlagsAreFound() {
        for line in ["kubectl --kubeconfig /tmp/x get po", "kubectl get po --kubeconfig=/tmp/x", "KUBECONFIG=/x kubectl get po", "env KUBECONFIG=/x kubectl get po",
                     "kubectl -s https://x get po", "kubectl --server=https://x get po", "kubectl --token abc get po", "helm --kube-apiserver https://x ls",
                     "HELM_KUBEAPISERVER=https://x helm ls", "helm list --kube-token t"] {
            #expect(UnguardedDetector.bypassReason(in: line) != nil, "\(line)")
        }
        for line in ["kubectl get po", "ls -s", "grep --token x file", "kubectl get po -n kube-system", "FOO=1 kubectl get po"] {
            #expect(UnguardedDetector.bypassReason(in: line) == nil, "\(line)")
        }
    }

    @Test func theTerminalEnvironmentStripsWhatCouldBypassGangway() {
        let base = ["PATH": "/usr/bin", "HOME": "/h", "KUBECONFIG": "/Users/x/.kube/config", "KUBERNETES_MASTER": "https://x", "HELM_KUBEAPISERVER": "https://x",
                    "HELM_KUBETOKEN": "t", "HELM_CACHE_HOME": "/c", "WHEELHOUSE_CLUSTER": "old", "DYLD_INSERT_LIBRARIES": "/x", "XPC_FLAGS": "1",
                    "__CFBundleIdentifier": "a", "MallocStackLogging": "1", "ZDOTDIR": "/z", "AWS_PROFILE": "p"]
        let out = TerminalEnvironment.build(base: base, kubeconfig: URL(fileURLWithPath: "/s/kubeconfig"), kubeCacheDir: URL(fileURLWithPath: "/cache"),
                                            session: .init(clusterID: "c", clusterName: "dev", environmentName: "development", sessionID: "sid"))
        let env = out.environment
        #expect(env["KUBECONFIG"] == "/s/kubeconfig")
        for key in ["KUBERNETES_MASTER", "HELM_KUBEAPISERVER", "HELM_KUBETOKEN", "DYLD_INSERT_LIBRARIES", "XPC_FLAGS", "__CFBundleIdentifier", "MallocStackLogging", "ZDOTDIR"] {
            #expect(env[key] == nil, "\(key)")
        }
        #expect(out.userZdotdir == "/z")
        #expect(env["HELM_CACHE_HOME"] == "/c")
        #expect(env["AWS_PROFILE"] == "p")
        #expect(env["WHEELHOUSE_CLUSTER"] == "dev" && env["WHEELHOUSE_ENV"] == "development" && env["WHEELHOUSE_SESSION"] == "sid")
        #expect(env["TERM"] == "xterm-256color" && env["COLORTERM"] == "truecolor" && env["TERM_PROGRAM"] == "Wheelhouse")
        #expect(env["KUBECACHEDIR"] == "/cache")
    }

    @Test func sanitizingRemovesHiddenCharacters() {
        let dirty = "kubectl\u{07} get\tpods\u{1B}[31m\u{202E}x\u{200B}y\u{85}\u{7F}\n"
        let cleaned = TerminalInserter.sanitize(dirty)
        #expect(cleaned.text == "kubectl get pods[31mxy")
        #expect(cleaned.removed == 8)
        #expect(TerminalInserter.sanitize("plain text").removed == 0)
    }

    final class FakeTarget: TerminalInsertTarget {
        var targetClusterID: ClusterID? = "c1"
        var targetClusterName = "staging-eu"
        var bracketedPasteEnabled = true
        var isAtPrompt = true
        var written = Data()
        func writeToShell(_ data: Data) { written.append(data) }
    }

    private func cluster(_ id: String, _ name: String) -> ClusterConfig {
        ClusterConfig(id: id, name: name, server: URL(string: "https://127.0.0.1:1")!, authKind: .none, environment: .development)
    }

    @Test func insertionIsBracketedAndNeverRuns() {
        let target = FakeTarget()
        let outcome = TerminalInserter.insert("kubectl get po\n; rm -rf /", forCluster: cluster("c1", "staging-eu"), into: target)
        #expect(outcome == .inserted(removed: 1))
        #expect(String(decoding: target.written, as: UTF8.self) == "\u{1B}[200~kubectl get po; rm -rf /\u{1B}[201~")
        #expect(!target.written.contains(0x0D) && !target.written.contains(0x0A))
    }

    @Test func insertionIsRefusedForTheWrongClusterWithoutBracketedPasteOrWhileBusy() {
        let target = FakeTarget()
        guard case .refused(let why) = TerminalInserter.insert("ls", forCluster: cluster("c2", "prod-eu-west"), into: target) else { Issue.record("expected refusal"); return }
        #expect(why.contains("staging-eu") && why.contains("prod-eu-west"))
        target.bracketedPasteEnabled = false
        #expect(TerminalInserter.insert("ls", forCluster: nil, into: target) == .refused("This shell does not support safe paste."))
        target.bracketedPasteEnabled = true
        target.isAtPrompt = false
        if case .inserted = TerminalInserter.insert("ls", forCluster: nil, into: target) { Issue.record("a busy terminal must refuse") }
        #expect(target.written.isEmpty)
    }

    @Test func onlyTypedTextRunsAndItIsSanitised() {
        let target = FakeTarget()
        _ = TerminalInserter.runTypedCommand("ls\u{1B}", into: target)
        #expect(String(decoding: target.written, as: UTF8.self) == "\u{1B}[200~ls\u{1B}[201~\r")
    }

    @Test func directModeIsUnavailableForProductionAndReadOnly() {
        var prod = cluster("p", "prod")
        prod.environment = .production
        var ro = cluster("r", "ro")
        ro.readOnly = true
        let gate = DevSafetyPolicy(isActive: false)
        #expect(DirectKubeconfig.availability(for: prod, hasKubeconfigContext: true, gate: gate) != .available)
        #expect(DirectKubeconfig.availability(for: ro, hasKubeconfigContext: true, gate: gate) != .available)
        #expect(DirectKubeconfig.availability(for: cluster("d", "dev"), hasKubeconfigContext: false, gate: gate) != .available)
        #expect(DirectKubeconfig.availability(for: cluster("d", "dev"), hasKubeconfigContext: true, gate: gate) == .available)
        // While the gate is active only an allowed test host qualifies.
        #expect(DirectKubeconfig.availability(for: cluster("d", "dev"), hasKubeconfigContext: true, gate: DevSafetyPolicy(isActive: true, allowedHosts: [])) != .available)
        #expect(DirectKubeconfig.availability(for: cluster("d", "dev"), hasKubeconfigContext: true, gate: DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"])) == .available)
    }

    static func context(name: String, token: String) throws -> KubeconfigContext {
        let yaml = """
        apiVersion: v1
        kind: Config
        clusters:
        - name: \(name)-cluster
          cluster: {server: "https://127.0.0.1:6443"}
        users:
        - name: \(name)-user
          user: {token: \(token)}
        contexts:
        - name: \(name)
          context: {cluster: \(name)-cluster, user: \(name)-user, namespace: apps}
        - name: other-prod
          context: {cluster: \(name)-cluster, user: \(name)-user}
        current-context: \(name)
        """
        let parsed = try KubeconfigParser.parse(yaml, environment: .desktop(baseDirectory: FileManager.default.temporaryDirectory))
        return try #require(parsed.contexts.first { $0.name == name })
    }

    @Test func theDirectFileHoldsOnlyTheOneContextAndIsReadOnly() throws {
        let context = try Self.context(name: "dev", token: "tok")
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-direct-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let written = try DirectKubeconfig.write(context, root: root)
        var st = stat()
        #expect(lstat(written.file.path, &st) == 0 && (st.st_mode & 0o777) == 0o400)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: written.file)) as? [String: Any]
        #expect((json?["contexts"] as? [[String: Any]])?.count == 1)
        #expect((json?["clusters"] as? [[String: Any]])?.count == 1)
        #expect(json?["current-context"] as? String == "dev")
        DirectKubeconfig.remove(directory: written.directory)
        #expect(!FileManager.default.fileExists(atPath: written.directory.path))
    }

    @Test func aDirectFolderSurvivesTheGangwaySweepFolderRulesAndIsSweptByAge() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-sweep-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try Self.context(name: "d", token: "t")
        let written = try DirectKubeconfig.write(context, root: root)
        // The Gangway sweep only removes UUID-named folders directly under `sessions`; Direct lives one level down under `direct`.
        #expect(UUID(uuidString: written.directory.deletingLastPathComponent().lastPathComponent) == nil)
        DirectKubeconfig.sweep(root: root, olderThan: 3600)
        #expect(FileManager.default.fileExists(atPath: written.directory.path))
        DirectKubeconfig.sweep(root: root, olderThan: 3600, now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: written.directory.path))
    }
}
#endif

#if os(macOS)
@Suite("Key to echo", .serialized)
struct KeyToEchoTests {
    /// The M5b perf gate: a typed key echoes in at most 5 ms (p50). The first output after a quiet moment is not held for the 16 ms coalescing window.
    @Test func aTypedKeyEchoesWithinFiveMillisecondsAtTheMedian() async throws {
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/cat"), environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"])
        let pty = try PTYProcess(spec: spec, size: (80, 24), helper: try PTYHelper.url())
        var iterator = pty.output.makeAsyncIterator()
        var samples: [Double] = []
        try await Task.sleep(for: .milliseconds(200))
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            try await Task.sleep(for: .milliseconds(40))
            let start = ContinuousClock.now
            pty.write(Data(String(letter).utf8))
            _ = await iterator.next()
            samples.append(start.duration(to: .now).microseconds / 1000)
        }
        samples.sort()
        let p50 = samples[samples.count / 2]
        #expect(p50 <= 5, "p50 \(p50) ms")
        await pty.terminate(gracePeriod: .milliseconds(200))
    }
}
#endif
