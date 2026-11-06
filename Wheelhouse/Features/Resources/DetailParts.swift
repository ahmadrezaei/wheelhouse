import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Everything a kind-specific detail section needs.
struct DetailContext {
    let session: ClusterSession
    let ref: ResourceRef
    let object: Unstructured
    let host: ActionHost
    var summary: ResourceSummary { ResourceSummarizer.summarize(kind: ref.kind, object: object) }
    var target: ResourceTarget { ResourceTarget(kind: ref.kind, object: object) }
    var namespace: String? { ref.namespace }
    func ref(_ kind: ResourceKind, _ name: String, namespace: String? = nil) -> ResourceRef {
        ResourceRef(clusterID: ref.clusterID, kind: kind, namespace: kind.namespaced ? (namespace ?? ref.namespace) : nil, name: name)
    }
}

struct DetailCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                Spacer()
                if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary) }
            }
            content
        }
        .whCard()
    }
}

struct KV: View {
    let label: String
    let value: String
    var mono = false
    var tone: StatusTone?
    init(_ label: String, _ value: String, mono: Bool = false, tone: StatusTone? = nil) {
        self.label = label; self.value = value; self.mono = mono; self.tone = tone
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                valueText.multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.footnote).foregroundStyle(.secondary)
                valueText
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var valueText: some View {
        Text(value).font(mono ? .whCode : .subheadline).foregroundStyle(tone?.textColor ?? Color.primary).textSelection(.enabled)
    }
}

/// Tappable row linking to another object's detail.
struct ObjectLink: View {
    let ref: ResourceRef
    var title: String?
    var subtitle: String?
    var trailing: String?
    var symbol: String?

    var body: some View {
        RouteLink(route: .resourceDetail(ref)) {
            HStack(spacing: 10) {
                Image(systemName: symbol ?? ref.kind.symbol).foregroundStyle(Palette.tint).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title ?? ref.name).font(.whCode).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                    Text(subtitle ?? ref.kind.kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let trailing { Text(trailing).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: Spacing.minHit)
        }
        .accessibilityLabel("\(ref.kind.kind) \(ref.name)")
    }
}

struct ConditionsCard: View {
    let conditions: [Condition]
    /// Types where `True` is the problem (node pressure conditions).
    var inverted: Set<String> = ["MemoryPressure", "DiskPressure", "PIDPressure", "NetworkUnavailable"]

    var body: some View {
        if !conditions.isEmpty {
            DetailCard("Conditions", subtitle: "\(conditions.count)") {
                ForEach(conditions) { c in
                    let bad = inverted.contains(c.type) ? c.isTrue : (c.status == "False" && !["Progressing", "ReplicaFailure"].contains(c.type)) || (c.type == "ReplicaFailure" && c.isTrue)
                    let tone: StatusTone = bad ? .critical : (c.status == "Unknown" ? .unknown : .healthy)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Image(systemName: tone.symbol).foregroundStyle(tone.color).imageScale(.small)
                            Text(c.type).font(.subheadline.weight(.medium))
                            Spacer()
                            Text(c.status).font(.footnote).foregroundStyle(tone.textColor)
                            if let t = c.lastTransitionTime { Text(Format.age(from: t)).font(.caption).foregroundStyle(.tertiary) }
                        }
                        if let r = c.reason { Text(r).font(.caption).foregroundStyle(.secondary) }
                        if let m = c.message, !m.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

struct LabelsCard: View {
    let title: String
    let pairs: [String: String]
    var onTap: ((String, String) -> Void)?
    @State private var expanded: Bool

    init(_ title: String, pairs: [String: String], collapsed: Bool = false, onTap: ((String, String) -> Void)? = nil) {
        self.title = title; self.pairs = pairs; self.onTap = onTap
        _expanded = State(initialValue: !collapsed)
    }

    var body: some View {
        if !pairs.isEmpty {
            DetailCard(title, subtitle: "\(pairs.count)") {
                DisclosureGroup(isExpanded: $expanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(pairs.sorted { $0.key < $1.key }, id: \.key) { k, v in
                            if let onTap {
                                Button { onTap(k, v) } label: { chip(k, v) }.buttonStyle(.plain)
                            } else { chip(k, v) }
                        }
                    }
                    .padding(.top, 6)
                } label: { Text(expanded ? "Hide" : "Show \(pairs.count)").font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private func chip(_ k: String, _ v: String) -> some View {
        Text("\(Text(k).foregroundStyle(.secondary))=\(Text(v))")
            .font(.whCodeSmall).lineLimit(3).multilineTextAlignment(.leading)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.small))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct OwnersCard: View {
    let ctx: DetailContext

    var body: some View {
        let owners = ctx.object.metadata.ownerReferences
        if !owners.isEmpty {
            DetailCard("Controlled By") {
                ForEach(owners, id: \.name) { o in
                    if let kind = ResourceKind.lookup(o.kind) {
                        ObjectLink(ref: ctx.ref(kind, o.name))
                    } else {
                        KV(o.kind, o.name, mono: true)
                    }
                }
            }
        }
    }
}

/// Events for the object (field-selected), newest first.
struct EventsCard: View {
    let ctx: DetailContext
    @State private var events: [KubeEvent] = []
    @State private var loaded = false

    var body: some View {
        DetailCard("Events", subtitle: loaded ? "\(events.count)" : nil) {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if events.isEmpty {
                Text("No events recorded for this object.").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ForEach(events.prefix(30)) { e in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: e.isWarning ? "exclamationmark.triangle.fill" : "info.circle").foregroundStyle(e.isWarning ? Palette.warning : Palette.info).imageScale(.small).padding(.top, 3)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(e.reason ?? "Event").font(.subheadline.weight(.medium))
                                if let c = e.count, c > 1 { Text("×\(c)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                                Spacer()
                                Text(Format.age(from: e.lastSeen)).font(.caption).foregroundStyle(.tertiary)
                            }
                            if let m = e.message { Text(m).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        // Keyed on the object, not its resourceVersion (every status tick used to trigger a re-list); refresh on a 30 s timer.
        .task(id: ctx.ref.id) {
            await load()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(30)))
                if Task.isCancelled { return }
                await load()
            }
        }
    }

    private func load() async {
        let name = ctx.ref.name
        var field = "involvedObject.name=\(name)"
        if let uid = ctx.object.metadata.uid, !uid.isEmpty, !ctx.session.config.isDemo { field += ",involvedObject.uid=\(uid)" }
        do {
            let list = try await ctx.session.client.list(KubeEvent.self, namespace: ctx.ref.kind.namespaced ? ctx.ref.namespace : nil, options: ListOptions(fieldSelector: field))
            events = list.items.filter { $0.involvedObject.kind == nil || $0.involvedObject.kind == ctx.ref.kind.kind }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        } catch { if events.isEmpty { events = [] } }
        loaded = true
    }
}

/// Pods selected by a label selector (typed store, watch-backed).
struct RelatedPodsCard: View {
    let ctx: DetailContext
    @Environment(AppPreferences.self) private var preferences
    let selector: String
    var fieldSelector: String?
    var title = "Pods"
    @State private var usage: [String: PodUsageSample] = [:]

    var body: some View {
        let store = ctx.session.store(for: Pod.self, namespace: ctx.namespace, labelSelector: selector.isEmpty ? nil : selector, fieldSelector: fieldSelector)
        let pods = store.items
        DetailCard(title, subtitle: store.isLoading ? nil : "\(pods.count)") {
            if store.isLoading { ProgressView().frame(maxWidth: .infinity) }
            else if let e = store.error, pods.isEmpty { Text(e.summary).font(.footnote).foregroundStyle(.secondary) }
            else if pods.isEmpty { Text("No pods match this selector.").font(.subheadline).foregroundStyle(.secondary) }
            ForEach(pods.prefix(50)) { pod in
                let st = pod.stateSummary()
                RouteLink(route: .resourceDetail(ctx.ref(.pod, pod.metadata.name, namespace: pod.metadata.namespace))) {
                    HStack(spacing: 10) {
                        Image(systemName: (st.isCompleted ? HealthStatus.healthy : st.severity).symbol).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, (st.isCompleted ? HealthStatus.healthy : st.severity).color).frame(width: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(pod.metadata.name).font(.whCode).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                            Text([st.reason, "\(pod.readyContainers)/\(pod.totalContainers)", st.restarts > 0 ? "↻ \(st.restarts)" : nil, Format.age(from: pod.metadata.creationTimestamp), pod.spec.nodeName].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        if let u = usage["\(pod.metadata.namespace ?? "")/\(pod.metadata.name)"] {
                            Text("\(Quantity.formatCPU(cores: u.cpuCores)) · \(Quantity.formatBytes(u.memoryBytes, binary: preferences.useBinaryUnits))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: Spacing.minHit)
                }
            }
            if pods.count > 50 { Text("+ \(pods.count - 50) more").font(.footnote).foregroundStyle(.secondary) }
        }
        .task(id: selector + (fieldSelector ?? "")) { await store.run() }
        .task(id: selector + (fieldSelector ?? "")) {
            guard let m = try? await ctx.session.client.podMetrics(namespace: ctx.namespace) else { return }
            usage = Dictionary(m.map { ("\($0.metadata.namespace ?? "")/\($0.metadata.name)", PodUsageSample(cpuCores: $0.cpuCores, memoryBytes: $0.memoryBytes)) }, uniquingKeysWith: { $1 })
        }
    }
}

/// Pod/template container list with image, state, last termination, restarts and requests/limits.
struct ContainersCard: View {
    let title: String
    let containers: [JSONValue]
    let statuses: [ContainerStatus]
    var usage: [String: PodUsageSample] = [:]
    var onLogs: ((String) -> Void)?

    var body: some View {
        if !containers.isEmpty {
            DetailCard(title, subtitle: "\(containers.count)") {
                ForEach(Array(containers.enumerated()), id: \.offset) { _, c in
                    ContainerBlock(spec: c, status: statuses.first { $0.name == c["name"]?.stringValue }, onLogs: onLogs)
                    if c != containers.last { Divider() }
                }
            }
        }
    }
}

private struct ContainerBlock: View {
    let spec: JSONValue
    @Environment(AppPreferences.self) private var preferences
    let status: ContainerStatus?
    var onLogs: ((String) -> Void)?

    private var name: String { spec["name"]?.stringValue ?? "container" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "shippingbox").foregroundStyle(Palette.tint)
                Text(name).font(.subheadline.weight(.semibold))
                Spacer()
                if let status { stateBadge(status) }
            }
            if let image = spec["image"]?.stringValue { Text(image).font(.whCodeSmall).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled) }
            if let status {
                HStack(spacing: 12) {
                    Label("\(status.restartCount) restart\(status.restartCount == 1 ? "" : "s")", systemImage: "arrow.counterclockwise").font(.caption).foregroundStyle(status.restartCount > 0 ? Palette.warningText : .secondary)
                    Label(status.ready ? "Ready" : "Not ready", systemImage: status.ready ? "checkmark.circle" : "circle.dashed").font(.caption).foregroundStyle(.secondary)
                }
                if let t = status.lastState?.terminated {
                    Text("Last: \(t.reason ?? "Terminated") · exit \(t.exitCode)\(t.finishedAt.map { " · \(Format.age(from: $0)) ago" } ?? "")")
                        .font(.caption).foregroundStyle(t.reason == "OOMKilled" ? Palette.criticalText : Palette.warningText)
                }
                if let m = status.state?.waiting?.message, !m.isEmpty { Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(3) }
            }
            resourcesView
            let ports = (spec["ports"]?.arrayValue ?? []).compactMap { p -> String? in p["containerPort"]?.intValue.map { "\($0)/\(p["protocol"]?.stringValue ?? "TCP")" + (p["name"]?.stringValue.map { " (\($0))" } ?? "") } }
            if !ports.isEmpty { Text("Ports: \(ports.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) }
            if let onLogs {
                Button { onLogs(name) } label: { Label("Logs", systemImage: "text.alignleft").font(.footnote) }.buttonStyle(.bordered).controlSize(.small)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func f(_ v: JSONValue?, mem: Bool) -> String {
        v?.stringValue.flatMap { Quantity($0).value }.map { mem ? Quantity.formatBytes($0, binary: preferences.useBinaryUnits) : Quantity.formatCPU(cores: $0) } ?? "–"
    }

    @ViewBuilder private var resourcesView: some View {
        let req = spec.value(at: "resources.requests")?.objectValue ?? [:], lim = spec.value(at: "resources.limits")?.objectValue ?? [:]
        if !req.isEmpty || !lim.isEmpty {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CPU").font(.caption2).foregroundStyle(.secondary)
                    Text("\(f(req["cpu"], mem: false)) / \(f(lim["cpu"], mem: false))").font(.caption.monospacedDigit())
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Memory").font(.caption2).foregroundStyle(.secondary)
                    Text("\(f(req["memory"], mem: true)) / \(f(lim["memory"], mem: true))").font(.caption.monospacedDigit())
                }
                Text("request / limit").font(.caption2).foregroundStyle(.tertiary)
            }
            if lim.isEmpty { Text("No limits set").font(.caption2).foregroundStyle(Palette.warningText) }
        } else {
            Text("No requests or limits").font(.caption2).foregroundStyle(Palette.warningText)
        }
    }

    private func stateBadge(_ s: ContainerStatus) -> some View {
        Group {
            if let w = s.state?.waiting { StatusPill(tone: ["CrashLoopBackOff", "Error", "ErrImagePull", "ImagePullBackOff"].contains(w.reason ?? "") ? .critical : .warning, text: w.reason ?? "Waiting") }
            else if let t = s.state?.terminated { StatusPill(tone: t.exitCode == 0 ? .healthy : .critical, text: t.reason ?? "Terminated") }
            else if s.state?.running != nil { StatusPill(tone: .healthy, text: "Running") }
            else { StatusPill(tone: .unknown, text: "Unknown") }
        }
    }
}
