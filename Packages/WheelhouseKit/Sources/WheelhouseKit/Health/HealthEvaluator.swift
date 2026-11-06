import Foundation

/// Pure functions deriving cluster status and attention items from resource snapshots. Shared by the UI and background refresh.
public enum HealthEvaluator {
    public static func evaluate(_ input: ClusterHealthInput, rules: HealthRules = HealthRules(), now: Date = Date()) -> ClusterHealth {
        var items: [AttentionItem] = []
        var counts = ClusterCounts()
        let cid = input.clusterID

        // Nodes
        counts.nodesTotal = input.nodes.count
        for node in input.nodes {
            let ref = ResourceRef(clusterID: cid, kind: .node, name: node.metadata.name)
            if node.isReady { counts.nodesReady += 1 } else {
                counts.nodesNotReady += 1
                items.append(AttentionItem(id: "\(cid)/node/\(node.metadata.name)/notready", clusterID: cid, severity: .critical, kind: .nodeNotReady,
                                           title: "Node NotReady", detail: "\(node.metadata.name) · \(node.readyCondition?.reason ?? "Ready condition not true")",
                                           resource: ref, since: node.readyCondition?.lastTransitionTime))
            }
            if node.isUnschedulable { counts.nodesCordoned += 1 }
            let pressure = node.activePressure
            if !pressure.isEmpty {
                counts.nodesPressure += 1
                items.append(AttentionItem(id: "\(cid)/node/\(node.metadata.name)/pressure", clusterID: cid, severity: .warning, kind: .nodePressure,
                                           title: pressure.map(\.type).joined(separator: ", "), detail: node.metadata.name, resource: ref,
                                           since: pressure.compactMap(\.lastTransitionTime).min()))
            }
        }

        // Pods
        counts.podsTotal = input.pods.count
        for pod in input.pods {
            let s = pod.stateSummary()
            let ref = ResourceRef(clusterID: cid, object: pod)
            let name = pod.metadata.name
            if s.isCompleted { counts.podsCompleted += 1 }
            else if pod.isPendingForCounts(s) { counts.podsPending += 1 }
            else if s.severity == .critical || s.severity == .warning { counts.podsFailing += 1 }
            else if s.isReady || pod.status?.phase == "Running" { counts.podsRunning += 1 }

            let since = pod.status?.containerStatuses.compactMap { $0.lastState?.terminated?.finishedAt }.max() ?? pod.metadata.creationTimestamp
            switch s.reason {
            case "CrashLoopBackOff":
                let oom = s.lastTerminationReason == "OOMKilled"
                items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/crash", clusterID: cid, severity: .critical, kind: oom ? .oomKilled : .crashLoop,
                                           title: oom ? "CrashLoopBackOff · OOMKilled" : "CrashLoopBackOff",
                                           detail: "\(name) · restarted \(s.restarts)×", resource: ref, since: since, restarts: s.restarts))
            case "OOMKilled":
                items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/oom", clusterID: cid, severity: .critical, kind: .oomKilled, title: "OOMKilled",
                                           detail: "\(name) · restarted \(s.restarts)×", resource: ref, since: since, restarts: s.restarts))
            case "ImagePullBackOff", "ErrImagePull", "InvalidImageName", "ErrImageNeverPull":
                items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/image", clusterID: cid, severity: .warning, kind: .imagePull, title: s.reason,
                                           detail: name, resource: ref, since: pod.metadata.creationTimestamp))
            case "CreateContainerConfigError", "CreateContainerError", "RunContainerError":
                items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/config", clusterID: cid, severity: .warning, kind: .configError, title: s.reason,
                                           detail: name, resource: ref, since: pod.metadata.creationTimestamp))
            default:
                if s.severity == .critical {
                    items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/failed", clusterID: cid, severity: .critical, kind: .podFailed, title: s.reason,
                                               detail: name, resource: ref, since: since))
                } else if pod.status?.phase == "Pending", pod.metadata.deletionTimestamp == nil,
                          let created = pod.metadata.creationTimestamp, now.timeIntervalSince(created) > rules.pendingThreshold {
                    let why = pod.status?.conditions.first { $0.type == "PodScheduled" && $0.status == "False" }?.reason
                    items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/pending", clusterID: cid, severity: .warning, kind: .podPending,
                                               title: "Pending \(Duration.seconds(now.timeIntervalSince(created)).formatted(.units(allowed: [.hours, .minutes], width: .narrow, maximumUnitCount: 1)))",
                                               detail: "\(name)\(why.map { " · \($0)" } ?? "")", resource: ref, since: created))
                } else if s.restarts >= rules.highRestartCount, s.severity == .healthy {
                    items.append(AttentionItem(id: "\(cid)/pod/\(pod.id)/restarts", clusterID: cid, severity: .warning, kind: .highRestarts, title: "High restarts",
                                               detail: "\(name) · \(s.restarts) restarts", resource: ref, since: since, restarts: s.restarts))
                }
            }
        }

        // Controllers
        counts.deploymentsTotal = input.deployments.count
        for d in input.deployments {
            let desired = d.desiredReplicas
            if desired == 0 || d.availableReplicas >= desired { counts.deploymentsAvailable += 1; continue }
            let ref = ResourceRef(clusterID: cid, object: d)
            if d.availableReplicas == 0 {
                items.append(AttentionItem(id: "\(cid)/deploy/\(d.id)/down", clusterID: cid, severity: .critical, kind: .deploymentUnavailable,
                                           title: "No replicas available", detail: "\(d.metadata.name) · 0 of \(desired) available", resource: ref,
                                           since: d.status?.conditions.first { $0.type == "Available" }?.lastTransitionTime))
            } else {
                counts.deploymentsAvailable += 1
                items.append(AttentionItem(id: "\(cid)/deploy/\(d.id)/degraded", clusterID: cid, severity: .warning, kind: .deploymentDegraded,
                                           title: "Below desired replicas", detail: "\(d.metadata.name) · \(d.availableReplicas) of \(desired) available", resource: ref, since: nil))
            }
        }
        counts.statefulSetsTotal = input.statefulSets.count
        counts.statefulSetsReady = input.statefulSets.filter { $0.readyReplicas >= $0.desiredReplicas }.count
        counts.daemonSetsTotal = input.daemonSets.count
        counts.daemonSetsReady = input.daemonSets.filter { $0.readyReplicas >= $0.desiredReplicas }.count

        for job in input.jobs where job.isFailed {
            counts.jobsFailed += 1
            items.append(AttentionItem(id: "\(cid)/job/\(job.id)", clusterID: cid, severity: .warning, kind: .jobFailed, title: "Job failed",
                                       detail: "\(job.metadata.name) · \(job.failureCondition?.reason ?? "Failed")", resource: ResourceRef(clusterID: cid, object: job),
                                       since: job.failureCondition?.lastTransitionTime))
        }
        for pvc in input.pvcs where pvc.status?.phase == "Pending" {
            if let created = pvc.metadata.creationTimestamp, now.timeIntervalSince(created) > rules.pendingThreshold {
                items.append(AttentionItem(id: "\(cid)/pvc/\(pvc.id)", clusterID: cid, severity: .warning, kind: .pvcPending, title: "PVC Pending",
                                           detail: pvc.metadata.name, resource: ResourceRef(clusterID: cid, object: pvc), since: created))
            }
        }
        counts.warningEvents = input.warningEventCount
        counts.namespaces = input.namespaceCount

        items.sort { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return (a.since ?? .distantPast) > (b.since ?? .distantPast)
        }

        // Cluster status: critical = NotReady node or a Deployment with 0 available; degraded = any other item.
        let status: HealthStatus
        if counts.nodesNotReady > 0 || items.contains(where: { $0.kind == .deploymentUnavailable }) { status = .critical }
        else if !items.isEmpty { status = .warning }
        else { status = .healthy }
        // A failed pods/nodes list means we cannot claim the cluster is healthy.
        let partial = !input.failedKinds.isEmpty
        let blind = !input.failedKinds.isDisjoint(with: ["pods", "nodes"])
        return ClusterHealth(clusterID: cid, status: status == .healthy && blind ? .unknown : status, isReachable: true, items: items, counts: counts,
                             updatedAt: now, isPartial: partial, failedKinds: input.failedKinds.sorted())
    }

    /// Items for the whole fleet, ranked critical → warning → unknown, then recency.
    public static func fleetAttention(_ healths: [ClusterHealth], limit: Int? = nil) -> [AttentionItem] {
        let all = healths.flatMap(\.items).sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            return (a.since ?? .distantPast) > (b.since ?? .distantPast)
        }
        return limit.map { Array(all.prefix($0)) } ?? all
    }
}
