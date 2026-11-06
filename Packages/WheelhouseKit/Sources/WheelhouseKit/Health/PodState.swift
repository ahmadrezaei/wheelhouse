import Foundation

/// kubectl-style summary of a pod's state.
public struct PodStateSummary: Hashable, Sendable {
    /// What `kubectl get pods` would print in STATUS (`Running`, `CrashLoopBackOff`, `Init:0/2`, `Terminating`…).
    public var reason: String
    public var severity: HealthStatus
    public var isReady: Bool
    public var isCompleted: Bool
    public var restarts: Int
    public var lastTerminationReason: String?
    public var lastExitCode: Int?
}

public extension Pod {
    static let criticalReasons: Set<String> = ["CrashLoopBackOff", "OOMKilled", "Error", "Failed", "Evicted", "ContainerCannotRun", "DeadlineExceeded"]
    static let warningReasons: Set<String> = ["ImagePullBackOff", "ErrImagePull", "InvalidImageName", "CreateContainerConfigError", "CreateContainerError", "ErrImageNeverPull", "RunContainerError"]

    /// True for a pod that has not started yet (unscheduled, initialising, creating containers) and has no error of its own.
    /// Pending pods carry `.warning` severity, so dashboards must test this before bucketing by severity.
    func isPendingForCounts(_ s: PodStateSummary) -> Bool {
        guard status?.phase == "Pending", s.severity != .critical else { return false }
        return s.reason == "Pending" || s.severity == .healthy
    }

    func stateSummary() -> PodStateSummary {
        let st = status
        var reason = st?.reason ?? st?.phase ?? "Unknown"
        let inits = st?.initContainerStatuses ?? []
        var initFailed = false
        for (i, c) in inits.enumerated() {
            if let t = c.state?.terminated {
                if t.exitCode == 0 { continue }
                reason = "Init:" + (t.reason ?? (t.signal.map { "Signal:\($0)" } ?? "ExitCode:\(t.exitCode)"))
                initFailed = true
            } else if let w = c.state?.waiting, let r = w.reason, r != "PodInitializing" {
                reason = "Init:" + r
                initFailed = true
            } else {
                reason = "Init:\(i)/\(inits.count)"
                initFailed = true
            }
            break
        }
        if !initFailed {
            for c in (st?.containerStatuses ?? []).reversed() {
                if let r = c.state?.waiting?.reason, !r.isEmpty { reason = r; break }
                if let t = c.state?.terminated {
                    reason = t.reason ?? (t.signal.map { "Signal:\($0)" } ?? "ExitCode:\(t.exitCode)")
                    break
                }
            }
        }
        if metadata.deletionTimestamp != nil { reason = st?.reason == "NodeLost" ? "Unknown" : "Terminating" }

        let restarts = restartCount
        let lastTerm = (st?.containerStatuses ?? []).compactMap { $0.lastState?.terminated }.max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        let completed = st?.phase == "Succeeded"
        let ready = st?.phase == "Running" && (st?.containerStatuses ?? []).allSatisfy(\.ready) && !(st?.containerStatuses ?? []).isEmpty

        var severity: HealthStatus = .healthy
        // Init failures use the main-container rules on the reason after `Init:`; `Init:0/2` and `PodInitializing` are progress.
        let isInit = reason.hasPrefix("Init:")
        let base = isInit ? String(reason.dropFirst(5)) : reason
        if Self.criticalReasons.contains(base) || base.hasPrefix("ExitCode:") || base.hasPrefix("Signal:")
            || base.hasPrefix("CrashLoop") || (isInit && base.hasPrefix("Error")) {
            severity = .critical
        } else if Self.warningReasons.contains(base) || (isInit && (base.hasPrefix("ImagePull") || base.hasPrefix("ErrImage"))) {
            severity = .warning
        } else if st?.phase == "Failed" {
            severity = .critical
        } else if reason == "Pending" {
            // A pod that has not started is never "healthy" (consistent with its diagnosis banner).
            severity = .warning
        } else if reason == "Unknown" {
            severity = .unknown
        }
        // A running container that recently OOM-killed is still a problem even before it enters back-off.
        if severity == .healthy, lastTerm?.reason == "OOMKilled", restarts > 0, let f = lastTerm?.finishedAt, Date().timeIntervalSince(f) < 600 {
            severity = .warning
        }
        return PodStateSummary(reason: reason, severity: severity, isReady: ready, isCompleted: completed, restarts: restarts,
                               lastTerminationReason: lastTerm?.reason, lastExitCode: lastTerm?.exitCode)
    }
}
