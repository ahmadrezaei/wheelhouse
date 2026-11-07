import Foundation

/// Suggested patches for workload findings (DESIGN-MAC §6.9). Until the Manifest Editor lands (M7) they are shown next to the finding,
/// copied to the pasteboard and the object opens in the YAML editor, whose normal review and confirmation apply.
public enum SuggestedPatches {
    public static func patch(for f: SecurityFinding) -> SuggestedPatch? {
        let containers = f.containers
        let pod = f.workload?.kind == "Pod"
        let podCaveat = pod ? "A Pod's security settings cannot be changed in place. Recreate the Pod, or move the settings into a controller." : nil

        func perContainer(_ fields: [String]) -> String {
            var lines = ["containers:"]
            for c in containers {
                lines.append("  - name: \(yamlString(c))")
                lines.append("    securityContext:")
                lines += fields.map { "      \($0)" }
            }
            return lines.joined(separator: "\n")
        }

        switch f.ruleID {
        case "WH-W01":
            return SuggestedPatch(summary: "Turn privileged mode off", yaml: perContainer(["privileged: false"]),
                                  caveat: podCaveat ?? "Add back only the specific capabilities the container needs.")
        case "WH-W03":
            let off = ["hostNetwork", "hostPID", "hostIPC"].filter { key in f.evidence.contains { $0.hasPrefix(key) } }
            guard !off.isEmpty else { return nil }
            return SuggestedPatch(summary: "Stop sharing the host's namespaces", yaml: off.map { "\($0): false" }.joined(separator: "\n"), caveat: podCaveat)
        case "WH-W04":
            return SuggestedPatch(summary: "Drop all capabilities", yaml: perContainer(["capabilities:", "  drop: [\"ALL\"]"]),
                                  caveat: podCaveat ?? "The added capabilities are removed by replacing the list. Add back only what the container needs, for example NET_BIND_SERVICE.")
        case "WH-W05":
            return SuggestedPatch(summary: "Forbid privilege escalation", yaml: perContainer(["allowPrivilegeEscalation: false"]), caveat: podCaveat)
        case "WH-W06":
            return SuggestedPatch(summary: "Run as a non-root user", yaml: "securityContext:\n  runAsNonRoot: true\n  runAsUser: 10001",
                                  caveat: podCaveat ?? "The image must work as that user (file permissions, listening ports above 1024).")
        case "WH-W07":
            return SuggestedPatch(summary: "Make the root filesystem read-only", yaml: perContainer(["readOnlyRootFilesystem: true"]),
                                  caveat: podCaveat ?? "Mount an emptyDir volume for paths the container writes to (/tmp, caches).")
        case "WH-W08":
            var lines = ["containers:"]
            for c in containers {
                lines += ["  - name: \(yamlString(c))", "    resources:", "      limits:", "        cpu: 500m", "        memory: 256Mi"]
            }
            return SuggestedPatch(summary: "Add CPU and memory limits", yaml: lines.joined(separator: "\n"),
                                  caveat: podCaveat.map { _ in "Recreate the Pod to change limits." } ?? "The values are placeholders: set them from observed usage.")
        case "WH-W09":
            var lines = ["containers:"]
            for c in containers { lines += ["  - name: \(yamlString(c))", "    image: <repository>@sha256:<digest>"] }
            return SuggestedPatch(summary: "Pin the image by digest", yaml: lines.joined(separator: "\n"),
                                  caveat: "Resolve the digest of the image you run (`crane digest` or the registry), then replace the placeholder.")
        case "WH-W11":
            return SuggestedPatch(summary: "Use the runtime's default seccomp profile", yaml: "securityContext:\n  seccompProfile:\n    type: RuntimeDefault", caveat: podCaveat)
        case "WH-A08":
            return SuggestedPatch(summary: "Do not mount the ServiceAccount token", yaml: "automountServiceAccountToken: false",
                                  caveat: podCaveat ?? "Only if the workload does not call the Kubernetes API.")
        case "WH-W10":
            return SuggestedPatch(summary: "Label the namespace for Pod Security Admission",
                                  yaml: "metadata:\n  labels:\n    pod-security.kubernetes.io/warn: restricted\n    pod-security.kubernetes.io/audit: restricted",
                                  caveat: "warn and audit report violations without blocking. Switch to enforce once the workloads pass.")
        default:
            return nil
        }
    }

    /// Where the patch applies: `spec.template.spec` of a controller, `spec.jobTemplate.spec.template.spec` of a CronJob, `spec` of a Pod.
    public static func location(for f: SecurityFinding) -> String? {
        if f.ruleID == "WH-W10" { return nil }
        switch f.workload?.kind {
        case "Pod": return "spec"
        case "CronJob": return "spec.jobTemplate.spec.template.spec"
        case nil: return nil
        default: return "spec.template.spec"
        }
    }

    /// The object to open in the editor for a finding.
    public static func editTarget(for f: SecurityFinding) -> ResourceRef? {
        if let w = f.workload { return w.resourceRef(clusterID: f.clusterID) }
        if f.object.kind == "Namespace" { return ResourceRef(clusterID: f.clusterID, kind: .namespace, name: f.object.name) }
        return nil
    }

    private static func yamlString(_ s: String) -> String {
        s.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil ? s : "\"\(s.replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
