import Foundation

/// Which GitOps kinds a cluster serves, found by CRD discovery (ARCHITECTURE-MAC section 7).
///
/// Discovery keeps only each group's preferred version, so "if several versions are served, the preferred one is used" holds by
/// construction. A version this build has never seen is still read: objects are views over `JSONValue` with known fields by path.
public struct GitOpsDetection: Hashable, Sendable {
    public var kustomizations: ResourceKind?
    public var helmReleases: ResourceKind?
    public var gitRepositories: ResourceKind?
    public var ociRepositories: ResourceKind?
    public var helmRepositories: ResourceKind?
    public var helmCharts: ResourceKind?
    public var buckets: ResourceKind?
    public var applications: ResourceKind?
    public var applicationSets: ResourceKind?
    public var appProjects: ResourceKind?
    /// The Flux notification and image-automation groups are served (read-only; Tides does not list them yet).
    public var fluxNotification = false
    public var fluxImage = false

    public init() {}

    public var hasFlux: Bool { kustomizations != nil || helmReleases != nil }
    public var hasArgo: Bool { applications != nil }
    /// Tides appears in a cluster's sidebar only when at least one tool is present.
    public var isPresent: Bool { hasFlux || hasArgo }

    /// The Flux source kinds this cluster serves, in display order.
    public var fluxSources: [ResourceKind] { [gitRepositories, ociRepositories, helmRepositories, helmCharts, buckets].compactMap { $0 } }

    /// The kinds listed in the Overview (everything that is an "app" rather than a source).
    public var appKinds: [ResourceKind] { [kustomizations, helmReleases, applications].compactMap { $0 } }

    /// The source kind a `sourceRef.kind` names.
    public func sourceKind(named kind: String) -> ResourceKind? {
        fluxSources.first { $0.kind == kind }
    }

    public static let fluxGroups = ["kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io", "source.toolkit.fluxcd.io",
                                    "notification.toolkit.fluxcd.io", "image.toolkit.fluxcd.io"]
    public static let argoGroup = "argoproj.io"

    public static func detect(_ info: DiscoveryInfo?) -> GitOpsDetection {
        var d = GitOpsDetection()
        guard let info else { return d }
        func find(_ group: String, _ kind: String) -> ResourceKind? {
            guard let r = info.topLevel.first(where: { ($0.group ?? "") == group && $0.kind == kind && $0.verbs.contains("list") }),
                  let version = r.version else { return nil }
            return .custom(group: group, version: version, kind: r.kind, plural: r.name, namespaced: r.namespaced)
        }
        d.kustomizations = find("kustomize.toolkit.fluxcd.io", "Kustomization")
        d.helmReleases = find("helm.toolkit.fluxcd.io", "HelmRelease")
        d.gitRepositories = find("source.toolkit.fluxcd.io", "GitRepository")
        d.ociRepositories = find("source.toolkit.fluxcd.io", "OCIRepository")
        d.helmRepositories = find("source.toolkit.fluxcd.io", "HelmRepository")
        d.helmCharts = find("source.toolkit.fluxcd.io", "HelmChart")
        d.buckets = find("source.toolkit.fluxcd.io", "Bucket")
        d.applications = find(argoGroup, "Application")
        d.applicationSets = find(argoGroup, "ApplicationSet")
        d.appProjects = find(argoGroup, "AppProject")
        let groups = Set(info.topLevel.compactMap(\.group))
        d.fluxNotification = groups.contains("notification.toolkit.fluxcd.io")
        d.fluxImage = groups.contains("image.toolkit.fluxcd.io")
        return d
    }
}
