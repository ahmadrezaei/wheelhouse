import Foundation

/// Which GitOps tool manages an object, if any.
public struct GitOpsOwner: Hashable, Sendable {
    public enum Tool: String, Sendable { case flux, argoCD }
    public var tool: Tool
    /// The Flux Kustomization or HelmRelease, or the Argo CD Application.
    public var name: String
    public var namespace: String?

    public init(tool: Tool, name: String, namespace: String? = nil) {
        self.tool = tool
        self.name = name
        self.namespace = namespace
    }
}

/// The ownership seam (M9 provides the real detector). The editor review sheet and the Chart Room release row show an
/// ownership badge from this; until then `NoOwnership` answers nil and the slot is empty.
public protocol GitOpsOwnership: Sendable {
    /// `object` is the object's raw JSON (metadata labels and annotations decide).
    func owner(of object: JSONValue, cluster: ClusterID) async -> GitOpsOwner?
}

public struct NoOwnership: GitOpsOwnership {
    public init() {}
    public func owner(of object: JSONValue, cluster: ClusterID) async -> GitOpsOwner? { nil }
}
