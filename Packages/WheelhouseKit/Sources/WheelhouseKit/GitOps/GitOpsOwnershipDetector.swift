import Foundation

/// The real ownership detector (ARCHITECTURE-MAC section 7). It reads only the object itself:
///
/// 1. Flux labels `kustomize.toolkit.fluxcd.io/name` and `helm.toolkit.fluxcd.io/name` (with their `/namespace`);
/// 2. Argo CD's `argocd.argoproj.io/instance` label, or the tracking-id annotation `argocd.argoproj.io/tracking-id`
///    (`<app>:<group>/<kind>:<namespace>/<name>`; an application outside the Argo namespace is prefixed `<namespace>_`);
/// 3. failing both, the field managers `kustomize-controller`, `helm-controller` and `argocd-controller`
///    (or `argocd-application-controller`), which name the tool but not the owner.
public struct GitOpsOwnershipDetector: GitOpsOwnership {
    public init() {}

    public func owner(of object: JSONValue, cluster: ClusterID) async -> GitOpsOwner? { Self.detect(object) }

    static let fluxManagers: [String: String] = ["kustomize-controller": "Kustomization", "helm-controller": "HelmRelease"]
    static let argoManagers: Set<String> = ["argocd-controller", "argocd-application-controller"]

    public static func detect(_ object: JSONValue) -> GitOpsOwner? {
        let labels = object.value(at: "metadata.labels")?.objectValue ?? [:]
        let annotations = object.value(at: "metadata.annotations")?.objectValue ?? [:]
        func label(_ k: String) -> String? { labels[k]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }

        if let name = label("kustomize.toolkit.fluxcd.io/name") {
            return GitOpsOwner(tool: .flux, name: name, namespace: label("kustomize.toolkit.fluxcd.io/namespace"))
        }
        if let name = label("helm.toolkit.fluxcd.io/name") {
            return GitOpsOwner(tool: .flux, name: name, namespace: label("helm.toolkit.fluxcd.io/namespace"))
        }
        if let tracking = annotations["argocd.argoproj.io/tracking-id"]?.stringValue, let owner = argoOwner(trackingID: tracking) {
            return owner
        }
        if let name = label("argocd.argoproj.io/instance") {
            return GitOpsOwner(tool: .argoCD, name: name)
        }
        let managers = (object.value(at: "metadata.managedFields")?.arrayValue ?? []).compactMap { $0["manager"]?.stringValue }
        if let m = managers.first(where: { fluxManagers[$0] != nil }) { return GitOpsOwner(tool: .flux, name: m) }
        if let m = managers.first(where: { argoManagers.contains($0) }) { return GitOpsOwner(tool: .argoCD, name: m) }
        return nil
    }

    /// `my-app:apps/Deployment:shop/web` or `argocd-team_my-app:apps/Deployment:shop/web`.
    static func argoOwner(trackingID: String) -> GitOpsOwner? {
        guard let head = trackingID.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).first, !head.isEmpty else { return nil }
        let parts = head.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { return GitOpsOwner(tool: .argoCD, name: parts[1], namespace: parts[0]) }
        return GitOpsOwner(tool: .argoCD, name: String(head))
    }

    /// The Flux HelmRelease that manages a Helm release (the Chart Room release row), from the cluster's HelmRelease objects.
    public static func owner(ofRelease releaseName: String, namespace: String, among apps: [GitOpsApp]) -> GitOpsOwner? {
        for app in apps where app.flavor == .fluxHelmRelease {
            let name = app.raw.value(at: "spec.releaseName")?.stringValue ?? app.name
            let ns = app.raw.value(at: "spec.targetNamespace")?.stringValue ?? app.raw.value(at: "spec.storageNamespace")?.stringValue ?? app.namespace
            if name == releaseName, ns == namespace { return GitOpsOwner(tool: .flux, name: app.name, namespace: app.namespace) }
        }
        return nil
    }
}
