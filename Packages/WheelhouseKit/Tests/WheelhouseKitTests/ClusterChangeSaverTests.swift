import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

/// The Edit Cluster save decision (Mac rules for leaving read-only), without a view.
@Suite("ClusterChangeSaver")
struct ClusterChangeSaverTests {
    struct Failure: Error, Equatable {}

    final class Fake: ClusterChangeAllowing, @unchecked Sendable {
        let managed: Bool
        let chosen: Bool
        var denyAuthorization = false
        var failCommit = false
        private let lock = Mutex<[String]>([])
        init(managed: Bool, chosen: Bool = true) { self.managed = managed; self.chosen = chosen }
        var log: [String] { lock.withLock { $0 } }
        func record(_ s: String) { lock.withLock { $0.append(s) } }

        func managesChanges(for id: ClusterID) -> Bool { managed }
        func environmentChosen(for id: ClusterID) -> Bool { chosen }
        func authorizeLeavingReadOnly(id: ClusterID, currentEnvironment: ClusterEnvironment, environment: ClusterEnvironment) async throws {
            record("authorize:\(currentEnvironment.rawValue)->\(environment.rawValue)")
            if denyAuthorization { throw Failure() }
        }
        func allowChanges(id: ClusterID, environment: ClusterEnvironment, authorized: Bool) async throws {
            record("allow:\(environment.rawValue):authorized=\(authorized)")
            if failCommit { throw Failure() }
        }
    }

    private func config(readOnly: Bool, environment: ClusterEnvironment = .staging) -> ClusterConfig {
        ClusterConfig(id: "c1", name: "c", server: URL(string: "https://c.example.com")!, environment: environment, readOnly: readOnly)
    }

    /// Runs the flow; `persisted` lists every persist call as "readOnly/managed".
    private func run(_ allowing: Fake?, current: ClusterConfig?, target: ClusterConfig, confirmed: Bool = false, failPersist: Bool = false) async throws -> (ClusterChangeSaver.Outcome, [String]) {
        let persisted = Mutex<[String]>([])
        let outcome = try await ClusterChangeSaver.save(allowing: allowing, current: current, target: target, environmentConfirmed: confirmed) { cfg, managed in
            persisted.withLock { $0.append("\(cfg.readOnly)/\(managed)") }
            allowing?.record("persist")
            if failPersist { throw Failure() }
        }
        return (outcome, persisted.withLock { $0 })
    }

    @Test func withoutTheSeamEverythingIsSavedDirectly() async throws {
        let (outcome, persisted) = try await run(nil, current: config(readOnly: true), target: config(readOnly: false))
        #expect(outcome == .saved)
        #expect(persisted == ["false/false"])
    }

    @Test func aKeychainClusterLeavingReadOnlyAsksTheOwnerThenSavesNormally() async throws {
        let fake = Fake(managed: false)
        let (_, persisted) = try await run(fake, current: config(readOnly: true, environment: .production), target: config(readOnly: false, environment: .production))
        #expect(fake.log == ["authorize:production->production", "persist"])
        #expect(persisted == ["false/false"])               // saved with its own secrets and read-only off; Moorings is not involved
    }

    @Test func aManagedClusterIsSavedReadOnlyThenMooringsCommits() async throws {
        let fake = Fake(managed: true)
        let (outcome, persisted) = try await run(fake, current: config(readOnly: true), target: config(readOnly: false))
        #expect(outcome == .saved)
        #expect(fake.log == ["authorize:staging->staging", "persist", "allow:staging:authorized=true"])
        #expect(persisted == ["true/true"])                 // read-only kept on and no secrets while saving
    }

    @Test func aDeniedPromptSavesNothing() async throws {
        for managed in [true, false] {
            let fake = Fake(managed: managed)
            fake.denyAuthorization = true
            await #expect(throws: Failure.self) { _ = try await run(fake, current: config(readOnly: true, environment: .production), target: config(readOnly: false, environment: .production)) }
            #expect(fake.log == ["authorize:production->production"])
        }
    }

    @Test func aFailingSaveNeverCommitsTheChange() async throws {
        let fake = Fake(managed: true)
        await #expect(throws: Failure.self) { _ = try await run(fake, current: config(readOnly: true), target: config(readOnly: false), failPersist: true) }
        #expect(fake.log == ["authorize:staging->staging", "persist"])        // no allow: still read-only
    }

    @Test func aFailingCommitAfterTheSaveIsReported() async throws {
        let fake = Fake(managed: true)
        fake.failCommit = true
        await #expect(throws: Failure.self) { _ = try await run(fake, current: config(readOnly: true), target: config(readOnly: false)) }
        #expect(fake.log == ["authorize:staging->staging", "persist", "allow:staging:authorized=true"])
    }

    @Test func aSuggestedEnvironmentMustBeConfirmedBeforeChangesAreAllowed() async throws {
        let fake = Fake(managed: true, chosen: false)
        let (first, persisted) = try await run(fake, current: config(readOnly: true), target: config(readOnly: false))
        #expect(first == .needsEnvironmentConfirmation)
        #expect(fake.log.isEmpty && persisted.isEmpty)       // nothing asked, nothing saved
        let (second, _) = try await run(fake, current: config(readOnly: true), target: config(readOnly: false), confirmed: true)
        #expect(second == .saved)
        #expect(fake.log.last == "allow:staging:authorized=true")
    }

    @Test func otherEditsOfAManagedClusterNeverTouchSecretsOrMooringsState() async throws {
        let fake = Fake(managed: true)
        let (_, stillReadOnly) = try await run(fake, current: config(readOnly: true), target: config(readOnly: true))
        #expect(stillReadOnly == ["true/true"])
        let (_, alreadyWritable) = try await run(fake, current: config(readOnly: false), target: config(readOnly: false))
        #expect(alreadyWritable == ["false/true"])
        #expect(fake.log == ["persist", "persist"])          // no prompt, no commit
        let (_, turningOn) = try await run(fake, current: config(readOnly: false), target: config(readOnly: true))
        #expect(turningOn == ["true/true"])
    }

    @Test func aNewClusterHasNoCurrentConfigAndIsSavedDirectly() async throws {
        let fake = Fake(managed: false)
        let (_, persisted) = try await run(fake, current: nil, target: config(readOnly: false))
        #expect(persisted == ["false/false"])
        #expect(fake.log == ["persist"])
    }

    @Test func aManagedClustersSecretsAreNeverWrittenEvenWhenTheDraftsCADiffers() {
        let existing = ClusterSecrets(token: "t", caPEM: "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----\n")
        let edited = ClusterSecrets(token: "t", caPEM: "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----")    // trimmed by the draft
        #expect(existing != edited)
        #expect(ClusterChangeSaver.secretsToWrite(managed: true, existing: existing, edited: edited) == nil)
        #expect(ClusterChangeSaver.secretsToWrite(managed: false, existing: existing, edited: edited) == edited)       // unchanged iOS rule
        #expect(ClusterChangeSaver.secretsToWrite(managed: false, existing: existing, edited: existing) == nil)
    }
}
