import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Live usage for a row (metrics-server), keyed elsewhere by `ns/name` or node name.
struct PodUsageSample: Hashable {
    var cpuCores: Double
    var memoryBytes: Double
}

/// Kind-specific list row (S8): lead indicator, name, status/subtitle and trailing metric.
struct ObjectRow: View {
    let kind: ResourceKind
    let object: Unstructured
    let summary: ResourceSummary
    var usage: PodUsageSample?
    var showNamespace = true
    var extraColumns: [String] = []
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(AppPreferences.self) private var preferences

    private var ageText: String { Format.age(from: object.metadata.creationTimestamp) }

    var body: some View {
        HStack(spacing: 12) {
            lead
            VStack(alignment: .leading, spacing: 3) {
                Text(object.metadata.name).font(.whCode.weight(.medium)).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                subtitle
                if kind == .node { nodeMeters }
            }
            Spacer(minLength: 4)
            trailing
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .frame(minHeight: Spacing.minHit)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: Lead

    @ViewBuilder private var lead: some View {
        switch kind.kind {
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job":
            ReadyRing(ready: summary.ready ?? 0, desired: summary.desired ?? 0)
        case "Pod", "Node", "PersistentVolumeClaim", "PersistentVolume", "Endpoints", "EndpointSlice", "Event":
            Image(systemName: summary.status.symbol).symbolRenderingMode(.palette).foregroundStyle(.white, summary.status.color).font(.title3).frame(width: 32)
        default:
            Image(systemName: kind.symbol).symbolRenderingMode(.hierarchical).foregroundStyle(summary.status == .healthy ? Palette.tint : summary.status.color).font(.title3).frame(width: 32)
        }
    }

    // MARK: Subtitle

    @ViewBuilder private var subtitle: some View {
        let tone = StatusTone(summary.status)
        let ns = showNamespace ? object.metadata.namespace : nil
        let statusFirst = ["Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "Node", "PersistentVolumeClaim", "PersistentVolume", "CronJob"].contains(kind.kind) || kind.section == .custom
        let rest = restParts.joined(separator: " · ")
        Group {
            if statusFirst, !summary.statusText.isEmpty {
                Text("\(Text(summary.statusText).foregroundStyle(tone.textColor).fontWeight(.medium))\(rest.isEmpty ? "" : " · \(rest)")")
            } else {
                Text(rest.isEmpty ? summary.statusText : rest)
            }
        }
        .font(.footnote).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
        if let ns {
            Text(ns).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    private var restParts: [String] {
        switch kind.kind {
        case "Pod":
            var p = ["\(summary.ready ?? 0)/\(summary.desired ?? 0)"]
            p.append("↻ \(summary.restarts)")
            p.append(ageText)
            if let n = summary.nodeName { p.append(n) }
            return p
        case "Node":
            return summary.details + [ageText]
        case "Deployment", "StatefulSet", "DaemonSet":
            return [summary.upToDate.map { "\($0) up-to-date" }, ageText].compactMap { $0 }
        case "Event":
            return summary.details.prefix(2).map { String($0) }
        default:
            return summary.details + extraColumns + (kind.kind == "Event" ? [] : [ageText])
        }
    }

    // MARK: Trailing

    @ViewBuilder private var trailing: some View {
        if kind == .pod, let u = usage {
            VStack(alignment: .trailing, spacing: 2) {
                Text(Quantity.formatCPU(cores: u.cpuCores)).foregroundStyle(cpuTone)
                Text(Quantity.formatBytes(u.memoryBytes, binary: preferences.useBinaryUnits)).foregroundStyle(memTone)
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var cpuTone: Color {
        guard let u = usage, let lim = summary.cpuLimitCores, lim > 0 else { return .secondary }
        return u.cpuCores / lim >= 0.95 ? Palette.criticalText : (u.cpuCores / lim >= 0.85 ? Palette.warningText : .secondary)
    }
    private var memTone: Color {
        guard let u = usage, let lim = summary.memoryLimitBytes, lim > 0 else { return .secondary }
        return u.memoryBytes / lim >= 0.95 ? Palette.criticalText : (u.memoryBytes / lim >= 0.85 ? Palette.warningText : .secondary)
    }

    @ViewBuilder private var nodeMeters: some View {
        HStack(spacing: 12) {
            miniMeter("CPU", usage.flatMap { u in summary.cpuCapacityCores.map { u.cpuCores / max($0, 0.001) } })
            miniMeter("MEM", usage.flatMap { u in summary.memoryCapacityBytes.map { u.memoryBytes / max($0, 1) } })
        }
        .frame(maxWidth: 260)
    }

    private func miniMeter(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Meter(value: value ?? 0, height: 4)
            Text(value.map(Format.percent) ?? "–").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 26, alignment: .trailing)
        }
    }

    private var accessibilityText: String {
        "\(kind.kind) \(object.metadata.name), \(summary.statusText), \(restParts.joined(separator: ", "))"
    }
}
