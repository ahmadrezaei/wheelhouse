import Foundation

/// One entry of the Survey rule catalogue: the stable ID, the severity and the plain-language text of the finding detail
/// (DESIGN-MAC §6.9). The catalogue also feeds `runs[].tool.driver.rules` of the SARIF export.
public struct SecurityRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var severity: Severity
    public var category: FindingCategory
    /// What the finding means, in one paragraph.
    public var summary: String
    /// The attack path, in plain language.
    public var whyItMatters: String
    /// Fix guidance, as steps.
    public var fix: [String]
    public var docsURL: String
}

public enum RuleCatalogue {
    public static func rule(_ id: String) -> SecurityRule? { byID[id] }
    public static let byID: [String: SecurityRule] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static var access: [SecurityRule] { all.filter { $0.category == .access } }
    public static var workload: [SecurityRule] { all.filter { $0.category == .workload } }

    private static let rbacDocs = "https://kubernetes.io/docs/reference/access-authn-authz/rbac/"
    private static let rbacGoodPractices = "https://kubernetes.io/docs/concepts/security/rbac-good-practices/"
    private static let pssDocs = "https://kubernetes.io/docs/concepts/security/pod-security-standards/"
    private static let securityContextDocs = "https://kubernetes.io/docs/tasks/configure-pod-container/security-context/"

    public static let all: [SecurityRule] = [
        // MARK: Access (RBAC)
        SecurityRule(
            id: "WH-A01", title: "Role grants wildcard verbs or resources", severity: .high, category: .access,
            summary: "A Role or ClusterRole uses `*` as a verb or as a resource, so it grants more than anyone can easily review, and it silently grows when new resource types or verbs are added to the cluster.",
            whyItMatters: "Whoever is bound to this role can do things its author never thought about, such as reading Secrets, creating Pods or changing other roles. Wildcards also hide the real permissions from audits.",
            fix: ["List what the subjects of this role actually do (the audit log or `kubectl auth can-i --list`).",
                  "Replace `*` with the explicit verbs and resources needed.",
                  "Keep wildcards only for break-glass roles, bound to a small group and reviewed regularly."],
            docsURL: rbacGoodPractices),
        SecurityRule(
            id: "WH-A02", title: "cluster-admin bound outside system:", severity: .critical, category: .access,
            summary: "The built-in `cluster-admin` role is bound to a user, group or ServiceAccount that is not part of the system components.",
            whyItMatters: "cluster-admin can do everything in the cluster: read every Secret, run code in every Pod, change every role. A stolen token for this subject is a full cluster compromise.",
            fix: ["Bind a narrower role (`admin`, `edit`, `view` or a custom role) instead.",
                  "If cluster-admin is required, bind it to a named human group with short-lived credentials, never to a ServiceAccount used by a workload.",
                  "Delete the binding when it is no longer needed."],
            docsURL: rbacGoodPractices),
        SecurityRule(
            id: "WH-A03", title: "Subject can read Secrets cluster-wide", severity: .high, category: .access,
            summary: "A subject can get, list or watch Secrets in every namespace.",
            whyItMatters: "Secrets hold tokens, passwords and private keys. Reading every Secret lets an attacker move into other workloads and often into the cloud account behind the cluster.",
            fix: ["Grant Secret access with a RoleBinding in the namespaces that need it.",
                  "Restrict `get` to named Secrets with `resourceNames`; avoid `list` and `watch`, which return every value.",
                  "Prefer mounting the Secret into the workload that needs it."],
            docsURL: rbacGoodPractices),
        SecurityRule(
            id: "WH-A04", title: "Subject can escalate, bind or impersonate", severity: .critical, category: .access,
            summary: "A subject can use the `escalate` or `bind` verb on roles, or the `impersonate` verb on users, groups or ServiceAccounts.",
            whyItMatters: "These verbs bypass the rule that nobody can grant more than they hold. A subject with them can give itself cluster-admin or act as any identity.",
            fix: ["Remove `escalate`, `bind` and `impersonate` from everything but the identity-management tooling.",
                  "If impersonation is needed (a gateway), restrict it with `resourceNames` to the identities it must act as."],
            docsURL: rbacDocs),
        SecurityRule(
            id: "WH-A05", title: "Subject can create Pods or exec in kube-system", severity: .high, category: .access,
            summary: "A subject can create Pods, or open a shell in a Pod (`pods/exec`), in the `kube-system` namespace.",
            whyItMatters: "kube-system runs the cluster's own components, many with powerful ServiceAccounts or host access. A Pod created there, or a shell in one of them, inherits that power.",
            fix: ["Remove create on `pods` and `pods/exec` for kube-system from this subject.",
                  "Use a dedicated namespace for workloads and administration tools."],
            docsURL: rbacGoodPractices),
        SecurityRule(
            id: "WH-A06", title: "Binding to anonymous or unauthenticated users", severity: .critical, category: .access,
            summary: "A binding grants a role to `system:anonymous` or `system:unauthenticated`, beyond the default discovery roles.",
            whyItMatters: "Anybody who can reach the API server gets these permissions without any credentials.",
            fix: ["Delete the binding, or bind the role to `system:authenticated` or a specific group.",
                  "Check that anonymous authentication is needed at all (`--anonymous-auth`)."],
            docsURL: rbacDocs),
        SecurityRule(
            id: "WH-A07", title: "Default ServiceAccount has extra RoleBindings", severity: .medium, category: .access,
            summary: "The `default` ServiceAccount of a namespace has been given permissions. Every Pod that does not name a ServiceAccount runs as it.",
            whyItMatters: "Permissions given to `default` apply to every Pod in the namespace that does not choose another ServiceAccount, including Pods that never needed an API token.",
            fix: ["Create a dedicated ServiceAccount for the workload that needs the permissions and bind the role to it.",
                  "Remove the bindings from `default`, and set `automountServiceAccountToken: false` on it."],
            docsURL: rbacGoodPractices),
        SecurityRule(
            id: "WH-A08", title: "Workload with a powerful ServiceAccount mounts its token", severity: .medium, category: .access,
            summary: "A workload runs as a ServiceAccount that holds powerful permissions, and the ServiceAccount token is mounted into its Pods.",
            whyItMatters: "Anything that can run code in one of these Pods (a vulnerable library, a compromised image) can read the token and use the permissions against the API server.",
            fix: ["Set `automountServiceAccountToken: false` on the Pod spec if the workload does not call the Kubernetes API.",
                  "Otherwise, give the workload a ServiceAccount with only the permissions it needs."],
            docsURL: "https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/"),
        SecurityRule(
            id: "WH-A09", title: "Subject can change admission webhooks", severity: .high, category: .access,
            summary: "A subject can create, update or patch ValidatingWebhookConfigurations or MutatingWebhookConfigurations.",
            whyItMatters: "A mutating webhook sees and can rewrite every object the cluster admits, including Pods and Secrets. Changing or removing a validating webhook switches off the cluster's policies.",
            fix: ["Remove write access to webhook configurations from everything but the tools that install them.",
                  "Review the webhook configurations that exist and their `failurePolicy`."],
            docsURL: "https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/"),
        SecurityRule(
            id: "WH-A10", title: "Subject can use nodes/proxy or create ServiceAccount tokens", severity: .high, category: .access,
            summary: "A subject can modify `nodes/proxy`, which reaches the kubelet API, or create tokens for ServiceAccounts (`serviceaccounts/token`).",
            whyItMatters: "`nodes/proxy` lets a subject run commands in any Pod on the node through the kubelet, without the API server's checks. Creating a ServiceAccount token lets the subject act as that ServiceAccount.",
            fix: ["Remove `nodes/proxy` and `serviceaccounts/token` from this subject.",
                  "Monitoring tools that read kubelet metrics need `nodes/metrics`, not `nodes/proxy`."],
            docsURL: rbacGoodPractices),

        // MARK: Workload (pod security)
        SecurityRule(
            id: "WH-W01", title: "Privileged container", severity: .critical, category: .workload,
            summary: "A container runs with `securityContext.privileged: true`.",
            whyItMatters: "A privileged container has nearly the same access as a process on the node. A break-out takes one command, and the whole node, with every other Pod on it, is compromised.",
            fix: ["Remove `privileged: true`.", "Add only the specific capabilities the container needs.", "Move genuinely privileged tools to a dedicated node pool and namespace."],
            docsURL: pssDocs),
        SecurityRule(
            id: "WH-W02", title: "hostPath volume", severity: .high, category: .workload,
            summary: "A Pod mounts a directory of the node (`hostPath`). Mounting the node's root, `/etc` or a container runtime socket is critical.",
            whyItMatters: "The Pod can read and often write files on the node. With the container runtime socket or `/etc`, it can start privileged containers or change the node's configuration.",
            fix: ["Use `emptyDir`, a PersistentVolumeClaim, a ConfigMap or a CSI volume instead.",
                  "If the node path is unavoidable, mount the narrowest path read-only."],
            docsURL: pssDocs),
        SecurityRule(
            id: "WH-W03", title: "Host network, PID or IPC namespace", severity: .high, category: .workload,
            summary: "A Pod uses `hostNetwork`, `hostPID` or `hostIPC`.",
            whyItMatters: "The Pod shares the node's network, process list or shared memory. It can reach node-local services and see or signal other processes.",
            fix: ["Remove `hostNetwork`, `hostPID` and `hostIPC` unless the workload is a node agent.", "Use a Service or a hostPort-free design instead."],
            docsURL: pssDocs),
        SecurityRule(
            id: "WH-W04", title: "Dangerous capabilities added", severity: .high, category: .workload,
            summary: "A container adds `SYS_ADMIN`, `NET_ADMIN`, `NET_RAW` or `ALL` capabilities.",
            whyItMatters: "`SYS_ADMIN` is close to root on the node. `NET_ADMIN` and `NET_RAW` allow network manipulation and sniffing, including inside the Pod network.",
            fix: ["Drop all capabilities (`drop: [ALL]`) and add back only what is required.", "Avoid `SYS_ADMIN` altogether."],
            docsURL: securityContextDocs),
        SecurityRule(
            id: "WH-W05", title: "Privilege escalation allowed", severity: .medium, category: .workload,
            summary: "A container does not set `allowPrivilegeEscalation: false`, so a process can gain more privileges than its parent (setuid binaries, for example).",
            whyItMatters: "Escalation turns a small foothold in the container into root inside it, which makes every other weakness easier to use.",
            fix: ["Set `securityContext.allowPrivilegeEscalation: false` on every container."],
            docsURL: securityContextDocs),
        SecurityRule(
            id: "WH-W06", title: "Runs as root or runAsNonRoot missing", severity: .medium, category: .workload,
            summary: "A container may run as root: `runAsNonRoot` is not true, and no non-zero `runAsUser` is set.",
            whyItMatters: "Root inside a container is a much stronger starting point for a container escape, and it can modify everything in the image.",
            fix: ["Set `runAsNonRoot: true` and a numeric `runAsUser` (for example 10001) on the Pod or the container.", "Make sure the image supports running as that user."],
            docsURL: securityContextDocs),
        SecurityRule(
            id: "WH-W07", title: "Writable root filesystem", severity: .low, category: .workload,
            summary: "A container does not set `readOnlyRootFilesystem: true`.",
            whyItMatters: "Malware can be written to the container's filesystem and its binaries replaced. A read-only filesystem blocks most of that.",
            fix: ["Set `readOnlyRootFilesystem: true` and mount `emptyDir` volumes for the paths that need writing (`/tmp`, caches)."],
            docsURL: securityContextDocs),
        SecurityRule(
            id: "WH-W08", title: "No CPU or memory limits", severity: .low, category: .workload,
            summary: "A container has no CPU limit or no memory limit.",
            whyItMatters: "One misbehaving or hijacked container can use all the CPU or memory of its node and take neighbours down.",
            fix: ["Set `resources.limits.memory` (and a CPU limit or a LimitRange default) based on observed usage."],
            docsURL: "https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/"),
        SecurityRule(
            id: "WH-W09", title: "Image by mutable tag", severity: .low, category: .workload,
            summary: "A container image is referenced by a tag (or `:latest`, or no tag) instead of a digest.",
            whyItMatters: "A tag can be moved to a different image at any time, so the same manifest can run different code tomorrow, and an attacker with registry access can replace what runs.",
            fix: ["Pin images by digest (`image@sha256:...`), and let your tooling update the digest.", "Never use `:latest` in production."],
            docsURL: "https://kubernetes.io/docs/concepts/containers/images/#image-names"),
        SecurityRule(
            id: "WH-W10", title: "Namespace without Pod Security Admission labels", severity: .medium, category: .workload,
            summary: "A namespace that runs Pods has none of the `pod-security.kubernetes.io/enforce`, `audit` or `warn` labels.",
            whyItMatters: "Without these labels the cluster does not check Pods in the namespace against the Pod Security Standards, so any of the risks above can be introduced unnoticed.",
            fix: ["Label the namespace, starting with `pod-security.kubernetes.io/warn: restricted` and `audit: restricted`, then `enforce: baseline` or `restricted` once workloads comply."],
            docsURL: "https://kubernetes.io/docs/concepts/security/pod-security-admission/"),
        SecurityRule(
            id: "WH-W11", title: "seccomp profile not set", severity: .low, category: .workload,
            summary: "A container has no `seccompProfile` (on the container or the Pod), or uses `Unconfined`.",
            whyItMatters: "Without a seccomp profile the container may call every system call, which widens the kernel attack surface.",
            fix: ["Set `securityContext.seccompProfile.type: RuntimeDefault` on the Pod."],
            docsURL: "https://kubernetes.io/docs/tutorials/security/seccomp/"),
    ]
}
