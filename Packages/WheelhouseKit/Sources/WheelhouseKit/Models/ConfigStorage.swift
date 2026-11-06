import Foundation

public struct ConfigMap: KubeObject {
    public static var resourceKind: ResourceKind { .configMap }
    public var metadata: ObjectMeta
    @Lenient public var data: [String: String]
    @Lenient public var binaryData: [String: String]
    public var immutable: Bool?
}

public struct Secret: KubeObject {
    public static var resourceKind: ResourceKind { .secret }
    public var metadata: ObjectMeta
    public var type: String?
    /// Base64-encoded values. Never log or persist these.
    @Lenient public var data: [String: String]
    public var immutable: Bool?

    /// Decodes a value, returning nil if the key is missing or not valid base64.
    public func decodedData(for key: String) -> Data? { data[key].flatMap { Data(base64Encoded: $0) } }
    public func decodedString(for key: String) -> String? { decodedData(for: key).flatMap { String(data: $0, encoding: .utf8) } }
}

public struct PersistentVolume: KubeObject {
    public static var resourceKind: ResourceKind { .persistentVolume }
    public struct Spec: Codable, Hashable, Sendable {
        public var capacity: [String: Quantity]?
        public var accessModes: [String]?
        public var persistentVolumeReclaimPolicy: String?
        public var storageClassName: String?
        public var volumeMode: String?
        public var claimRef: ObjectReference?
        public var nodeAffinity: JSONValue?
    }
    public struct Status: Codable, Hashable, Sendable { public var phase: String?; public var message: String?; public var reason: String? }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
}

public struct PersistentVolumeClaim: KubeObject {
    public static var resourceKind: ResourceKind { .persistentVolumeClaim }
    public struct Spec: Codable, Hashable, Sendable {
        public var accessModes: [String]?
        public var storageClassName: String?
        public var volumeName: String?
        public var volumeMode: String?
        public var resources: ResourceRequirements?
    }
    public struct Status: Codable, Hashable, Sendable {
        public var phase: String?
        public var capacity: [String: Quantity]?
        public var accessModes: [String]?
    }
    public var metadata: ObjectMeta
    public var spec: Spec
    public var status: Status?
}

public struct StorageClass: KubeObject {
    public static var resourceKind: ResourceKind { .storageClass }
    public var metadata: ObjectMeta
    public var provisioner: String
    public var reclaimPolicy: String?
    public var volumeBindingMode: String?
    public var allowVolumeExpansion: Bool?
    @Lenient public var parameters: [String: String]
    public var isDefault: Bool {
        metadata.annotations["storageclass.kubernetes.io/is-default-class"] == "true"
            || metadata.annotations["storageclass.beta.kubernetes.io/is-default-class"] == "true"
    }
}
