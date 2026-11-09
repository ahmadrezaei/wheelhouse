import Testing
import Foundation
@testable import WheelhouseKit

@Suite("Vulnerabilities: image inventory")
struct ImageInventoryTests {
    private func pod(_ name: String, ns: String = "shop", phase: String = "Running", owner: (String, String)? = nil, image: String, imageID: String,
                     secrets: [String] = []) -> JSONValue {
        var meta: JSONValue = ["name": .string(name), "namespace": .string(ns)]
        if let owner { meta["ownerReferences"] = [["kind": .string(owner.0), "name": .string(owner.1), "controller": true]] }
        var spec: JSONValue = [:]
        if !secrets.isEmpty { spec["imagePullSecrets"] = .array(secrets.map { ["name": .string($0)] }) }
        return ["metadata": meta, "spec": spec,
                "status": ["phase": .string(phase), "containerStatuses": [["image": .string(image), "imageID": .string(imageID)]]]]
    }

    @Test func buildsADeduplicatedSetWithWorkloads() {
        let digest = "sha256:" + String(repeating: "c", count: 64)
        let pods = [
            pod("web-7d9f8c6b5d-x1", owner: ("ReplicaSet", "web-7d9f8c6b5d"), image: "registry.example.com/web:1",
                imageID: "docker-pullable://registry.example.com/web@\(digest)", secrets: ["regcred"]),
            pod("web-7d9f8c6b5d-x2", owner: ("ReplicaSet", "web-7d9f8c6b5d"), image: "registry.example.com/web:1",
                imageID: "docker-pullable://registry.example.com/web@\(digest)"),
            pod("tool", image: "registry.example.com/tool:3", imageID: ""),
            pod("done", phase: "Succeeded", image: "registry.example.com/job:1", imageID: ""),
        ]
        let uses = ImageInventory.build(pods: pods, clusterID: "c1")
        #expect(uses.count == 2)
        #expect(uses[0].reference.digest == digest && !uses[0].reference.isMutable)
        #expect(uses[0].workloads == [TrivyOperator.WorkloadKey(namespace: "shop", kind: "Deployment", name: "web")])
        #expect(uses[0].pullSecrets == [PullSecretRef(namespace: "shop", name: "regcred")])
        #expect(uses[1].reference.isMutable && uses[1].workloads.first?.kind == "Pod")
    }

    @Test func theClusterArchitectureIsTheMostCommonNodeArchitecture() {
        func node(_ arch: String) -> JSONValue { ["status": ["nodeInfo": ["architecture": .string(arch)]]] }
        #expect(ImageInventory.dominantArchitecture(nodes: [node("arm64"), node("amd64"), node("amd64")]) == "amd64")
        #expect(ImageInventory.dominantArchitecture(nodes: [node("arm64")]) == "arm64")
        #expect(ImageInventory.dominantArchitecture(nodes: [node("s390x")]) == nil)
        #expect(ImageInventory.dominantArchitecture(nodes: []) == nil)
    }

    @Test func mergesAcrossClusters() throws {
        let ref = try #require(ImageReference("registry.example.com/web:1"))
        let w = TrivyOperator.WorkloadKey(namespace: "n", kind: "Deployment", name: "w")
        let merged = ImageInventory.merge([ImageUse(reference: ref, clusterID: "a", workloads: [w], pullSecrets: []),
                                           ImageUse(reference: ref, clusterID: "b", workloads: [w], pullSecrets: [])])
        #expect(merged.count == 1 && merged[0].clusters == ["a", "b"] && merged[0].workloads["b"] == [w])
    }
}
