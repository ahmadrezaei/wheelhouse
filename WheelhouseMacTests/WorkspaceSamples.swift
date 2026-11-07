import Foundation
import WheelhouseKit
@testable import WheelhouseMac

/// One sample per `WorkspaceDestination` case. The golden JSON in `WorkspaceCodingTests` pins how each one is encoded.
enum WorkspaceSamples {
    static let cluster = "kc-0123456789abcdef"

    static let samples: [(name: String, value: WorkspaceDestination)] = [
        ("route", .route(.resourceDetail(ResourceRef(clusterID: cluster, kind: .deployment, namespace: "shop", name: "payments-api")))),
        ("deckTerminal", .deckTerminal(TerminalSpec(clusterID: cluster, namespace: "shop", shell: "/bin/zsh", startDirectory: "/Users/x/work", title: "build"))),
        ("chartRoom", .chartRoom(cluster, .releases)),
        ("helmRelease", .helmRelease(HelmReleaseRef(clusterID: cluster, namespace: "shop", name: "payments", revision: 7))),
        ("helmInstall", .helmInstall(ChartRef(repository: "bitnami", name: "nginx", version: "18.2.0", ociReference: "oci://registry.example.com/charts/nginx"))),
        ("survey", .survey(SurveyScope(clusterID: cluster, tab: .vulnerabilities, namespace: "shop"))),
        ("surveyFinding", .surveyFinding("WH-A001:clusterrolebinding/admin")),
        ("tides", .tides(TidesScope(clusterID: cluster, tool: .flux))),
        ("gitopsApp", .gitopsApp(ResourceRef(clusterID: cluster, kind: .custom(group: "argoproj.io", version: "v1alpha1", kind: "Application", plural: "applications", namespaced: true), namespace: "argocd", name: "shop"))),
        ("landfall", .landfall),
        ("firstMate", .firstMate("conv-1")),
        ("moorings", .moorings),
        ("activity", .activity),
        ("station", .station("station-1")),
        ("riggingView", .riggingView(RiggingViewRef(pack: "cert-manager", view: "certificates", clusterID: cluster, namespace: "payments"))),
    ]

    /// One sample per `Route` case (all 16). `routeName` is an exhaustive switch, so a new `Route` case fails to compile here until
    /// it gets a sample and a golden line.
    static let ref = ResourceRef(clusterID: cluster, kind: .pod, namespace: "shop", name: "payments-api-0")
    static let routeSamples: [(name: String, value: Route)] = [
        ("fleet", .fleet), ("alerts", .alerts), ("cluster", .cluster(cluster)), ("resourceSections", .resourceSections(cluster)),
        ("resourceList", .resourceList(cluster, .deployment, namespace: "shop")), ("resourceDetail", .resourceDetail(ref)),
        ("yaml", .yaml(ref)), ("createYAML", .createYAML(cluster, namespace: "shop")),
        ("logs", .logs(ref, container: "app", previous: true)), ("shell", .shell(ref, container: "app")), ("portForward", .portForward(ref)),
        ("sessions", .sessions), ("search", .search(query: "payments")), ("settings", .settings), ("addCluster", .addCluster),
        ("importKubeconfig", .importKubeconfig),
    ]

    static func routeName(_ r: Route) -> String {
        switch r {
        case .fleet: "fleet"
        case .alerts: "alerts"
        case .cluster: "cluster"
        case .resourceSections: "resourceSections"
        case .resourceList: "resourceList"
        case .resourceDetail: "resourceDetail"
        case .yaml: "yaml"
        case .createYAML: "createYAML"
        case .logs: "logs"
        case .shell: "shell"
        case .portForward: "portForward"
        case .sessions: "sessions"
        case .search: "search"
        case .settings: "settings"
        case .addCluster: "addCluster"
        case .importKubeconfig: "importKubeconfig"
        }
    }
}
