import Foundation

/// Rule-based explanation of a pod's problem, derived only from API fields (no guessing).
public struct PodDiagnosis: Hashable, Sendable {
    public var severity: HealthStatus
    public var symbol: String
    /// `OOMKilled`, `CrashLoopBackOff`, …
    public var title: String
    /// Facts shown after the title, e.g. `exit 137`, `memory peaked at 255Mi of 256Mi limit`.
    public var facts: [String]
    public var explanation: String
    public var suggestion: String?
    public var containerName: String?
    public var suggestsPreviousLogs: Bool

    /// Single-line banner text: `OOMKilled · exit 137 · memory peaked at … · next restart in 4m 12s`.
    public var bannerText: String { ([title] + facts).joined(separator: " · ") }
}

public enum PodDiagnoser {
    /// Kubelet crash back-off: 10s doubling to a 5 minute cap.
    public static func backoffDelay(restarts: Int) -> TimeInterval { min(300, 10 * pow(2, Double(max(restarts - 1, 0)))) }

    public static func exitCodeMeaning(_ code: Int) -> String? {
        switch code {
        case 0: "exited normally"
        case 1: "application error"
        case 2: "misuse of a shell builtin"
        case 126: "command not executable"
        case 127: "command not found"
        case 130: "interrupted (SIGINT)"
        case 137: "killed (SIGKILL), often out of memory"
        case 139: "segmentation fault (SIGSEGV)"
        case 143: "terminated (SIGTERM)"
        default: nil
        }
    }

    /// - Parameter memoryPeakBytes: highest observed memory use of the failing container (from metrics), when known.
    public static func diagnose(_ pod: Pod, memoryPeakBytes: Double? = nil, now: Date = Date()) -> PodDiagnosis? {
        let summary = pod.stateSummary()
        let containers = (pod.status?.containerStatuses ?? []) + (pod.status?.initContainerStatuses ?? [])
        let failing = containers.first { $0.state?.waiting?.reason == "CrashLoopBackOff" || $0.lastState?.terminated?.reason == "OOMKilled" || ($0.state?.terminated?.exitCode ?? 0) != 0 }
            ?? containers.first { $0.state?.waiting != nil && !$0.ready }

        switch summary.reason {
        case "CrashLoopBackOff", "OOMKilled", "Error":
            guard let c = failing else { return nil }
            let term = c.lastState?.terminated ?? c.state?.terminated
            let oom = term?.reason == "OOMKilled"
            var facts: [String] = []
            if let code = term?.exitCode { facts.append("exit \(code)") }
            if oom, let limit = pod.spec.containers.first(where: { $0.name == c.name })?.resources?.limits?.memoryBytes {
                if let peak = memoryPeakBytes {
                    facts.append("memory peaked at \(Quantity.formatBytes(peak)) of \(Quantity.formatBytes(limit)) limit")
                } else {
                    facts.append("memory limit \(Quantity.formatBytes(limit))")
                }
            }
            if summary.reason == "CrashLoopBackOff", let finished = term?.finishedAt {
                let remaining = finished.addingTimeInterval(backoffDelay(restarts: c.restartCount)).timeIntervalSince(now)
                if remaining > 0 {
                    facts.append("next restart in \(Duration.seconds(remaining).formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))")
                }
            }
            let meaning = term.flatMap { exitCodeMeaning($0.exitCode) }
            let explanation: String
            if oom {
                explanation = "The container \(c.name) used more memory than its limit and was killed by the kernel. Kubernetes restarts it with growing back-off."
            } else {
                explanation = "The container \(c.name) keeps exiting\(meaning.map { " (\($0))" } ?? "") and Kubernetes is delaying each restart."
            }
            return PodDiagnosis(severity: .critical, symbol: "xmark.octagon.fill", title: oom ? "OOMKilled" : "CrashLoopBackOff", facts: facts, explanation: explanation,
                                suggestion: oom ? "Check the previous logs, then raise the memory limit or fix the leak." : "Open the previous container's logs to see why it exited.",
                                containerName: c.name, suggestsPreviousLogs: true)
        case "ImagePullBackOff", "ErrImagePull", "InvalidImageName":
            let c = failing
            let msg = c?.state?.waiting?.message
            return PodDiagnosis(severity: .warning, symbol: "exclamationmark.triangle.fill", title: summary.reason,
                                facts: [c?.image].compactMap { $0 }, explanation: msg ?? "The image could not be pulled. Check the image name, tag and registry credentials (imagePullSecrets).",
                                suggestion: "Verify the image exists and the pull secret is valid.", containerName: c?.name, suggestsPreviousLogs: false)
        case "CreateContainerConfigError", "CreateContainerError":
            let msg = failing?.state?.waiting?.message
            return PodDiagnosis(severity: .warning, symbol: "exclamationmark.triangle.fill", title: summary.reason, facts: [],
                                explanation: msg ?? "The container could not be configured, usually a missing ConfigMap or Secret reference.",
                                suggestion: "Check referenced ConfigMaps, Secrets and volume mounts.", containerName: failing?.name, suggestsPreviousLogs: false)
        case "Evicted":
            return PodDiagnosis(severity: .critical, symbol: "xmark.octagon.fill", title: "Evicted", facts: [pod.status?.reason].compactMap { $0 },
                                explanation: pod.status?.message ?? "The node evicted this pod, usually because of resource pressure.",
                                suggestion: "Check node pressure conditions and the pod's resource requests.", containerName: nil, suggestsPreviousLogs: false)
        default:
            break
        }

        if pod.status?.phase == "Pending", pod.metadata.deletionTimestamp == nil {
            let unscheduled = pod.status?.conditions.first { $0.type == "PodScheduled" && $0.status == "False" }
            if let unscheduled {
                var facts = [unscheduled.reason ?? "Unschedulable"]
                if let created = pod.metadata.creationTimestamp {
                    facts.append("pending \(Duration.seconds(now.timeIntervalSince(created)).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))")
                }
                return PodDiagnosis(severity: .warning, symbol: "clock.badge.exclamationmark", title: "Pending", facts: facts,
                                    explanation: unscheduled.message ?? "The scheduler could not place this pod on any node.",
                                    suggestion: "Check resource requests, node selectors, taints and PersistentVolumeClaims.", containerName: nil, suggestsPreviousLogs: false)
            }
        }
        if summary.severity == .critical || summary.severity == .warning {
            return PodDiagnosis(severity: summary.severity, symbol: summary.severity.symbol, title: summary.reason, facts: [pod.status?.message].compactMap { $0 },
                                explanation: pod.status?.message ?? "The pod is not healthy.", suggestion: nil, containerName: failing?.name, suggestsPreviousLogs: summary.restarts > 0)
        }
        return nil
    }
}
