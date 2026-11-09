#if os(macOS)
import Foundation
import WheelhouseKit

/// Builds the kubeconfig entries for clusters Landfall adds (ARCHITECTURE-MAC §8.1): server, CA and an `exec` stanza. Never a secret.
public enum LandfallKubeconfig {
    /// One entry set. The cluster, user and context share the vendor-convention name (`arn:aws:eks:…`, `gke_…`, the AKS name).
    public static func entries(for clusters: [CloudCluster]) -> KubeconfigEntries {
        var out = KubeconfigEntries()
        for c in clusters {
            out.clusters.append(.init(name: c.contextName, cluster: .init(server: c.endpoint, certificateAuthorityData: c.caData)))
            out.users.append(.init(name: c.contextName, user: .init(exec: exec(for: c))))
            out.contexts.append(.init(name: c.contextName, context: .init(cluster: c.contextName, user: c.contextName)))
        }
        return out
    }

    static func exec(for c: CloudCluster) -> KubeconfigEntries.NamedUser.User.Exec {
        let api = "client.authentication.k8s.io/v1beta1"
        switch c.provider {
        case .aws:
            // The same shape `aws eks update-kubeconfig` writes.
            return .init(apiVersion: api, command: "aws", args: ["--region", c.region, "eks", "get-token", "--cluster-name", c.name, "--output", "json"],
                         env: [.init(name: "AWS_PROFILE", value: c.accountID)])
        case .gcp:
            return .init(apiVersion: api, command: "gke-gcloud-auth-plugin", args: [],
                         installHint: "Install gke-gcloud-auth-plugin for use with kubectl by following https://cloud.google.com/kubernetes-engine/docs/how-to/cluster-access-for-kubectl#install_plugin",
                         provideClusterInfo: true, interactiveMode: "IfAvailable")
        case .azure:
            return .init(apiVersion: api, command: "kubelogin", args: ["get-token", "--login", "azurecli", "--server-id", AzureCLI.serverID],
                         installHint: "Install kubelogin: brew install Azure/kubelogin/kubelogin", provideClusterInfo: false)
        }
    }
}

/// Where the optional "Also merge into ~/.kube/config" writes.
public enum LandfallMergeTarget {
    /// `~/.kube/config` of `gate.home`. Throws while the gate is active: development builds never write it.
    public static func resolve(gate: DevSafetyPolicy) throws -> URL {
        try gate.require(gate.allowsKubeconfigWrites, feature: "Merging into ~/.kube/config")
        return gate.home.appending(path: ".kube/config")
    }
}
#endif
