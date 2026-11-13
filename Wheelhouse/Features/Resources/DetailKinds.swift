import SwiftUI
import WheelhouseKit
import WheelhouseUI

// MARK: - Pod

struct PodSections: View {
    let ctx: DetailContext
    @Environment(AppPreferences.self) private var preferences
    @Environment(AppRouter.self) private var router
    @State private var usage: PodUsageSample?

    var body: some View {
        let pod = try? ctx.object.raw.decode(Pod.self)
        Group {
            if let pod {
                if ctx.session.metricsAvailability != nil || true { usageCard(pod) }
                containers("Init Containers", spec: "spec.initContainers", statuses: pod.status?.initContainerStatuses ?? [])
                containers("Containers", spec: "spec.containers", statuses: pod.status?.containerStatuses ?? [])
                containers("Ephemeral Containers", spec: "spec.ephemeralContainers", statuses: pod.status?.ephemeralContainerStatuses ?? [])
                detailsCard(pod)
                if !pod.spec.volumes.isEmpty {
                    DetailCard("Volumes", subtitle: "\(pod.spec.volumes.count)") {
                        ForEach(pod.spec.volumes) { v in
                            if let claim = v.persistentVolumeClaim?.claimName { ObjectLink(ref: ctx.ref(.persistentVolumeClaim, claim), title: v.name, subtitle: "PVC \(claim)") }
                            else { KV(v.name, v.sourceDescription) }
                        }
                    }
                }
                ConditionsCard(conditions: pod.status?.conditions ?? [])
            }
        }
        .task { await pollUsage() }
    }

    private func containers(_ title: String, spec: String, statuses: [ContainerStatus]) -> some View {
        ContainersCard(title: title, containers: ctx.object.array(spec), statuses: statuses, onLogs: { c in
            router.push(.logs(ctx.ref, container: c, previous: false))
        })
    }

    @ViewBuilder private func usageCard(_ pod: Pod) -> some View {
        let cpuReq = pod.spec.containers.compactMap { $0.resources?.requests?.cpuCores }.reduce(0, +)
        let memReq = pod.spec.containers.compactMap { $0.resources?.requests?.memoryBytes }.reduce(0, +)
        let cpuLimits = pod.spec.containers.compactMap { $0.resources?.limits?.cpuCores }
        let memLimits = pod.spec.containers.compactMap { $0.resources?.limits?.memoryBytes }
        let cpuLim = cpuLimits.count == pod.spec.containers.count ? cpuLimits.reduce(0, +) : 0
        let memLim = memLimits.count == pod.spec.containers.count ? memLimits.reduce(0, +) : 0
        DetailCard("Usage", subtitle: usage == nil ? "requests / limits" : "live") {
            UsageRow(label: "CPU", used: usage?.cpuCores, request: cpuReq, limit: cpuLim, format: { Quantity.formatCPU(cores: $0) })
            UsageRow(label: "Memory", used: usage?.memoryBytes, request: memReq, limit: memLim, format: { Quantity.formatBytes($0, binary: preferences.useBinaryUnits) })
        }
    }

    private func detailsCard(_ pod: Pod) -> some View {
        DetailCard("Details") {
            if let node = pod.spec.nodeName { ObjectLink(ref: ctx.ref(.node, node)) }
            if let ip = pod.status?.podIP { KV("Pod IP", ip, mono: true) }
            if let ip = pod.status?.hostIP { KV("Host IP", ip, mono: true) }
            if let q = pod.status?.qosClass { KV("QoS class", q) }
            if let sa = pod.spec.serviceAccountName { ObjectLink(ref: ctx.ref(.serviceAccount, sa)) }
            if let p = pod.spec.priorityClassName { KV("Priority class", p) }
            if let r = pod.spec.restartPolicy { KV("Restart policy", r) }
            if let s = pod.status?.startTime { KV("Started", s.formatted(date: .abbreviated, time: .shortened)) }
            if !pod.spec.nodeSelector.isEmpty { KV("Node selector", LabelSelectorSyntax.query(from: pod.spec.nodeSelector), mono: true) }
            if !pod.spec.tolerations.isEmpty { KV("Tolerations", "\(pod.spec.tolerations.count)") }
        }
    }

    private func pollUsage() async {
        let client = ctx.session.client, ns = ctx.namespace, name = ctx.ref.name
        while !Task.isCancelled {
            if EnergyPolicy.current.allowsLiveSampling || usage == nil,
               let list = try? await client.podMetrics(namespace: ns), let m = list.first(where: { $0.metadata.name == name }) {
                usage = PodUsageSample(cpuCores: m.cpuCores, memoryBytes: m.memoryBytes)
            }
            try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(15)))
        }
    }
}

/// Usage bar with request marker and limit track end (S11).
struct UsageRow: View {
    let label: String
    let used: Double?
    let request: Double
    let limit: Double
    let format: (Double) -> String

    var body: some View {
        let track = limit > 0 ? limit : max(max(request, used ?? 0) * 1.3, 0.0001)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("\(used.map(format) ?? "–") · req \(request > 0 ? format(request) : "–") · limit \(limit > 0 ? format(limit) : "none")").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Meter(value: (used ?? 0) / track, request: request > 0 ? request / track : nil, limit: limit > 0 ? 1 : nil, height: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Workloads

struct WorkloadSections: View {
    let ctx: DetailContext
    @Environment(AppRouter.self) private var router
    @State private var hpa: JSONValue?

    private var kindName: String { ctx.ref.kind.kind }
    private var selector: String {
        LabelSelectorSyntax.query(from: ctx.object.raw.value(at: "spec.selector.matchLabels")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
    }

    var body: some View {
        let s = ctx.summary
        Group {
            replicasCard(s)
            if kindName == "DaemonSet" { daemonCard }
            if kindName == "StatefulSet" { statefulCard }
            RelatedPodsCard(ctx: ctx, selector: selector)
            if kindName == "Deployment" { RolloutHistoryCard(ctx: ctx) }
            ContainersCard(title: "Init Containers", containers: ctx.object.array("spec.template.spec.initContainers"), statuses: [])
            ContainersCard(title: "Containers", containers: ctx.object.array("spec.template.spec.containers"), statuses: [])
            ConditionsCard(conditions: ctx.object.conditions())
        }
        .task { await loadHPA() }
    }

    private func replicasCard(_ s: ResourceSummary) -> some View {
        let desired = s.desired ?? 0, ready = s.ready ?? 0
        let total = max(ctx.object.int("status.replicas") ?? ctx.object.int("status.currentNumberScheduled") ?? ready, ready)
        return DetailCard("Replicas", subtitle: "\(ready) of \(desired) ready") {
            HStack(spacing: 3) {
                ForEach(0..<min(max(desired, total), 40), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3).fill(i < ready ? Palette.healthy : (i < total ? Palette.warning : Palette.fieldFill)).frame(height: 14)
                }
                if desired == 0 { Text("Scaled to 0").font(.subheadline).foregroundStyle(.secondary) }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel("\(ready) of \(desired) replicas ready")
            if kindName == "Deployment" {
                if let t = ctx.object.string("spec.strategy.type") {
                    let surge = ctx.object.raw.value(at: "spec.strategy.rollingUpdate.maxSurge").flatMap { JSONPathLite.display($0) }
                    let unavail = ctx.object.raw.value(at: "spec.strategy.rollingUpdate.maxUnavailable").flatMap { JSONPathLite.display($0) }
                    KV("Strategy", t == "RollingUpdate" ? "RollingUpdate · surge \(surge ?? "–") · unavailable \(unavail ?? "–")" : t)
                }
                KV("Up-to-date", "\(s.upToDate ?? 0)")
                KV("Available", "\(ctx.object.int("status.availableReplicas") ?? 0)")
                if ctx.object.bool("spec.paused") == true { KV("Rollout", "Paused", tone: .warning) }
            }
            if !selector.isEmpty { KV("Selector", selector, mono: true) }
            if let hpa { hpaView(hpa) }
            if ctx.host.canMutate, ["Deployment", "StatefulSet", "ReplicaSet"].contains(kindName) {
                Button { ctx.host.scale(ctx.target) } label: { Label("Scale…", systemImage: "plusminus") }.buttonStyle(.bordered)
            }
        }
    }

    private func hpaView(_ h: JSONValue) -> some View {
        let min = h.value(at: "spec.minReplicas")?.intValue ?? 1, max = h.value(at: "spec.maxReplicas")?.intValue ?? 0
        let cur = h.value(at: "status.currentReplicas")?.intValue ?? 0
        return KV("Autoscaler", "\(h.value(at: "metadata.name")?.stringValue ?? "HPA") · \(min)–\(max) · now \(cur)")
    }

    private var daemonCard: some View {
        DetailCard("Rollout") {
            KV("Desired", "\(ctx.object.int("status.desiredNumberScheduled") ?? 0)")
            KV("Current", "\(ctx.object.int("status.currentNumberScheduled") ?? 0)")
            KV("Ready", "\(ctx.object.int("status.numberReady") ?? 0)")
            KV("Updated", "\(ctx.object.int("status.updatedNumberScheduled") ?? 0)")
            KV("Misscheduled", "\(ctx.object.int("status.numberMisscheduled") ?? 0)", tone: (ctx.object.int("status.numberMisscheduled") ?? 0) > 0 ? .warning : nil)
        }
    }

    private var statefulCard: some View {
        DetailCard("StatefulSet") {
            if let s = ctx.object.string("spec.serviceName") { ObjectLink(ref: ctx.ref(.service, s)) }
            if let p = ctx.object.string("spec.podManagementPolicy") { KV("Pod management", p) }
            if let t = ctx.object.string("spec.updateStrategy.type") { KV("Update strategy", t) }
            if let part = ctx.object.int("spec.updateStrategy.rollingUpdate.partition") { KV("Partition", "\(part)") }
            let claims = ctx.object.array("spec.volumeClaimTemplates")
            ForEach(Array(claims.enumerated()), id: \.offset) { _, c in
                KV("PVC template", "\(c.value(at: "metadata.name")?.stringValue ?? "?") · \(c.value(at: "spec.resources.requests.storage")?.stringValue ?? "?")")
            }
        }
    }

    private func loadHPA() async {
        guard kindName == "Deployment" || kindName == "StatefulSet" else { return }
        guard let raw = try? await ctx.session.client.listRaw(.horizontalPodAutoscaler, namespace: ctx.namespace, options: ListOptions()) else { return }
        hpa = raw["items"]?.arrayValue?.first { $0.value(at: "spec.scaleTargetRef.name")?.stringValue == ctx.ref.name && $0.value(at: "spec.scaleTargetRef.kind")?.stringValue == kindName }
    }
}

struct RolloutHistoryCard: View {
    let ctx: DetailContext
    @State private var revisions: [RolloutRevision] = []
    @State private var loaded = false

    var body: some View {
        DetailCard("Rollout History", subtitle: loaded ? "\(revisions.count) revision\(revisions.count == 1 ? "" : "s")" : nil) {
            if !loaded { ProgressView().frame(maxWidth: .infinity) }
            else if revisions.isEmpty { Text("No ReplicaSet history.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(revisions.prefix(6)) { rev in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Revision \(rev.revision)").font(.subheadline.weight(.semibold))
                        if rev.isCurrent { StatusPill(tone: .info, text: "Current") }
                        Spacer()
                        Text(Format.age(from: rev.created)).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(rev.images.joined(separator: ", ")).font(.whCodeSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    if let c = rev.changeCause { Text(c).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityElement(children: .combine)
            }
            if ctx.host.canMutate, revisions.count > 1 {
                Button { ctx.host.rollback(ctx.target) } label: { Label("Roll Back…", systemImage: "arrow.uturn.backward") }.buttonStyle(.bordered)
            }
        }
        .task(id: ctx.object.metadata.resourceVersion) { await load() }
    }

    private func load() async {
        let sel = LabelSelectorSyntax.query(from: ctx.object.raw.value(at: "spec.selector.matchLabels")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
        guard let raw = try? await ctx.session.client.listRaw(.replicaSet, namespace: ctx.namespace, options: ListOptions(labelSelector: sel.isEmpty ? nil : sel)) else { loaded = true; return }
        revisions = RolloutHistory.revisions(deployment: ctx.object, replicaSets: (raw["items"]?.arrayValue ?? []).map { Unstructured(raw: $0) })
        loaded = true
    }
}

// MARK: - Jobs

struct JobSections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        let sel = LabelSelectorSyntax.query(from: o.raw.value(at: "spec.selector.matchLabels")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
        DetailCard("Job") {
            KV("Completions", "\(o.int("status.succeeded") ?? 0) / \(o.int("spec.completions") ?? 1)")
            KV("Parallelism", "\(o.int("spec.parallelism") ?? 1)")
            KV("Active", "\(o.int("status.active") ?? 0)")
            KV("Failed", "\(o.int("status.failed") ?? 0)", tone: (o.int("status.failed") ?? 0) > 0 ? .warning : nil)
            KV("Backoff limit", "\(o.int("spec.backoffLimit") ?? 6)")
            if let start = o.string("status.startTime").flatMap(ResourceSummarizer.parseDate) {
                let end = o.string("status.completionTime").flatMap(ResourceSummarizer.parseDate) ?? Date()
                KV("Duration", Format.age(seconds: end.timeIntervalSince(start)))
            }
            if let f = o.conditions().first(where: { $0.type == "Failed" && $0.isTrue }) { KV("Failure", [f.reason, f.message].compactMap { $0 }.joined(separator: ": "), tone: .critical) }
        }
        RelatedPodsCard(ctx: ctx, selector: sel)
        ContainersCard(title: "Containers", containers: o.array("spec.template.spec.containers"), statuses: [])
        ConditionsCard(conditions: o.conditions())
    }
}

struct CronJobSections: View {
    let ctx: DetailContext
    @State private var jobs: [Unstructured] = []

    var body: some View {
        let o = ctx.object
        let schedule = o.string("spec.schedule") ?? ""
        let cron = CronSchedule(schedule)
        let tz = o.string("spec.timeZone").flatMap(TimeZone.init(identifier:)) ?? .gmt
        DetailCard("Schedule") {
            KV("Cron", schedule, mono: true)
            if let cron { KV("Meaning", cron.describe()) }
            KV("Time zone", o.string("spec.timeZone") ?? "UTC (controller)")
            if let cron {
                let runs = cron.nextRuns(after: Date(), count: 3, timeZone: tz)
                ForEach(Array(runs.enumerated()), id: \.offset) { i, d in KV(i == 0 ? "Next runs" : "", d.formatted(date: .abbreviated, time: .shortened)) }
            }
            KV("Concurrency", o.string("spec.concurrencyPolicy") ?? "Allow")
            KV("Suspended", (o.bool("spec.suspend") ?? false) ? "Yes" : "No", tone: (o.bool("spec.suspend") ?? false) ? .warning : nil)
            KV("Last schedule", o.string("status.lastScheduleTime").flatMap(ResourceSummarizer.parseDate).map { "\(Format.age(from: $0)) ago" } ?? "never")
            if let t = o.string("status.lastSuccessfulTime").flatMap(ResourceSummarizer.parseDate) { KV("Last success", "\(Format.age(from: t)) ago") }
        }
        DetailCard("Jobs", subtitle: "\(jobs.count)") {
            if jobs.isEmpty { Text("No Jobs owned by this CronJob.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(jobs.prefix(15)) { j in
                let s = ResourceSummarizer.summarize(kind: .job, object: j)
                ObjectLink(ref: ctx.ref(.job, j.metadata.name), subtitle: "\(s.statusText) · \(Format.age(from: j.metadata.creationTimestamp))",
                           trailing: "\(s.ready ?? 0)/\(s.desired ?? 1)", symbol: s.status.symbol)
            }
        }
        ContainersCard(title: "Containers", containers: o.array("spec.jobTemplate.spec.template.spec.containers"), statuses: [])
        .task(id: o.metadata.resourceVersion) { await loadJobs() }
    }

    private func loadJobs() async {
        guard let raw = try? await ctx.session.client.listRaw(.job, namespace: ctx.namespace, options: ListOptions()) else { return }
        jobs = (raw["items"]?.arrayValue ?? []).map { Unstructured(raw: $0) }
            .filter { $0.metadata.ownerReferences.contains { $0.kind == "CronJob" && $0.name == ctx.ref.name } }
            .sorted { ($0.metadata.creationTimestamp ?? .distantPast) > ($1.metadata.creationTimestamp ?? .distantPast) }
    }
}

// MARK: - Networking

struct ServiceSections: View {
    let ctx: DetailContext
    @Environment(AppRouter.self) private var router
    @State private var endpoints: JSONValue?
    @State private var endpointsLoaded = false

    var body: some View {
        let o = ctx.object
        let selector = LabelSelectorSyntax.query(from: o.raw.value(at: "spec.selector")?.objectValue?.compactMapValues(\.stringValue) ?? [:])
        DetailCard("Service") {
            KV("Type", o.string("spec.type") ?? "ClusterIP")
            if let ip = o.string("spec.clusterIP") { KV("Cluster IP", ip, mono: true) }
            let lb = o.array("status.loadBalancer.ingress").compactMap { $0["ip"]?.stringValue ?? $0["hostname"]?.stringValue }
            if !lb.isEmpty { KV("External", lb.joined(separator: ", "), mono: true) }
            if let e = o.string("spec.externalName") { KV("External name", e, mono: true) }
            if !selector.isEmpty { KV("Selector", selector, mono: true) }
            if let a = o.string("spec.sessionAffinity"), a != "None" { KV("Session affinity", a) }
        }
        DetailCard("Ports", subtitle: "\(o.array("spec.ports").count)") {
            ForEach(Array(o.array("spec.ports").enumerated()), id: \.offset) { _, p in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(p["port"]?.intValue ?? 0) → \(JSONPathLite.display(p["targetPort"]) ?? "?")").font(.whCode)
                        Text([p["name"]?.stringValue, p["protocol"]?.stringValue ?? "TCP", p["nodePort"]?.intValue.map { "nodePort \($0)" }].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ctx.host.cluster.readOnly == false || ctx.host.cluster.allowExecInReadOnly {
                        #if os(macOS)
                        ServicePortForwardControl(ref: ctx.ref, port: p["port"]?.intValue ?? 0, isTCP: (p["protocol"]?.stringValue ?? "TCP") == "TCP")   // fix-P
                        #else
                        Button("Forward") { router.forward(ctx.ref) }.buttonStyle(.bordered).controlSize(.small)
                        #endif
                    }
                }
            }
        }
        endpointsCard
        if !selector.isEmpty { RelatedPodsCard(ctx: ctx, selector: selector, title: "Matched Pods") }
        Color.clear.frame(height: 0).task(id: o.metadata.resourceVersion) { await loadEndpoints() }
    }

    @ViewBuilder private var endpointsCard: some View {
        let subsets = endpoints?["subsets"]?.arrayValue ?? []
        let ready = subsets.flatMap { $0["addresses"]?.arrayValue ?? [] }
        let notReady = subsets.flatMap { $0["notReadyAddresses"]?.arrayValue ?? [] }
        DetailCard("Endpoints", subtitle: endpointsLoaded ? "\(ready.count) ready · \(notReady.count) not ready" : nil) {
            if endpointsLoaded, ready.isEmpty, notReady.isEmpty { Text("No endpoints. The selector matches no ready pods.").font(.subheadline).foregroundStyle(Palette.warningText) }
            ForEach(Array(ready.enumerated()), id: \.offset) { _, a in endpointRow(a, ready: true) }
            ForEach(Array(notReady.enumerated()), id: \.offset) { _, a in endpointRow(a, ready: false) }
        }
    }

    @ViewBuilder private func endpointRow(_ a: JSONValue, ready: Bool) -> some View {
        if let pod = a.value(at: "targetRef.name")?.stringValue, a.value(at: "targetRef.kind")?.stringValue == "Pod" {
            ObjectLink(ref: ctx.ref(.pod, pod), title: a["ip"]?.stringValue, subtitle: "\(ready ? "Ready" : "Not ready") · \(pod)", symbol: ready ? "checkmark.circle.fill" : "exclamationmark.circle")
        } else {
            KV(ready ? "Ready" : "Not ready", a["ip"]?.stringValue ?? "?", mono: true, tone: ready ? nil : .warning)
        }
    }

    private func loadEndpoints() async {
        endpoints = try? await ctx.session.client.getRaw(.endpoints, name: ctx.ref.name, namespace: ctx.namespace)
        endpointsLoaded = true
    }
}

struct IngressSections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        DetailCard("Ingress") {
            if let c = o.string("spec.ingressClassName") ?? o.metadata.annotations["kubernetes.io/ingress.class"] { KV("Class", c) }
            let lb = o.array("status.loadBalancer.ingress").compactMap { $0["ip"]?.stringValue ?? $0["hostname"]?.stringValue }
            if !lb.isEmpty { KV("Address", lb.joined(separator: ", "), mono: true) }
            if let d = o.raw.value(at: "spec.defaultBackend.service.name")?.stringValue { ObjectLink(ref: ctx.ref(.service, d), subtitle: "Default backend") }
        }
        let tlsHosts = Set(o.array("spec.tls").flatMap { $0["hosts"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        DetailCard("Rules") {
            ForEach(Array(o.array("spec.rules").enumerated()), id: \.offset) { _, rule in
                let host = rule["host"]?.stringValue
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(host ?? "any host").font(.subheadline.weight(.semibold))
                        if let host, let url = URL(string: "\(tlsHosts.contains(host) ? "https" : "http")://\(host)") { Link(destination: url) { Image(systemName: "safari") }.accessibilityLabel("Open \(host)") }
                    }
                    ForEach(Array((rule.value(at: "http.paths")?.arrayValue ?? []).enumerated()), id: \.offset) { _, p in
                        if let svc = p.value(at: "backend.service.name")?.stringValue {
                            ObjectLink(ref: ctx.ref(.service, svc), title: "\(p["path"]?.stringValue ?? "/") → \(svc):\(JSONPathLite.display(p.value(at: "backend.service.port.number") ?? p.value(at: "backend.service.port.name")) ?? "?")",
                                       subtitle: p["pathType"]?.stringValue ?? "Prefix")
                        }
                    }
                }
            }
        }
        let tls = o.array("spec.tls")
        if !tls.isEmpty {
            DetailCard("TLS") {
                ForEach(Array(tls.enumerated()), id: \.offset) { _, t in
                    if let s = t["secretName"]?.stringValue { ObjectLink(ref: ctx.ref(.secret, s), subtitle: (t["hosts"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")) }
                }
            }
        }
    }
}

struct NetworkPolicySections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        DetailCard("Policy") {
            KV("Applies to pods", ResourceSummarizer.selectorText(o.raw.value(at: "spec.podSelector")), mono: true)
            KV("Types", o.array("spec.policyTypes").compactMap(\.stringValue).joined(separator: ", "))
        }
        rules("Ingress rules", o.array("spec.ingress"), peers: "from", verb: "Allow from")
        rules("Egress rules", o.array("spec.egress"), peers: "to", verb: "Allow to")
    }

    @ViewBuilder private func rules(_ title: String, _ rules: [JSONValue], peers: String, verb: String) -> some View {
        if !rules.isEmpty {
            DetailCard(title) {
                ForEach(Array(rules.enumerated()), id: \.offset) { _, r in
                    let who = (r[peers]?.arrayValue ?? []).map { p -> String in
                        if let sel = p["podSelector"] { return "pods \(ResourceSummarizer.selectorText(sel))" + (p["namespaceSelector"].map { " in namespaces \(ResourceSummarizer.selectorText($0))" } ?? "") }
                        if let ns = p["namespaceSelector"] { return "namespaces \(ResourceSummarizer.selectorText(ns))" }
                        if let cidr = p.value(at: "ipBlock.cidr")?.stringValue { return "CIDR \(cidr)" }
                        return "any"
                    }
                    let ports = (r["ports"]?.arrayValue ?? []).map { "\($0["protocol"]?.stringValue ?? "TCP") \(JSONPathLite.display($0["port"]) ?? "*")" }
                    Text("\(verb) \(who.isEmpty ? "anywhere" : who.joined(separator: " or "))\(ports.isEmpty ? "" : " on \(ports.joined(separator: ", "))")")
                        .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Node

struct NodeSections: View {
    let ctx: DetailContext
    @Environment(AppPreferences.self) private var preferences
    @State private var usage: PodUsageSample?

    var body: some View {
        let o = ctx.object
        let store = ctx.session.store(for: Pod.self, namespace: nil, fieldSelector: "spec.nodeName=\(ctx.ref.name)")
        let pods = store.items.filter { $0.status?.phase != "Succeeded" && $0.status?.phase != "Failed" }
        let allocCPU = o.string("status.allocatable.cpu").flatMap { Quantity($0).value } ?? 0
        let allocMem = o.string("status.allocatable.memory").flatMap { Quantity($0).value } ?? 0
        let reqCPU = pods.reduce(0.0) { $0 + $1.spec.containers.compactMap { $0.resources?.requests?.cpuCores }.reduce(0, +) }
        let reqMem = pods.reduce(0.0) { $0 + $1.spec.containers.compactMap { $0.resources?.requests?.memoryBytes }.reduce(0, +) }
        let maxPods = o.string("status.allocatable.pods").flatMap(Int.init) ?? 0
        Group {
            DetailCard("Capacity") {
                capacity("CPU", used: usage?.cpuCores, requested: reqCPU, allocatable: allocCPU, capacity: o.string("status.capacity.cpu").flatMap { Quantity($0).value } ?? 0, fmt: { Quantity.formatCPU(cores: $0) })
                capacity("Memory", used: usage?.memoryBytes, requested: reqMem, allocatable: allocMem, capacity: o.string("status.capacity.memory").flatMap { Quantity($0).value } ?? 0, fmt: { Quantity.formatBytes($0, binary: preferences.useBinaryUnits) })
                KV("Pods", "\(pods.count)\(maxPods > 0 ? " / \(maxPods)" : "")")
            }
            DetailCard("Node") {
                if let z = o.metadata.labels["topology.kubernetes.io/zone"] { KV("Zone", z) }
                if let t = o.metadata.labels["node.kubernetes.io/instance-type"] ?? o.metadata.labels["beta.kubernetes.io/instance-type"] { KV("Instance type", t) }
                if let v = o.string("status.nodeInfo.kubeletVersion") { KV("Kubelet", v) }
                if let v = o.string("status.nodeInfo.osImage") { KV("OS", v) }
                if let v = o.string("status.nodeInfo.kernelVersion") { KV("Kernel", v, mono: true) }
                if let v = o.string("status.nodeInfo.containerRuntimeVersion") { KV("Runtime", v, mono: true) }
                if let v = o.string("status.nodeInfo.architecture") { KV("Architecture", v) }
                ForEach(Array(o.array("status.addresses").enumerated()), id: \.offset) { _, a in KV(a["type"]?.stringValue ?? "Address", a["address"]?.stringValue ?? "", mono: true) }
            }
            let taints = o.array("spec.taints")
            if !taints.isEmpty {
                DetailCard("Taints", subtitle: "\(taints.count)") {
                    ForEach(Array(taints.enumerated()), id: \.offset) { _, t in
                        Text("\(t["key"]?.stringValue ?? "")\(t["value"]?.stringValue.map { "=\($0)" } ?? ""):\(t["effect"]?.stringValue ?? "")").font(.whCodeSmall)
                    }
                }
            }
            ConditionsCard(conditions: o.conditions())
            RelatedPodsCard(ctx: ctx, selector: "", fieldSelector: "spec.nodeName=\(ctx.ref.name)", title: "Pods on Node")
        }
        .task {
            while !Task.isCancelled {
                if EnergyPolicy.current.allowsLiveSampling || usage == nil,
                   let list = try? await ctx.session.client.nodeMetrics(), let m = list.first(where: { $0.metadata.name == ctx.ref.name }) {
                    usage = PodUsageSample(cpuCores: m.cpuCores, memoryBytes: m.memoryBytes)
                }
                try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(15)))
            }
        }
    }

    private func capacity(_ label: String, used: Double?, requested: Double, allocatable: Double, capacity: Double, fmt: (Double) -> String) -> some View {
        let track = max(allocatable, 0.0001)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.subheadline)
                Spacer()
                Text("req \(fmt(requested)) · \(used.map { "used \(fmt($0)) · " } ?? "")alloc \(fmt(allocatable)) / cap \(fmt(capacity))").font(.caption.monospacedDigit()).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            Meter(value: (used ?? requested) / track, request: used == nil ? nil : requested / track, height: 8)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Config

struct ConfigMapSections: View {
    let ctx: DetailContext
    @State private var expanded: Set<String> = []

    var body: some View {
        let data = ctx.object.raw["data"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        let binary = ctx.object.raw["binaryData"]?.objectValue ?? [:]
        DetailCard("Data", subtitle: "\(data.count + binary.count) key\(data.count + binary.count == 1 ? "" : "s")") {
            if data.isEmpty, binary.isEmpty { Text("This ConfigMap has no data.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(data.sorted { $0.key < $1.key }, id: \.key) { key, value in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Button { toggle(key) } label: {
                            HStack { Image(systemName: expanded.contains(key) ? "chevron.down" : "chevron.right").imageScale(.small).frame(width: 14); Text(key).font(.whCode.weight(.medium)) }
                        }.buttonStyle(.plain)
                        Spacer()
                        Text("\(value.utf8.count) B").font(.caption).foregroundStyle(.secondary)
                        Button { Pasteboard.copy(value) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.borderless).accessibilityLabel("Copy \(key)")
                    }
                    if expanded.contains(key) {
                        Text(String(value.prefix(6000))).font(.whCodeSmall).textSelection(.enabled)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code))
                        if value.count > 6000 { Text("Truncated — open YAML for the full value.").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Text(value.split(separator: "\n").first.map(String.init) ?? "").font(.whCodeSmall).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            ForEach(binary.keys.sorted(), id: \.self) { k in KV(k, "binary", mono: true) }
        }
        .onAppear { if data.count == 1 { expanded = Set(data.keys) } }
    }

    private func toggle(_ k: String) { if expanded.contains(k) { expanded.remove(k) } else { expanded.insert(k) } }
}

struct SecretSections: View {
    let ctx: DetailContext
    @Environment(AppPreferences.self) private var preferences
    @State private var revealed: Set<String> = []
    @State private var note: String?

    var body: some View {
        let data = ctx.object.raw["data"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        let type = ctx.object.string("type") ?? "Opaque"
        Group {
            DetailCard("Secret", subtitle: type) {
                HStack(spacing: 8) {
                    Image(systemName: "faceid").foregroundStyle(Palette.tint)
                    Text("Values are masked. Revealing or copying requires Face ID or your passcode. Values are never logged or stored.").font(.footnote).foregroundStyle(.secondary)
                }
                if type == "kubernetes.io/dockerconfigjson", let v = data[".dockerconfigjson"] {
                    let regs = SecretDecoder.registries(dockerConfigBase64: v)
                    if !regs.isEmpty { KV("Registries", regs.joined(separator: ", "), mono: true) }
                }
                if type == "kubernetes.io/tls", let crt = data["tls.crt"], let subject = certificateSubject(base64: crt) { KV("Certificate", subject) }
            }
            DetailCard("Data", subtitle: "\(data.count) key\(data.count == 1 ? "" : "s")") {
                if data.isEmpty { Text("This Secret has no data.").font(.subheadline).foregroundStyle(.secondary) }
                ForEach(data.sorted { $0.key < $1.key }, id: \.key) { key, b64 in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(key).font(.whCode.weight(.medium))
                            Spacer()
                            Text("\(SecretDecoder.byteCount(base64: b64)) B").font(.caption).foregroundStyle(.secondary)
                            Button { Task { await toggle(key) } } label: { Image(systemName: revealed.contains(key) ? "eye.slash" : "eye") }
                                .buttonStyle(.borderless).accessibilityLabel(revealed.contains(key) ? "Hide \(key)" : "Reveal \(key)")
                            Button { Task { await copy(key, b64) } } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).accessibilityLabel("Copy \(key)")
                        }
                        if revealed.contains(key) {
                            Text(SecretDecoder.text(fromBase64: b64).map { String($0.prefix(4000)) } ?? "(binary data)").font(.whCodeSmall).textSelection(.enabled)
                                .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code))
                        } else {
                            Text("••••••••••••").font(.whCodeSmall).foregroundStyle(.secondary).accessibilityLabel("Hidden")
                        }
                    }
                }
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onChange(of: ctx.ref) { revealed = [] }
        .onDisappear { revealed = [] }
    }

    private func toggle(_ key: String) async {
        if revealed.contains(key) { revealed.remove(key); return }
        let ok = await SecretRevealGate.shared.authorize(oncePerSession: preferences.revealSecretsOncePerSession) {
            await AppLockController.authenticate(reason: "Reveal secret value “\(key)”")
        }
        guard ok else { note = "Authentication required to reveal values."; return }
        note = nil
        revealed.insert(key)
        try? await Task.sleep(for: .seconds(30))
        revealed.remove(key)
    }

    private func copy(_ key: String, _ b64: String) async {
        guard await AppLockController.authenticate(reason: "Copy secret value “\(key)”"), let text = SecretDecoder.text(fromBase64: b64) else { note = "Authentication required to copy values."; return }
        Pasteboard.copySensitive(text, clearAfter: 60)
        note = "Copied \(key). The clipboard clears in 60 seconds."
    }

    private func certificateSubject(base64: String) -> String? {
        guard let pemData = Data(base64Encoded: base64), let pem = String(data: pemData, encoding: .utf8) else { return nil }
        let body = pem.components(separatedBy: "-----").dropFirst(2).first ?? ""
        guard let der = Data(base64Encoded: body.filter { !$0.isWhitespace }), let cert = SecCertificateCreateWithData(nil, der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(cert) as String?
    }
}

// MARK: - Storage

struct PVCSections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        DetailCard("Claim") {
            KV("Status", o.string("status.phase") ?? "Unknown", tone: StatusTone(ctx.summary.status))
            KV("Capacity", o.string("status.capacity.storage") ?? o.string("spec.resources.requests.storage") ?? "–")
            KV("Access modes", o.array("spec.accessModes").compactMap(\.stringValue).joined(separator: ", "))
            if let sc = o.string("spec.storageClassName") { ObjectLink(ref: ctx.ref(.storageClass, sc)) }
            if let pv = o.string("spec.volumeName") { ObjectLink(ref: ctx.ref(.persistentVolume, pv), subtitle: "Bound volume") }
            if let m = o.string("spec.volumeMode") { KV("Volume mode", m) }
        }
        UsedByPodsCard(ctx: ctx)
        ConditionsCard(conditions: o.conditions())
    }
}

private struct UsedByPodsCard: View {
    let ctx: DetailContext

    var body: some View {
        let store = ctx.session.store(for: Pod.self, namespace: ctx.namespace)
        let users = store.items.filter { $0.spec.volumes.contains { $0.persistentVolumeClaim?.claimName == ctx.ref.name } }
        DetailCard("Used By", subtitle: "\(users.count)") {
            if users.isEmpty { Text("No pods mount this claim.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(users) { p in ObjectLink(ref: ctx.ref(.pod, p.metadata.name), subtitle: p.stateSummary().reason) }
        }
        .task { await store.run() }
    }
}

struct PVSections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        DetailCard("Volume") {
            KV("Status", o.string("status.phase") ?? "Unknown", tone: StatusTone(ctx.summary.status))
            KV("Capacity", o.string("spec.capacity.storage") ?? "–")
            KV("Access modes", o.array("spec.accessModes").compactMap(\.stringValue).joined(separator: ", "))
            KV("Reclaim policy", o.string("spec.persistentVolumeReclaimPolicy") ?? "–")
            if let sc = o.string("spec.storageClassName") { ObjectLink(ref: ctx.ref(.storageClass, sc)) }
            if let src = o.raw["spec"]?.objectValue?.keys.first(where: { ["hostPath", "nfs", "csi", "local", "awsElasticBlockStore", "gcePersistentDisk", "azureDisk", "iscsi", "rbd", "cephfs"].contains($0) }) { KV("Source", src) }
            if let c = o.raw.value(at: "spec.claimRef.name")?.stringValue { ObjectLink(ref: ctx.ref(.persistentVolumeClaim, c, namespace: o.raw.value(at: "spec.claimRef.namespace")?.stringValue), subtitle: "Bound claim") }
        }
        ConditionsCard(conditions: o.conditions())
    }
}

// MARK: - Access

struct RoleSections: View {
    let ctx: DetailContext

    var body: some View {
        let rules = ctx.object.array("rules")
        DetailCard("Rules", subtitle: "\(rules.count)") {
            ForEach(Array(rules.enumerated()), id: \.offset) { _, r in
                let verbs = (r["verbs"]?.arrayValue ?? []).compactMap(\.stringValue)
                let res = (r["resources"]?.arrayValue ?? []).compactMap(\.stringValue) + (r["nonResourceURLs"]?.arrayValue ?? []).compactMap(\.stringValue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(res.joined(separator: ", ")).font(.whCode).lineLimit(3)
                    Text(verbs.joined(separator: " · ")).font(.caption).foregroundStyle(verbs.contains("*") ? Palette.warningText : .secondary)
                    let groups = (r["apiGroups"]?.arrayValue ?? []).compactMap(\.stringValue)
                    if !groups.isEmpty { Text("groups: " + groups.map { $0.isEmpty ? "core" : $0 }.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary) }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct BindingSections: View {
    let ctx: DetailContext

    var body: some View {
        let o = ctx.object
        DetailCard("Role") {
            if let name = o.string("roleRef.name"), let kindName = o.string("roleRef.kind"), let kind = ResourceKind.lookup(kindName) {
                ObjectLink(ref: ctx.ref(kind, name))
            }
        }
        DetailCard("Subjects", subtitle: "\(o.array("subjects").count)") {
            ForEach(Array(o.array("subjects").enumerated()), id: \.offset) { _, s in
                let kind = s["kind"]?.stringValue ?? "Subject", name = s["name"]?.stringValue ?? ""
                if kind == "ServiceAccount" {
                    ObjectLink(ref: ctx.ref(.serviceAccount, name, namespace: s["namespace"]?.stringValue), subtitle: "ServiceAccount · \(s["namespace"]?.stringValue ?? "")")
                } else { KV(kind, name, mono: true) }
            }
        }
    }
}

// MARK: - Cluster & generic

struct GenericSections: View {
    let ctx: DetailContext
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        let o = ctx.object
        let fields = Self.flatten(o.raw["spec"], prefix: "", depth: 2) + Self.flatten(o.raw["status"], prefix: "status.", depth: 2)
            .filter { !$0.0.hasPrefix("status.conditions") }
        let top = ["type", "provisioner", "reclaimPolicy", "volumeBindingMode", "reason", "message", "note", "involvedObject", "count", "secrets", "imagePullSecrets"]
            .compactMap { k in o.raw[k].flatMap { JSONPathLite.display($0) }.map { (k, $0) } }
        if ctx.ref.kind == .namespace {
            DetailCard("Namespace") {
                KV("Phase", o.string("status.phase") ?? "Active")
                Button { registry.setNamespace(ctx.ref.name, for: ctx.ref.clusterID); ctx.host.show(ActionToast(message: "Current namespace: \(ctx.ref.name)", symbol: "folder.fill", tone: .info)) } label: {
                    Label("Set as Current Namespace", systemImage: "folder.badge.gearshape")
                }.buttonStyle(.bordered)
            }
        }
        if ctx.ref.kind == .customResourceDefinition { crdCard }
        if !top.isEmpty || !fields.isEmpty {
            DetailCard("Properties") {
                ForEach(Array((top + fields.prefix(24)).enumerated()), id: \.offset) { _, kv in KV(kv.0, kv.1, mono: true) }
            }
        }
        ConditionsCard(conditions: o.conditions())
    }

    @ViewBuilder private var crdCard: some View {
        let o = ctx.object
        DetailCard("Definition") {
            KV("Group", o.string("spec.group") ?? "", mono: true)
            KV("Kind", o.string("spec.names.kind") ?? "")
            KV("Scope", o.string("spec.scope") ?? "")
            KV("Versions", o.array("spec.versions").compactMap { $0["name"]?.stringValue }.joined(separator: ", "))
            if let crd = try? o.raw.decode(CustomResourceDefinition.self) {
                RouteLink(route: .resourceList(ctx.ref.clusterID, crd.resourceKind, namespace: nil)) {
                    Label("Browse Instances", systemImage: "list.bullet").frame(minHeight: Spacing.minHit)
                }
            }
        }
    }

    static func flatten(_ value: JSONValue?, prefix: String, depth: Int) -> [(String, String)] {
        guard let obj = value?.objectValue else { return [] }
        var out: [(String, String)] = []
        for (k, v) in obj.sorted(by: { $0.key < $1.key }) {
            switch v {
            case .object where depth > 0: out += flatten(v, prefix: "\(prefix)\(k).", depth: depth - 1)
            case .object, .null: continue
            case .array(let a):
                if a.allSatisfy({ $0.objectValue == nil && $0.arrayValue == nil }), !a.isEmpty { out.append(("\(prefix)\(k)", a.compactMap { JSONPathLite.display($0) }.joined(separator: ", "))) }
                else if !a.isEmpty { out.append(("\(prefix)\(k)", "\(a.count) item\(a.count == 1 ? "" : "s")")) }
            default: if let d = JSONPathLite.display(v) { out.append(("\(prefix)\(k)", d)) }
            }
        }
        return out
    }
}
