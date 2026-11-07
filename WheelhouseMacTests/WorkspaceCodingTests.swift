import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

/// Golden JSON per destination case (ARCHITECTURE-MAC §12.2). These strings are the on-disk format of `workspace.json`.
/// A failing test here means a frozen payload type or case changed: that is not allowed. Later milestones may only ADD
/// OPTIONAL fields (add them to a sample only with a NEW golden line, never by editing an existing one).
@Suite("WorkspaceCodingTests")
struct WorkspaceCodingTests {
    static let golden: [String: String] = [
        "route": #"{"case":"route","payload":{"resourceDetail":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Deployments","group":"apps","kind":"Deployment","namespaced":true,"plural":"deployments","section":"workloads","symbol":"square.stack.3d.up","version":"v1"},"name":"payments-api","namespace":"shop"}}}}"#,
        "deckTerminal": #"{"case":"deckTerminal","payload":{"clusterID":"kc-0123456789abcdef","namespace":"shop","shell":"/bin/zsh","startDirectory":"/Users/x/work","title":"build"}}"#,
        "chartRoom": #"{"case":"chartRoom","payload":{"clusterID":"kc-0123456789abcdef","section":"releases"}}"#,
        "helmRelease": #"{"case":"helmRelease","payload":{"clusterID":"kc-0123456789abcdef","name":"payments","namespace":"shop","revision":7}}"#,
        "helmInstall": #"{"case":"helmInstall","payload":{"name":"nginx","ociReference":"oci://registry.example.com/charts/nginx","repository":"bitnami","version":"18.2.0"}}"#,
        "survey": #"{"case":"survey","payload":{"clusterID":"kc-0123456789abcdef","namespace":"shop","tab":"vulnerabilities"}}"#,
        "surveyFinding": #"{"case":"surveyFinding","payload":"WH-A001:clusterrolebinding/admin"}"#,
        "tides": #"{"case":"tides","payload":{"clusterID":"kc-0123456789abcdef","tool":"flux"}}"#,
        "gitopsApp": #"{"case":"gitopsApp","payload":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Application","group":"argoproj.io","kind":"Application","namespaced":true,"plural":"applications","section":"custom","symbol":"cube.transparent","version":"v1alpha1"},"name":"shop","namespace":"argocd"}}"#,
        "landfall": #"{"case":"landfall"}"#,
        "firstMate": #"{"case":"firstMate","payload":"conv-1"}"#,
        "moorings": #"{"case":"moorings"}"#,
        "activity": #"{"case":"activity"}"#,
        "station": #"{"case":"station","payload":"station-1"}"#,
        "riggingView": #"{"case":"riggingView","payload":{"clusterID":"kc-0123456789abcdef","namespace":"payments","pack":"cert-manager","view":"certificates"}}"#,
    ]

    /// One golden line per `Route` case (all 16), pinning how the iOS routes are stored inside a pane stack.
    static let routeGolden: [String: String] = [
        "fleet": #"{"fleet":{}}"#,
        "alerts": #"{"alerts":{}}"#,
        "cluster": #"{"cluster":{"_0":"kc-0123456789abcdef"}}"#,
        "resourceSections": #"{"resourceSections":{"_0":"kc-0123456789abcdef"}}"#,
        "resourceList": #"{"resourceList":{"_0":"kc-0123456789abcdef","_1":{"displayName":"Deployments","group":"apps","kind":"Deployment","namespaced":true,"plural":"deployments","section":"workloads","symbol":"square.stack.3d.up","version":"v1"},"namespace":"shop"}}"#,
        "resourceDetail": #"{"resourceDetail":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Pods","group":"","kind":"Pod","namespaced":true,"plural":"pods","section":"workloads","symbol":"cube","version":"v1"},"name":"payments-api-0","namespace":"shop"}}}"#,
        "yaml": #"{"yaml":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Pods","group":"","kind":"Pod","namespaced":true,"plural":"pods","section":"workloads","symbol":"cube","version":"v1"},"name":"payments-api-0","namespace":"shop"}}}"#,
        "createYAML": #"{"createYAML":{"_0":"kc-0123456789abcdef","namespace":"shop"}}"#,
        "logs": #"{"logs":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Pods","group":"","kind":"Pod","namespaced":true,"plural":"pods","section":"workloads","symbol":"cube","version":"v1"},"name":"payments-api-0","namespace":"shop"},"container":"app","previous":true}}"#,
        "shell": #"{"shell":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Pods","group":"","kind":"Pod","namespaced":true,"plural":"pods","section":"workloads","symbol":"cube","version":"v1"},"name":"payments-api-0","namespace":"shop"},"container":"app"}}"#,
        "portForward": #"{"portForward":{"_0":{"clusterID":"kc-0123456789abcdef","kind":{"displayName":"Pods","group":"","kind":"Pod","namespaced":true,"plural":"pods","section":"workloads","symbol":"cube","version":"v1"},"name":"payments-api-0","namespace":"shop"}}}"#,
        "sessions": #"{"sessions":{}}"#,
        "search": #"{"search":{"query":"payments"}}"#,
        "settings": #"{"settings":{}}"#,
        "addCluster": #"{"addCluster":{}}"#,
        "importKubeconfig": #"{"importKubeconfig":{}}"#,
    ]

    private var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return e }

    @Test func everyCaseHasASampleAndAGoldenLine() {
        #expect(WorkspaceSamples.samples.map(\.name) == WorkspaceDestination.allCaseNames)
        #expect(Set(Self.golden.keys) == Set(WorkspaceDestination.allCaseNames))
        #expect(WorkspaceSamples.samples.map { $0.value.caseName } == WorkspaceDestination.allCaseNames)
    }

    @Test(arguments: WorkspaceSamples.samples.map(\.name))
    func encodingMatchesTheGoldenJSON(_ name: String) throws {
        let sample = try #require(WorkspaceSamples.samples.first { $0.name == name })
        let json = String(decoding: try encoder.encode(sample.value), as: UTF8.self)
        #expect(json == Self.golden[name])
    }

    @Test(arguments: WorkspaceSamples.samples.map(\.name))
    func goldenJSONDecodesToTheSample(_ name: String) throws {
        let sample = try #require(WorkspaceSamples.samples.first { $0.name == name })
        let decoded = try JSONDecoder().decode(WorkspaceDestination.self, from: Data(try #require(Self.golden[name]).utf8))
        #expect(decoded == sample.value)
    }

    @Test func everyRouteCaseHasASampleAndAGoldenLine() {
        #expect(WorkspaceSamples.routeSamples.count == 16)
        #expect(Set(WorkspaceSamples.routeSamples.map(\.name)) == Set(Self.routeGolden.keys))
        #expect(WorkspaceSamples.routeSamples.allSatisfy { WorkspaceSamples.routeName($0.value) == $0.name })
    }

    @Test(arguments: WorkspaceSamples.routeSamples.map(\.name))
    func routeEncodingMatchesTheGoldenJSONAndDecodesBack(_ name: String) throws {
        let sample = try #require(WorkspaceSamples.routeSamples.first { $0.name == name })
        let json = String(decoding: try encoder.encode(WorkspaceDestination.route(sample.value)), as: UTF8.self)
        #expect(json == #"{"case":"route","payload":"# + (Self.routeGolden[name] ?? "MISSING") + "}")
    }

    @Test func payloadEnumRawValuesArePinned() {
        #expect(ChartRoomSection.allCases.map(\.rawValue) == ["releases", "charts", "repositories"])
        #expect(SurveyTab.allCases.map(\.rawValue) == ["overview", "vulnerabilities", "access", "workload"])
        #expect([TidesTool.argoCD, .flux].map(\.rawValue) == ["argoCD", "flux"])
    }

    @Test func resourceKindDecodesFromItsIdentityAlone() throws {
        // Cosmetic fields (symbol, display name, section) may change or vanish without orphaning a saved pane.
        let json = #"{"case":"gitopsApp","payload":{"clusterID":"c","kind":{"group":"apps","kind":"Deployment","namespaced":true,"plural":"deployments","version":"v1"},"name":"shop","namespace":"s"}}"#
        guard case .gitopsApp(let ref) = try JSONDecoder().decode(WorkspaceDestination.self, from: Data(json.utf8)) else { Issue.record("wrong case"); return }
        #expect(ref.kind.id == "apps/v1/deployments" && ref.kind.displayName == "Deployment")
    }

    @Test func aStackOfDestinationsRoundTrips() throws {
        let stack = WorkspaceSamples.samples.map(\.value)
        let back = try JSONDecoder().decode([WorkspaceDestination].self, from: try encoder.encode(stack))
        #expect(back == stack)
    }

    @Test func unknownCaseFromANewerBuildFailsToDecode() {
        let json = #"{"case":"holodeck","payload":{"x":1}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceDestination.self, from: Data(json.utf8)) }
    }

    @Test func payloadThatNoLongerDecodesFails() {
        let json = #"{"case":"helmRelease","payload":{"clusterID":"c"}}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(WorkspaceDestination.self, from: Data(json.utf8)) }
    }

    @Test func laterOptionalFieldsAreIgnoredByTheFrozenShape() throws {
        // A newer build may add optional fields; this build must still decode the pane.
        let json = #"{"case":"deckTerminal","payload":{"clusterID":"c","futureOption":true}}"#
        let d = try JSONDecoder().decode(WorkspaceDestination.self, from: Data(json.utf8))
        #expect(d == .deckTerminal(TerminalSpec(clusterID: "c")))
    }

    @Test func optionalFieldsAreOmittedWhenNil() throws {
        let json = String(decoding: try encoder.encode(WorkspaceDestination.deckTerminal(TerminalSpec())), as: UTF8.self)
        #expect(json == #"{"case":"deckTerminal","payload":{}}"#)
    }

    @Test func destinationsAreHashableForPaneLookup() {
        let all = Set(WorkspaceSamples.samples.map(\.value))
        #expect(all.count == WorkspaceSamples.samples.count)
    }
}
