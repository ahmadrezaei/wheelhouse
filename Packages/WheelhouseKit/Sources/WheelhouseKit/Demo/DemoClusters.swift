import Foundation

/// Composes the object set for each demo cluster.
enum DemoClusters {
    struct Profile {
        var objects: [String: [JSONValue]]
        var nodeCPU: Double
        var nodeMemGi: Double
        var nodeCount: Int
        var hasMetricsServer: Bool
        var hasPrometheus: Bool
        var reachable: Bool
    }

    static func profile(for config: ClusterConfig, now: Date = Date()) -> Profile {
        switch config.id {
        case DemoFleet.prodID: return prod(now: now)
        case DemoFleet.stagingID: return staging(now: now)
        case DemoFleet.homelabID: return homelab(now: now)
        default: return Profile(objects: [:], nodeCPU: 0, nodeMemGi: 0, nodeCount: 0, hasMetricsServer: false, hasPrometheus: false, reachable: false)
        }
    }

    // MARK: prod-eu-west (critical: NotReady node, CrashLoop OOM, Pending pod, failed Job)

    static func prod(now: Date) -> Profile {
        var b = DemoDataBuilder(clusterName: "prod-eu-west", now: now)
        let zones = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
        for i in 0..<8 {
            let ready = i != 6
            b.addNode("ip-10-2-22-\(61 + i * 4).eu-west-1.compute.internal", cpu: 8, memGi: 32, instance: "m6i.2xlarge", zone: zones[i % 3], pool: i < 6 ? "general" : "memory", ready: ready, cordoned: i == 7)
        }
        for ns in ["payments", "checkout", "platform", "monitoring", "ingress-nginx", "kube-system", "default"] { b.addNamespace(ns) }
        let reg = "registry.example.com"
        b.addWorkload(.init(name: "payments-api", ns: "payments", replicas: 3, image: "\(reg)/payments-api:3.8.2", cpuRequest: "500m", memRequest: "256Mi", memLimit: "256Mi", states: [.crashLoopOOM]))
        b.addWorkload(.init(name: "payments-worker", ns: "payments", replicas: 2, image: "\(reg)/payments-worker:3.8.2", memRequest: "512Mi", memLimit: "1Gi"))
        b.addWorkload(.init(name: "checkout-web", ns: "checkout", replicas: 4, image: "\(reg)/checkout-web:12.1.0", cpuRequest: "200m"))
        b.addWorkload(.init(name: "checkout-api", ns: "checkout", replicas: 3, image: "\(reg)/checkout-api:12.1.0", cpuRequest: "400m", memRequest: "512Mi", memLimit: "1Gi"))
        b.addWorkload(.init(name: "search-indexer", ns: "platform", replicas: 1, image: "\(reg)/search-indexer:1.9.0", cpuRequest: "2", memRequest: "24Gi", memLimit: "28Gi",
                            states: [.pending("0/8 nodes are available: 1 node(s) had untolerated taint {node.kubernetes.io/unreachable: }, 1 node(s) were unschedulable, 6 Insufficient memory. preemption: 0/8 nodes are available: 8 No preemption victims found for incoming pod.")]))
        b.addWorkload(.init(name: "auth-service", ns: "platform", replicas: 3, image: "\(reg)/auth:5.2.0", cpuRequest: "300m"))
        b.addWorkload(.init(name: "ingress-nginx-controller", ns: "ingress-nginx", replicas: 2, image: "registry.k8s.io/ingress-nginx/controller:v1.11.3", port: 443))
        b.addWorkload(.init(name: "coredns", ns: "kube-system", replicas: 2, image: "registry.k8s.io/coredns/coredns:v1.11.3", cpuRequest: "100m", memRequest: "70Mi", memLimit: "170Mi", port: 53))
        b.addWorkload(.init(name: "grafana", ns: "monitoring", replicas: 1, image: "grafana/grafana:11.3.0", port: 3000))
        b.addWorkload(.init(name: "prometheus-k8s", ns: "monitoring", replicas: 2, image: "quay.io/prometheus/prometheus:v2.55.1", cpuRequest: "1", memRequest: "4Gi", memLimit: "6Gi", port: 9090, kind: .statefulSet))
        b.addWorkload(.init(name: "node-exporter", ns: "monitoring", replicas: 8, image: "quay.io/prometheus/node-exporter:v1.8.2", cpuRequest: "50m", memRequest: "64Mi", memLimit: "128Mi", port: 9100, kind: .daemonSet))
        b.addWorkload(.init(name: "kube-proxy", ns: "kube-system", replicas: 8, image: "registry.k8s.io/kube-proxy:v1.31.4", cpuRequest: "100m", memRequest: "64Mi", memLimit: "128Mi", port: 10249, kind: .daemonSet))
        b.addService("payments-api", ns: "payments", port: 80, targetPort: 8080)
        b.addService("checkout-web", ns: "checkout", port: 80, targetPort: 8080, type: "LoadBalancer", lb: "a1b2c3.elb.eu-west-1.amazonaws.com")
        b.addService("grafana", ns: "monitoring", port: 3000)
        b.addService("prometheus-operated", ns: "monitoring", port: 9090)
        b.addIngress("checkout", ns: "checkout", host: "shop.example.com", service: "checkout-web", port: 80)
        b.addConfigMap("payments-config", ns: "payments", data: ["LOG_LEVEL": "info", "FEATURE_FLAGS": "{\"newCheckout\":true,\"retryV2\":false}", "app.yaml": "server:\n  port: 8080\n  timeout: 30s\n"])
        b.addSecret("payments-db", ns: "payments", keys: ["username", "password", "host"])
        b.addSecret("checkout-tls", ns: "checkout", type: "kubernetes.io/tls", keys: ["tls.crt", "tls.key"])
        b.addPVC("prometheus-data-prometheus-k8s-0", ns: "monitoring", size: "100Gi")
        b.addPVC("search-index-data", ns: "platform", size: "500Gi", phase: "Pending")
        b.addCronJob("nightly-report", ns: "payments", schedule: "0 2 * * *")
        b.addCronJob("cleanup-sessions", ns: "platform", schedule: "*/30 * * * *")
        b.addJob("nightly-report-28812340", ns: "payments", failed: true, ago: 3600 * 5)
        b.addJob("nightly-report-28811900", ns: "payments", failed: false, ago: 3600 * 29)
        let crashPod = (b.objects[ResourceKind.pod.id] ?? []).first { $0.value(at: "metadata.name")?.stringValue?.hasPrefix("payments-api") == true && $0.value(at: "status.containerStatuses")?[0]?["restartCount"]?.intValue == 14 }
        let crashName = crashPod?.value(at: "metadata.name")?.stringValue ?? "payments-api-0"
        b.addEvent(ns: "payments", object: ("Pod", crashName), type: "Warning", reason: "BackOff", message: "Back-off restarting failed container payments-api in pod \(crashName)", count: 142, ago: 45)
        b.addEvent(ns: "payments", object: ("Pod", crashName), type: "Warning", reason: "OOMKilling", message: "Memory cgroup out of memory: Killed process 28412 (java) total-vm:3421056kB", count: 14, ago: 70)
        b.addEvent(ns: "platform", object: ("Pod", "search-indexer-0"), type: "Warning", reason: "FailedScheduling", message: "0/8 nodes are available: 6 Insufficient memory, 1 node(s) were unschedulable.", count: 31, ago: 120)
        b.addEvent(ns: "default", object: ("Node", "ip-10-2-22-85.eu-west-1.compute.internal"), type: "Warning", reason: "NodeNotReady", message: "Node ip-10-2-22-85 status is now: NodeNotReady", count: 1, ago: 17 * 60)
        b.addEvent(ns: "payments", object: ("Job", "nightly-report-28812340"), type: "Warning", reason: "BackoffLimitExceeded", message: "Job has reached the specified backoff limit", count: 1, ago: 3600 * 5)
        b.addEvent(ns: "checkout", object: ("Deployment", "checkout-web"), type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set checkout-web to 4", count: 1, ago: 3600 * 8)
        addCRDs(&b, includeCerts: true)
        b.addStaticObjects(namespaces: ["payments", "checkout", "platform"])
        return Profile(objects: b.objects, nodeCPU: 8, nodeMemGi: 32, nodeCount: 8, hasMetricsServer: true, hasPrometheus: true, reachable: true)
    }

    // MARK: staging (healthy)

    static func staging(now: Date) -> Profile {
        var b = DemoDataBuilder(clusterName: "staging", now: now)
        for i in 0..<3 { b.addNode("gke-staging-pool-1-\(b.rng.token(8))", cpu: 4, memGi: 16, instance: "e2-standard-4", zone: "europe-west4-\(["a", "b", "c"][i])", pool: "pool-1", kubelet: "v1.31.3", provider: "GKE") }
        for ns in ["payments", "checkout", "monitoring", "kube-system", "default"] { b.addNamespace(ns) }
        let reg = "registry.example.com"
        b.addWorkload(.init(name: "payments-api", ns: "payments", replicas: 2, image: "\(reg)/payments-api:3.9.0-rc1", memRequest: "256Mi", memLimit: "512Mi"))
        b.addWorkload(.init(name: "checkout-web", ns: "checkout", replicas: 2, image: "\(reg)/checkout-web:12.2.0-rc2"))
        b.addWorkload(.init(name: "checkout-api", ns: "checkout", replicas: 2, image: "\(reg)/checkout-api:12.2.0-rc2"))
        b.addWorkload(.init(name: "coredns", ns: "kube-system", replicas: 2, image: "registry.k8s.io/coredns/coredns:v1.11.3", port: 53))
        b.addWorkload(.init(name: "grafana", ns: "monitoring", replicas: 1, image: "grafana/grafana:11.3.0", port: 3000))
        b.addWorkload(.init(name: "prometheus-k8s", ns: "monitoring", replicas: 1, image: "quay.io/prometheus/prometheus:v2.55.1", port: 9090, kind: .statefulSet))
        b.addService("payments-api", ns: "payments", port: 80, targetPort: 8080)
        b.addService("prometheus-operated", ns: "monitoring", port: 9090)
        b.addConfigMap("payments-config", ns: "payments", data: ["LOG_LEVEL": "debug"])
        b.addSecret("payments-db", ns: "payments", keys: ["username", "password"])
        b.addPVC("prometheus-data-prometheus-k8s-0", ns: "monitoring", size: "50Gi")
        b.addCronJob("nightly-report", ns: "payments", schedule: "0 3 * * *")
        b.addJob("nightly-report-28812400", ns: "payments", failed: false, ago: 3600 * 9)
        b.addEvent(ns: "payments", object: ("Deployment", "payments-api"), type: "Normal", reason: "ScalingReplicaSet", message: "Scaled up replica set payments-api to 2", count: 1, ago: 3600 * 3)
        addCRDs(&b, includeCerts: false)
        b.addStaticObjects(namespaces: ["payments", "checkout", "monitoring"])
        return Profile(objects: b.objects, nodeCPU: 4, nodeMemGi: 16, nodeCount: 3, hasMetricsServer: true, hasPrometheus: true, reachable: true)
    }

    // MARK: homelab-k3s (degraded: ImagePullBackOff; metrics-server only)

    static func homelab(now: Date) -> Profile {
        var b = DemoDataBuilder(clusterName: "homelab-k3s", now: now)
        b.addNode("k3s-server", cpu: 4, memGi: 8, instance: "k3s", zone: "home", pool: "server", kubelet: "v1.30.6+k3s1", control: true, provider: "k3s")
        b.addNode("k3s-agent-1", cpu: 4, memGi: 8, instance: "k3s", zone: "home", pool: "agent", kubelet: "v1.30.6+k3s1", provider: "k3s")
        for ns in ["home", "media", "kube-system", "default"] { b.addNamespace(ns) }
        b.addWorkload(.init(name: "home-assistant", ns: "home", replicas: 1, image: "ghcr.io/home-assistant/home-assistant:2024.11", port: 8123))
        b.addWorkload(.init(name: "jellyfin", ns: "media", replicas: 1, image: "jellyfin/jellyfin:10.10.1", memRequest: "1Gi", memLimit: "2Gi", port: 8096))
        b.addWorkload(.init(name: "photo-sync", ns: "media", replicas: 1, image: "ghcr.io/example/photo-sync:no-such-tag", states: [.imagePull]))
        b.addWorkload(.init(name: "traefik", ns: "kube-system", replicas: 1, image: "rancher/mirrored-library-traefik:2.11.8", port: 8000))
        b.addWorkload(.init(name: "coredns", ns: "kube-system", replicas: 1, image: "rancher/mirrored-coredns-coredns:1.11.1", port: 53))
        b.addService("home-assistant", ns: "home", port: 8123)
        b.addService("jellyfin", ns: "media", port: 8096)
        b.addPVC("jellyfin-config", ns: "media", size: "10Gi", sc: "local-path")
        b.addEvent(ns: "media", object: ("Pod", "photo-sync"), type: "Warning", reason: "Failed", message: "Failed to pull image \"ghcr.io/example/photo-sync:no-such-tag\": not found", count: 22, ago: 300)
        b.addStaticObjects(namespaces: ["home", "media"])
        return Profile(objects: b.objects, nodeCPU: 4, nodeMemGi: 8, nodeCount: 2, hasMetricsServer: true, hasPrometheus: false, reachable: true)
    }

    private static func addCRDs(_ b: inout DemoDataBuilder, includeCerts: Bool) {
        let cert = ResourceKind.custom(group: "cert-manager.io", version: "v1", kind: "Certificate", plural: "certificates", namespaced: true)
        let crd: JSONValue = [
            "metadata": b.meta("certificates.cert-manager.io", age: 86_400 * 120),
            "spec": ["group": "cert-manager.io", "scope": "Namespaced", "names": ["plural": "certificates", "singular": "certificate", "kind": "Certificate", "shortNames": ["cert"]],
                     "versions": [["name": "v1", "served": true, "storage": true, "additionalPrinterColumns": [["name": "Ready", "type": "string", "jsonPath": ".status.conditions[0].status"]]]]],
        ]
        b.add(.customResourceDefinition, crd)
        if includeCerts {
            b.add(cert, ["metadata": b.meta("checkout-tls", ns: "checkout", age: 86_400 * 60),
                         "spec": ["secretName": "checkout-tls", "dnsNames": ["shop.example.com"], "issuerRef": ["name": "letsencrypt", "kind": "ClusterIssuer"]],
                         "status": ["notAfter": .string(Date().addingTimeInterval(86_400 * 24).formatted(.iso8601)), "conditions": [["type": "Ready", "status": "True"]]]])
        }
    }
}
