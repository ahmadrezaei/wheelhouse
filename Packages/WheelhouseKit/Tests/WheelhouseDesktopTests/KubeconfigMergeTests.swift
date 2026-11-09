#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// The native merge (ARCHITECTURE-MAC §4.9). Every file here lives in a scratch folder; none is named `.kube`, because the process gate
/// refuses any path under a `~/.kube` while tests run (see `processGateRefusesAnyHomeKubePathEvenWithAnOpenPolicy`).
@Suite("KubeconfigMerge")
struct KubeconfigMergeTests {
    static let existing = """
    apiVersion: v1
    kind: Config
    # a comment that normalisation drops
    current-context: prod-eu
    preferences: {}
    clusters:
    - name: c-prod
      cluster: {server: "https://prod-eu.example.test:6443"}
    users:
    - name: u-prod
      user: {token: tok-prod}
    contexts:
    - name: prod-eu
      context: {cluster: c-prod, user: u-prod, namespace: payments}
    """

    static func cluster(name: String = "arn:aws:eks:eu-west-1:123456789012:cluster/payments", profile: String = "123456789012", server: String = "https://x.eks.example.test") -> CloudCluster {
        CloudCluster(provider: .aws, accountID: profile, accountName: profile, name: "payments", region: "eu-west-1", endpoint: server, caData: "Q0EtREFUQQ==",
                     status: "Active", contextName: name)
    }

    func writer(_ s: Scratch) throws -> KubeconfigWriter { KubeconfigWriter(gate: openGate(home: try s.home())) }
    func mode(_ url: URL) -> Int { Int((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue ?? -1) }

    @Test func mergesIntoAFileWithCurrentContextAndLeavesItAlone() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = try s.write("config-a", Self.existing, mode: 0o640)
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let plan = try writer(s).plan(entries: entries, into: target, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(plan.currentContext == "prod-eu")
        #expect(plan.yaml.contains("arn:aws:eks:eu-west-1:123456789012:cluster/payments"))
        #expect(plan.backup?.lastPathComponent.hasPrefix("config-a.wheelhouse-backup-") == true)
        #expect(plan.added.count == 3 && plan.replaced.isEmpty)

        let result = try writer(s).merge(plan: plan, entries: entries)
        let backup = try #require(result.backup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.existing)
        #expect(mode(backup) == 0o600)
        #expect(mode(target) == 0o640)                                   // the original mode is kept
        let merged = try String(contentsOf: target, encoding: .utf8)
        let parsed = try KubeconfigParser.parse(merged, environment: .desktop(baseDirectory: s.root))
        #expect(parsed.currentContext == "prod-eu")                      // never changed
        #expect(Set(parsed.contexts.map(\.name)) == ["prod-eu", "arn:aws:eks:eu-west-1:123456789012:cluster/payments"])
        #expect(parsed.contexts.first { $0.name == "prod-eu" }?.namespace == "payments")
        #expect(parsed.contexts.first { $0.name == "prod-eu" }?.auth == .token("tok-prod"))
        #expect(parsed.contexts.first { $0.name != "prod-eu" }?.exec?.command == "aws")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("lock").path))
        // The tidy-up is only normalisation: the comment is gone, nothing else.
        #expect(!merged.contains("a comment"))
    }

    @Test func aFileWithoutCurrentContextStaysWithout() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = try s.write("config-b", Self.existing.replacingOccurrences(of: "current-context: prod-eu\n", with: ""))
        _ = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: target)
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(!text.contains("current-context"))
        #expect(try KubeconfigParser.parse(text).currentContext == nil)
    }

    @Test func nameCollisionsReplaceOnlyTheNamedEntriesInPlace() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let name = "arn:aws:eks:eu-west-1:123456789012:cluster/payments"
        let seeded = Self.existing + """

        - name: \(name)
          context: {cluster: \(name), user: \(name)}
        """
        // The three sections: add the same-named cluster and user in the right sections too.
        let doc = seeded
            .replacingOccurrences(of: "users:\n", with: "users:\n- name: \(name)\n  user: {token: old-token}\n")
            .replacingOccurrences(of: "clusters:\n", with: "clusters:\n- name: \(name)\n  cluster: {server: \"https://old.example.test\"}\n")
        let target = try s.write("config-c", doc)
        let result = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster(server: "https://new.example.test")]), into: target)
        #expect(Set(result.replaced) == ["clusters/\(name)", "users/\(name)", "contexts/\(name)"])
        #expect(result.added.isEmpty)
        let parsed = try KubeconfigParser.parse(try String(contentsOf: target, encoding: .utf8), environment: .desktop(baseDirectory: s.root))
        #expect(parsed.contexts.count == 2)
        let replaced = try #require(parsed.contexts.first { $0.name == name })
        #expect(replaced.server?.host() == "new.example.test")
        #expect(replaced.exec?.command == "aws")                         // the old token user is gone
        #expect(parsed.contexts.first { $0.name == "prod-eu" }?.auth == .token("tok-prod"))
    }

    @Test func aFailedVerificationRestoresTheOriginalByteForByte() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = try s.write("config-d", Self.existing, mode: 0o600)
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let w = try writer(s)
        let plan = try w.plan(entries: entries, into: target)
        // Something else changes current-context right after our write.
        #expect {
            try w.merge(plan: plan, entries: entries, afterWrite: { url in
                let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "current-context: prod-eu", with: "current-context: elsewhere")
                try text.write(to: url, atomically: true, encoding: .utf8)
            })
        } throws: { error in
            guard case KubeconfigWriteError.verificationFailed(let why, let restored) = error else { return false }
            return restored && why.contains("current-context")
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == Self.existing)
        #expect(mode(target) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathExtension("lock").path))
    }

    @Test func aNewFileIsCreatedPrivatelyWithoutABackupAndRemovedOnFailure() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let w = try writer(s)
        let target = s.root.appending(path: "fresh/config")
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let plan = try w.plan(entries: entries, into: target)
        #expect(plan.backup == nil && plan.baseHash == nil && plan.currentContext == nil)
        let result = try w.merge(plan: plan, entries: entries)
        #expect(result.backup == nil)
        #expect(mode(target) == 0o600)
        #expect(try KubeconfigParser.parse(try String(contentsOf: target, encoding: .utf8)).contexts.count == 1)

        let failing = s.root.appending(path: "fresh2/config")
        let failingPlan = try w.plan(entries: entries, into: failing)
        #expect(throws: KubeconfigWriteError.self) {
            try w.merge(plan: failingPlan, entries: entries, afterWrite: { url in try "nonsense: [".write(to: url, atomically: true, encoding: .utf8) })
        }
        #expect(!FileManager.default.fileExists(atPath: failing.path))
    }

    @Test func numericProfilesAndAccountNumbersStayStrings() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let target = try s.write("config-e", Self.existing)
        _ = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster(profile: "123456789012")]), into: target)
        let parsed = try KubeconfigParser.parse(try String(contentsOf: target, encoding: .utf8), environment: .desktop(baseDirectory: s.root))
        #expect(parsed.contexts.first { $0.exec != nil }?.exec?.env == [.init(name: "AWS_PROFILE", value: "123456789012")])
    }

    @Test func fileShapesThatCouldNotBeRewrittenSafelyAreRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let w = try writer(s)
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let multi = try s.write("multi", Self.existing + "\n---\napiVersion: v1\nkind: Other\n")
        #expect(throws: KubeconfigMergeError.multipleDocuments) { _ = try w.plan(entries: entries, into: multi) }
        let notMapping = try s.write("list", "- a\n- b\n")
        #expect(throws: KubeconfigMergeError.self) { _ = try w.plan(entries: entries, into: notMapping) }
        let dup = try s.write("dup", Self.existing.replacingOccurrences(of: "contexts:\n", with: "contexts:\n- name: \(Self.cluster().contextName)\n  context: {cluster: a, user: b}\n- name: \(Self.cluster().contextName)\n  context: {cluster: c, user: d}\n"))
        #expect(throws: KubeconfigMergeError.self) { _ = try w.plan(entries: entries, into: dup) }
        for url in [multi, notMapping, dup] { #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appending(path: url.lastPathComponent + ".lock").path)) }
        // `clusters: null` is an empty list.
        let nulls = try s.write("nulls", "apiVersion: v1\nkind: Config\nclusters: null\nusers:\ncontexts: []\ncurrent-context: keep\n")
        _ = try w.merge(entries: entries, into: nulls)
        let parsed = try KubeconfigParser.parse(try String(contentsOf: nulls, encoding: .utf8))
        #expect(parsed.currentContext == "keep" && parsed.contexts.count == 1)
    }

    @Test func yamlAliasesAreWrittenOutAsEqualCopies() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let aliased = Self.existing.replacingOccurrences(of: "  user: {token: tok-prod}", with: "  user: &tok {token: tok-prod}\n- name: u2\n  user: *tok")
            + "\n- name: second\n  context: {cluster: c-prod, user: u2}"
        let target = try s.write("aliased", aliased)
        _ = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: target)
        let parsed = try KubeconfigParser.parse(try String(contentsOf: target, encoding: .utf8), environment: .desktop(baseDirectory: s.root))
        #expect(parsed.contexts.first { $0.name == "second" }?.auth == .token("tok-prod"))
        #expect(parsed.currentContext == "prod-eu")
    }

    @Test func aHardLinkedAndAChangedFileAreRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let w = try writer(s)
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let original = try s.write("config-f", Self.existing)
        let alias = s.root.appending(path: "alias-of-f")
        try FileManager.default.linkItem(at: original, to: alias)
        #expect(throws: KubeconfigWriteError.hardLinked) { _ = try w.plan(entries: entries, into: original) }

        let g = try s.write("config-g", Self.existing)
        let plan = try w.plan(entries: entries, into: g)
        try (Self.existing + "\n# edited elsewhere\nextra: 1\n").write(to: g, atomically: true, encoding: .utf8)
        #expect(throws: KubeconfigWriteError.changedSinceReview) { _ = try w.merge(plan: plan, entries: entries) }
        #expect(try String(contentsOf: g, encoding: .utf8).contains("edited elsewhere"))
    }

    @Test func aLockFileFromAnotherProgramStopsTheMerge() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let w = try writer(s)
        let target = try s.write("config-h", Self.existing)
        try s.write("config-h.lock", "")
        #expect(throws: KubeconfigWriteError.locked) { _ = try w.merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: target) }
        #expect(try String(contentsOf: target, encoding: .utf8) == Self.existing)
        #expect(FileManager.default.fileExists(atPath: target.appendingPathExtension("lock").path))   // not ours: left alone
    }

    @Test func aSymlinkedConfigStaysALinkAndItsTargetIsUpdated() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let realFile = try s.write("dotfiles/kubeconfig", Self.existing)
        let link = s.root.appending(path: "linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        let result = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: link)
        #expect(result.target == realFile)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil)
        #expect(result.backup?.deletingLastPathComponent() == realFile.deletingLastPathComponent())
        #expect(try String(contentsOf: realFile, encoding: .utf8).contains("arn:aws:eks"))
    }

    @Test func twoMergesInOneSecondKeepBothBackups() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let w = try writer(s)
        let target = try s.write("config-i", Self.existing)
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let a = try w.merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: target, now: stamp)
        let b = try w.merge(entries: LandfallKubeconfig.entries(for: [Self.cluster(name: "other", server: "https://o.example.test")]), into: target, now: stamp)
        #expect(a.backup != nil && b.backup != nil && a.backup != b.backup)
        #expect(try String(contentsOf: a.backup!, encoding: .utf8) == Self.existing)
        #expect(try String(contentsOf: b.backup!, encoding: .utf8).contains("arn:aws:eks"))
    }

    @Test func aLockOnTheSymlinkPathAloneStopsTheMerge() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let realFile = try s.write("dotfiles/kubeconfig", Self.existing)
        let link = s.root.appending(path: "linked-config")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFile)
        try s.write("linked-config.lock", "")                                   // kubectl locks the path it was given
        #expect(throws: KubeconfigWriteError.locked) { _ = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: link) }
        #expect(try String(contentsOf: realFile, encoding: .utf8) == Self.existing)
        #expect(!FileManager.default.fileExists(atPath: realFile.appendingPathExtension("lock").path))   // the lock taken first is released
    }

    @Test func aSymlinkedFolderIsLockedOnceAndTheMergeSucceeds() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let realDir = try s.dir("dotfiles-kube")
        let file = realDir.appending(path: "config")
        try Self.existing.write(to: file, atomically: true, encoding: .utf8)
        let linkDir = s.root.appending(path: "linked-dir")
        try FileManager.default.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        // Both names (the link's and the target's) are one file: one lock, not two.
        let result = try writer(s).merge(entries: LandfallKubeconfig.entries(for: [Self.cluster()]), into: linkDir.appending(path: "config"))
        #expect(result.added.count == 3)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("arn:aws:eks"))
        #expect(!FileManager.default.fileExists(atPath: file.appendingPathExtension("lock").path))
    }

    // MARK: Gate

    @Test func everyWriteIsRefusedWhileTheGateIsActive() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let w = KubeconfigWriter(gate: activeGate(home: home))
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        let userFile = try s.write("home/.kube/config", Self.existing)      // a stand-in for the user's file
        let plain = try s.write("plain", Self.existing)
        for url in [userFile, plain, s.root.appending(path: "new/config")] {
            #expect(throws: DevSafetyError.disabledInDevelopment("Writing kubeconfig files")) { _ = try w.plan(entries: entries, into: url) }
            #expect(throws: DevSafetyError.self) { _ = try w.merge(entries: entries, into: url) }
        }
        #expect(try String(contentsOf: userFile, encoding: .utf8) == Self.existing)
        #expect(try String(contentsOf: plain, encoding: .utf8) == Self.existing)
        #expect(!FileManager.default.fileExists(atPath: s.root.appending(path: "new").path))
        // The merge target resolver refuses too.
        #expect(throws: DevSafetyError.self) { _ = try LandfallMergeTarget.resolve(gate: activeGate(home: home)) }
        #expect(try LandfallMergeTarget.resolve(gate: openGate(home: home)) == home.appending(path: ".kube/config"))
    }

    @Test func processGateRefusesAnyHomeKubePathEvenWithAnOpenPolicy() throws {
        #expect(DevSafety.isActive)
        let s = try Scratch(); defer { s.cleanup() }
        let entries = LandfallKubeconfig.entries(for: [Self.cluster()])
        // A fake home (the policy's own) and the account's REAL home. Neither path is read or created: the refusal comes first, from the path alone.
        let fakeHome = try s.home()
        let fake = fakeHome.appending(path: ".kube/config")
        #expect(throws: DevSafetyError.self) { _ = try KubeconfigWriter(gate: openGate(home: fakeHome)).plan(entries: entries, into: fake) }
        let real = DevSafetyPolicy.accountHome.appending(path: ".kube/wheelhouse-test-never-written-\(UUID().uuidString)")
        #expect(throws: DevSafetyError.self) { _ = try KubeconfigWriter(gate: openGate(home: fakeHome)).plan(entries: entries, into: real) }
        #expect(throws: DevSafetyError.self) { _ = try KubeconfigWriter(gate: openGate(home: fakeHome)).merge(entries: entries, into: real) }
        #expect(!FileManager.default.fileExists(atPath: real.path))
        #expect(!FileManager.default.fileExists(atPath: fake.path))
    }
}
#endif
