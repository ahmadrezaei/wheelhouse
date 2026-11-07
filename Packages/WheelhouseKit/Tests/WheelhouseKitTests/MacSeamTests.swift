import Testing
import Foundation
@testable import WheelhouseKit

private func cluster(_ env: ClusterEnvironment, readOnly: Bool = false, allowExec: Bool = false) -> ClusterConfig {
    ClusterConfig(name: "c", server: URL(string: "https://c.example.com")!, environment: env, readOnly: readOnly, allowExecInReadOnly: allowExec)
}

@Suite("MutationPolicy")
struct MutationPolicyTests {
    @Test func readsAndReviewsAlwaysPass() {
        for env in ClusterEnvironment.allCases {
            for readOnly in [false, true] {
                let c = cluster(env, readOnly: readOnly)
                #expect(MutationPolicy.decide(.read, cluster: c, origin: nil) == .pass)
                #expect(MutationPolicy.decide(.review, cluster: c, origin: nil) == .pass)
            }
        }
    }

    @Test func mutationsOnReadOnlyClustersAreRefusedEvenAsDryRun() {
        let c = cluster(.development, readOnly: true)
        #expect(MutationPolicy.decide(.mutation(dryRun: false), cluster: c, origin: nil) == .refuse(MutationPolicy.readOnlyReason))
        #expect(MutationPolicy.decide(.mutation(dryRun: true), cluster: c, origin: .ui) == .refuse(MutationPolicy.readOnlyReason))
    }

    @Test func mutationsRequireTypingOnlyOnProduction() {
        for env in ClusterEnvironment.allCases {
            let v = MutationPolicy.decide(.mutation(dryRun: false), cluster: cluster(env), origin: nil)
            #expect(v == .confirm(requiresTyping: env == .production))
        }
    }

    @Test func execAndPortForwardFollowAllowExecInReadOnly() {
        let locked = cluster(.staging, readOnly: true)
        let allowed = cluster(.staging, readOnly: true, allowExec: true)
        #expect(MutationPolicy.decide(.exec(interactive: true), cluster: locked, origin: nil) == .refuse(MutationPolicy.readOnlyReason))
        #expect(MutationPolicy.decide(.portForward, cluster: locked, origin: nil) == .refuse(MutationPolicy.readOnlyReason))
        #expect(MutationPolicy.decide(.exec(interactive: true), cluster: allowed, origin: nil) == .confirm(requiresTyping: false))
        #expect(MutationPolicy.decide(.portForward, cluster: allowed, origin: nil) == .confirm(requiresTyping: false))
    }

    @Test func nonInteractiveExecIsTypedOnProduction() {
        #expect(MutationPolicy.decide(.exec(interactive: false), cluster: cluster(.production), origin: nil) == .confirm(requiresTyping: true))
        #expect(MutationPolicy.decide(.exec(interactive: true), cluster: cluster(.production), origin: nil) == .confirm(requiresTyping: false))
    }

    // iOS answers: identical to the old `alwaysRequireTyping || (typeToConfirmOnProduction && env.requiresTypeToConfirm)`.
    @Test func requiresTypingMatchesTheShippedIOSRule() {
        for env in ClusterEnvironment.allCases {
            for always in [false, true] {
                for typeOnProd in [false, true] {
                    let legacy = always || (typeOnProd && env.requiresTypeToConfirm)
                    let new = MutationPolicy.requiresTyping(cluster: cluster(env), origin: nil, exemption: typeOnProd ? nil : .interactiveShell, alwaysRequireTyping: always)
                    #expect(new == legacy, "env \(env) always \(always) typeOnProd \(typeOnProd)")
                }
            }
        }
    }

    @Test func nonUIOriginsCannotBeExemptedOnProduction() {
        let prod = cluster(.production)
        for origin in [ChangeOrigin.firstMate(conversation: "c"), .beacon(client: "x"), .rigging(pack: "p")] {
            #expect(MutationPolicy.requiresTyping(cluster: prod, origin: origin, exemption: .interactiveShell, alwaysRequireTyping: false))
        }
        // The terminal origin IS the interactive pod shell case (decision 8/9): it keeps the button confirmation.
        #expect(!MutationPolicy.requiresTyping(cluster: prod, origin: .terminal(session: "s", reportedCommand: nil), exemption: .interactiveShell, alwaysRequireTyping: false))
        #expect(!MutationPolicy.requiresTyping(cluster: prod, origin: nil, exemption: .interactiveShell, alwaysRequireTyping: false))
    }

    @Test func nonProductionNeverTypesUnlessAlways() {
        let dev = cluster(.development)
        #expect(!MutationPolicy.requiresTyping(cluster: dev, origin: .firstMate(conversation: "c"), exemption: nil, alwaysRequireTyping: false))
        #expect(MutationPolicy.requiresTyping(cluster: dev, origin: nil, exemption: nil, alwaysRequireTyping: true))
    }

    @Test func changeOriginRoundTripsAndClassifies() throws {
        let all: [ChangeOrigin] = [.ui, .chartRoom, .tides, .survey, .firstMate(conversation: "c1"), .beacon(client: "cl"),
                                   .terminal(session: "s", reportedCommand: "kubectl get pods"), .rigging(pack: "cert-manager")]
        for o in all {
            let back = try JSONDecoder().decode(ChangeOrigin.self, from: JSONEncoder().encode(o))
            #expect(back == o)
        }
        #expect(all.filter(\.isNonUI).count == 4)
        #expect(ChangeOrigin?.none.orUI == .ui)
    }
}

@Suite("EnvironmentSuggester")
struct EnvironmentSuggesterTests {
    private func suggest(_ name: String? = nil, cluster: String? = nil, user: String? = nil, host: String? = nil, tags: [String: String] = [:]) -> EnvironmentSuggestion? {
        EnvironmentSuggester.suggest(SuggestionInput(contextName: name, clusterName: cluster, userName: user, serverHost: host, cloudTags: tags))
    }

    @Test(arguments: ["prod", "prd", "prod1", "prd02", "production", "live", "PROD", "eu-prod-1", "prod_eu", "arn:aws:eks:eu:123:cluster/prod", "admin@prod.example", "a/prod/b", "live.example"])
    func productionTokens(_ name: String) {
        #expect(suggest(name)?.environment == .production, "\(name)")
    }

    @Test(arguments: ["nonprod", "product", "prodx", "reprod", "preprod-1", "produce", "liveliness", "prodigy", "oliver"])
    func notProduction(_ name: String) {
        #expect(suggest(name)?.environment != .production, "\(name)")
    }

    @Test(arguments: ["stag", "stage", "staging", "stg", "uat", "preprod", "eu-stg-2", "UAT_cluster", "x.staging.y"])
    func stagingTokens(_ name: String) {
        #expect(suggest(name)?.environment == .staging, "\(name)")
    }

    @Test(arguments: ["kind-dev", "k3d-test", "minikube", "docker-desktop", "orbstack", "rancher-desktop", "Kind-foo"])
    func localNames(_ name: String) {
        let s = suggest(name)
        #expect(s?.environment == .development && s?.label == "Development (local)", "\(name)")
    }

    @Test(arguments: ["minikube-2", "my-minikube", "kindle", "docker-desktop-2"])
    func localNamesMustBeWhole(_ name: String) {
        #expect(suggest(name) == nil, "\(name)")
    }

    @Test(arguments: ["127.0.0.1", "::1", "localhost", "api.localhost", "LOCALHOST"])
    func localHosts(_ host: String) {
        #expect(suggest(host: host)?.label == "Development (local)", "\(host)")
    }

    @Test func otherHostsGiveNoSuggestion() {
        #expect(suggest(host: "10.0.0.5") == nil)
        #expect(suggest(host: "k8s.example.com") == nil)
        #expect(suggest("my-cluster", cluster: "c1", user: "bob") == nil)
    }

    @Test func precedenceIsProductionThenStagingThenLocal() {
        #expect(suggest("kind-prod")?.environment == .production)
        #expect(suggest("staging-prod")?.environment == .production)
        #expect(suggest("kind-staging")?.environment == .staging)
        #expect(suggest("minikube", host: "localhost")?.label == "Development (local)")
        #expect(suggest("dev", host: "localhost", tags: ["env": "prod"])?.environment == .production)
    }

    @Test func everyInputFieldIsConsulted() {
        #expect(suggest(cluster: "prod-eu")?.environment == .production)
        #expect(suggest(user: "prod-admin")?.environment == .production)
        #expect(suggest(host: "api.prod.example.com")?.environment == .production)
        #expect(suggest(host: "api.stg.example.com")?.environment == .staging)
    }

    @Test func cloudTagsAreConsultedForEnvEnvironmentAndStage() {
        #expect(suggest(tags: ["env": "production"])?.environment == .production)
        #expect(suggest(tags: ["environment": "prd"])?.environment == .production)
        #expect(suggest(tags: ["stage": "staging"])?.environment == .staging)
        #expect(suggest(tags: ["team": "prod"]) == nil)
        #expect(suggest(tags: ["env": "kind-x"]) == nil)
    }

    @Test func reasonsExplainTheMatch() throws {
        let s = try #require(suggest("eu-prod", host: "localhost"))
        #expect(s.environment == .production)
        #expect(s.reasons.contains { $0.contains("context name") && $0.contains("prod") })
    }

    @Test func localLabelIsNotANewEnumCase() {
        #expect(ClusterEnvironment.allCases.count == 4)
    }

    @Test func iosSuggestionIsUnchanged() {
        #expect(ClusterEnvironment.suggested(forName: "my-prod-cluster") == .production)
        #expect(ClusterEnvironment.suggested(forName: "minikube") == .personal)
        #expect(ClusterEnvironment.suggested(forName: "anything") == .development)
    }
}

@Suite("Seams: client, activity, ownership, Moorings")
struct SeamDefaultsTests {
    private struct BareClient {}

    @Test func demoListMetadataReturnsOnlyMetadata() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let list = try await client.listMetadata(kind: .pod, namespace: nil, labelSelector: nil, limit: 5)
        #expect(list.items.count == 5)
        #expect(list.continueToken != nil)
        #expect(list.items.allSatisfy { !$0.name.isEmpty })
        let all = try await client.listMetadata(kind: .namespace, namespace: nil, labelSelector: nil, limit: nil)
        #expect(all.continueToken == nil && !all.items.isEmpty)
    }

    @Test func demoProxyRequestIsGETOnly() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        await #expect(throws: KubeError.self) {
            _ = try await client.proxyRequest(method: "POST", namespace: "monitoring", service: "prometheus", port: "9090", path: "api/v1/query", query: [:], headers: [:], body: nil)
        }
    }

    @Test func noopActivityLogAcceptsEntries() {
        NoopActivityLog().record(ActivityEntry(verb: "patch", result: "ok"))
        let mem = InMemoryActivityLog()
        mem.record(ActivityEntry(cluster: "c", origin: .beacon(client: "x"), verb: "scale", object: "deployment/a", result: "ok"))
        #expect(mem.entries.count == 1 && mem.entries[0].origin == .beacon(client: "x"))
    }

    @Test func noOwnershipAnswersNil() async {
        #expect(await NoOwnership().owner(of: ["metadata": ["name": "x"]], cluster: "c") == nil)
    }

    @Test func mooringsSeamIsUnavailable() async {
        let adder = UnavailableMooringsSourceAdder()
        #expect(!adder.isAvailable)
        await #expect(throws: KubeError.self) { try await adder.addFileSource(URL(fileURLWithPath: "/tmp/x")) }
    }

    @Test func appGroupDefaultsAreUnchangedWithoutTheInfoKey() {
        #expect(AppGroup.identifier(in: Bundle(for: Probe.self)) == "group.com.ahmadrezaei.wheelhouse")
        #expect(AppGroup.defaultIdentifier == "group.com.ahmadrezaei.wheelhouse")
    }
    private final class Probe {}
}
