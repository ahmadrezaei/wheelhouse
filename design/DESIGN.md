# Wheelhouse — Product & UI Design Spec

> **Every cluster, at the helm.**
> Native iPhone + iPad app for operating a fleet of Kubernetes clusters.
> Status: **Design v1, for approval.** Visual board: `design/index.html` · Icons: `design/icon/*.svg`

---

## Contents

1. [Product goals & principles](#1-product-goals--principles)
2. [Information architecture & navigation](#2-information-architecture--navigation)
3. [Screen inventory](#3-screen-inventory)
4. [Screen specs](#4-screen-specs)
5. [Common states](#5-common-states)
6. [Key user flows](#6-key-user-flows)
7. [Safety model](#7-safety-model)
8. [Design system](#8-design-system)
9. [Widgets](#9-widgets)
10. [Notifications & background alerts](#10-notifications--background-alerts)
11. [Settings](#11-settings)
12. [Accessibility](#12-accessibility)
13. [Technical architecture notes for engineers](#13-technical-architecture-notes-for-engineers)
14. [Open questions](#14-open-questions)

---

## 1. Product goals & principles

**Who it is for.** Platform/SRE engineers and developers who run several clusters (prod, staging, homelab) and need to check, triage and fix things away from a laptop: on call, in a meeting, on the couch with an iPad and keyboard.

**Goals**

| # | Goal | Measured by |
|---|------|-------------|
| G1 | Know in **5 seconds** whether the fleet is OK | Fleet dashboard ranks problems first; widgets mirror it |
| G2 | Go from an alert to the cause in **3 taps** | Notification → pod → previous logs |
| G3 | Fix common issues safely from a phone | Scale, restart, rollback, edit-with-diff, drain, CronJob control |
| G4 | Never make a destructive change by accident | Context-rich confirmations, production type-to-confirm, read-only mode |
| G5 | Feel like an Apple app, not a web console | System components, Liquid Glass, SF Symbols, Dynamic Type |
| G6 | Be honest about iOS limits | Exec plugins, background refresh and suspended sessions are explained in the UI |

**Principles**

1. **Problems first.** Every list sorts by severity by default; healthy things are summarized, not listed.
2. **Context is always visible.** Cluster (with environment badge) and namespace appear on every resource screen.
3. **Explain, don't just show.** Rule-based diagnosis banners translate status (e.g. `OOMKilled`, `exit 137`, back-off) into plain language with the next step. No AI, no guessing — only derived from API fields.
4. **Dense where it matters, calm elsewhere.** Dashboards are information-dense; detail screens use standard grouped lists.
5. **Fewer components, reused everywhere.** One card, one list row, one status pill, one confirmation sheet.
6. **Degrade gracefully.** Missing metrics, RBAC gaps and unreachable clusters are expected states, not errors.

**Non-goals for v1:** Helm release management, multi-cluster bulk apply, cost reporting, running kubectl plugins, cluster provisioning, AI assistants.

---

## 2. Information architecture & navigation

### 2.1 Decision

| Context | Container | Why |
|---|---|---|
| iPhone (compact width) | `TabView` with 4 tabs + a `Tab(role: .search)`; floating Liquid Glass tab bar; each tab owns a `NavigationStack` | The app has four distinct jobs: scan the fleet, inspect one cluster, manage resources, keep long-running sessions. Tabs keep each job's stack intact when switching. |
| iPad (regular width) | `NavigationSplitView` with sidebar + content + detail | Clusters × resource sections is a two-level hierarchy that a sidebar-adaptable `TabView` cannot express; a true 3-column layout gives list + detail at once. |
| iPad compact (Slide Over, ⅓ Split View) | Falls back to the iPhone `TabView` | Same view models and routes; only the container differs. |

`.tabViewStyle(.sidebarAdaptable)` was considered and rejected: it collapses tabs into a flat sidebar, but we need disclosure groups per cluster and a content column.

### 2.2 iPhone tabs

| Tab | SF Symbol | Root | Pushes |
|---|---|---|---|
| **Fleet** | custom `wheelhouse.helm` | Fleet dashboard | Cluster dashboard → resource detail; Alerts inbox; Add Cluster (sheet); Settings (sheet) |
| **Cluster** | `gauge.with.dots.needle.67percent` | Dashboard of the *current cluster* (title is a cluster switcher menu) | Node / workload / event details |
| **Resources** | `square.stack.3d.up` | Section list for current cluster: Workloads, Networking, Config, Storage, Cluster, Access, Custom Resources | Kind list → detail → logs / shell / YAML / port-forward |
| **Sessions** | custom (terminal in stack) | Active port-forwards, shells, followed log streams | The session itself |
| **Search** | `magnifyingglass` | Search across names, labels, images in the current cluster; scope token “All clusters” | Result detail |

The tab bar minimizes on scroll (`.tabBarMinimizeBehavior(.onScrollDown)`). Full-screen tools (terminal, YAML editor, logs) hide it.

### 2.3 iPad columns

| Column | Content |
|---|---|
| **Sidebar** (floating glass) | Search field · Fleet · Alerts (badge) · Sessions (badge) · **Clusters** section: one row per cluster (status dot, name, env badge), disclosure → Overview, Workloads, Networking, Config, Storage, Cluster, Access, Custom Resources · Settings pinned at bottom |
| **Content** | Fleet: summary + attention + cluster list. Section selected: resource list with kind segmented chips, namespace picker, label filter, sort, search |
| **Detail** | Cluster dashboard (2-up card grid) or resource detail. Logs, shell and YAML open *in* the detail column, can split it (logs \| shell), or open in a new window (`openWindow`) |

Column widths (1180 pt landscape): sidebar 290, content 340, detail flexible (min 480). Sidebar collapses with ⌃⌘S or the toolbar button.

### 2.4 Navigation map

```
Fleet ─┬─ Alerts inbox ─ alert ─ resource
       ├─ Cluster card ─ Cluster dashboard ─ (failing workload | node | event) ─ detail
       ├─ Add Cluster (sheet) ─ Kubeconfig import | Token | Demo
       └─ Settings (sheet) ─ Cluster settings
Cluster ─ dashboard ─ same destinations as above
Resources ─ section ─ kind list ─ detail ─┬─ Logs
                                          ├─ Shell
                                          ├─ YAML editor ─ Review (diff + dry-run) ─ Apply
                                          ├─ Port-forward (sheet)
                                          └─ Action sheets (scale, restart, rollback, delete, drain…)
Sessions ─ port-forward ─ in-app browser | shell | log stream
```

**App-wide state:** `currentCluster`, `currentNamespace` (remembered per cluster; “All namespaces” allowed). Changing cluster in any tab updates Cluster/Resources tabs.

**Deep links:** `wheelhouse://cluster/{clusterID}[/ns/{ns}][/{kind}/{name}][?view=logs|yaml&container=…&previous=1]` — used by widgets, notifications, Spotlight and Shortcuts (App Intents: “Show failing pods in prod-eu-west”, “Scale deployment”). A link never opens an exec shell. Mutating intents always open the app to the confirmation sheet.

---

## 3. Screen inventory

| # | Screen | iPhone | iPad | Board |
|---|---|---|---|---|
| S1 | Welcome / onboarding | sheet | sheet | (flow) |
| S2 | Add Cluster — method + token form | ✓ | form sheet | ✓ |
| S3 | Kubeconfig import — choose contexts | ✓ | form sheet | ✓ |
| S4 | Fleet dashboard | ✓ | content+detail | ✓ L/D |
| S5 | Cluster dashboard | ✓ | detail | ✓ L/D |
| S6 | Alerts inbox | ✓ | content | (spec) |
| S7 | Resource sections | ✓ | sidebar | (spec) |
| S8 | Resource list (generic, per kind) | ✓ | content | ✓ Workloads |
| S9 | Workload detail (Deployment/StatefulSet/DaemonSet/ReplicaSet) | ✓ | detail | ✓ |
| S10 | Job / CronJob detail | ✓ | detail | (spec) |
| S11 | Pod detail | ✓ | detail | ✓ |
| S12 | Logs viewer | ✓ | detail / split / window | ✓ |
| S13 | Terminal (exec) | ✓ | detail / split / window | ✓ |
| S14 | YAML editor | ✓ | detail / window | ✓ |
| S15 | Review changes (diff + dry-run) | ✓ | detail | ✓ |
| S16 | Create from YAML | ✓ | sheet | (spec) |
| S17 | Nodes list / Node detail | ✓ | content/detail | ✓ |
| S18 | Drain sheet | ✓ | sheet | ✓ |
| S19 | Networking details (Service, Ingress, NetworkPolicy, Endpoints) | ✓ | detail | (spec) |
| S20 | Config details (ConfigMap, Secret) | ✓ | detail | ✓ Secret |
| S21 | Storage details (PV, PVC, StorageClass) | ✓ | detail | (spec) |
| S22 | Namespaces, Events, CRDs, custom resources | ✓ | content/detail | (spec) |
| S23 | Access (ServiceAccounts, Roles, ClusterRoles, Bindings) | ✓ | detail | (spec) |
| S24 | Sessions & port-forwards; in-app browser | ✓ | sidebar item | ✓ |
| S25 | Settings; Cluster settings | ✓ | sheet | ✓ |
| S26 | App lock | ✓ | ✓ | ✓ |
| S27 | Error states (unreachable, forbidden, TLS, auth expired) | ✓ | ✓ | ✓ 2 of 4 |
| S28 | iPad power layout (logs + shell split, menu bar) | — | ✓ | ✓ |

---

## 4. Screen specs

Each screen lists **purpose · content · components · actions**. States follow §5 unless stated.

### S1 Welcome
- **Purpose:** first launch. Icon, name, tagline, three value bullets (Fleet health · Fix safely · Logs & shell).
- **Actions:** `Add Cluster` (primary), `Explore Demo` (secondary — loads mock clusters, flagged “DEMO” everywhere), `Import from iCloud` (shown only if synced clusters exist).
- App Store review uses Demo mode; no network required.

### S2 Add Cluster — token
- **Method tiles:** Kubeconfig (Files · Paste · Share Sheet) · Token (URL + bearer) · Demo.
- **Form (inset grouped):** Name · API server URL (validated `https://host[:port]`) · Token (secure field, paste button, scans for JWT `exp` and shows expiry) · CA certificate (Files picker; PEM/CRT; shows subject + expiry) · **Skip TLS verification** toggle → inline critical banner (“Connection is not verified … prefer adding the CA”) and a permanent `UNVERIFIED TLS` badge on the cluster.
- **Safety:** Environment (Production / Staging / Development / Personal), Read-only mode, Sync with iCloud Keychain (off by default).
- **Connection test** (automatic after fields are valid, button to re-run): version, node/pod count, latency; RBAC capability checklist via `SelfSubjectRulesReview` (list/watch workloads, read secrets, exec & port-forward, delete); metrics-server found / Prometheus found / not found.
- **Actions:** Cancel, Add (enabled once test passes or user taps “Add anyway”).

### S3 Kubeconfig import
- **Sources:** document picker (`.yaml`, `.yml`, no extension, `config`), paste (detects YAML on clipboard), Share Sheet / “Open in Wheelhouse”, drag & drop on iPad.
- **Header card:** file name, location, counts (contexts, users, clusters).
- **Context list** with checkbox, monospaced context name, cluster + auth type, and a status pill:

| Status | Rule | UI |
|---|---|---|
| Ready | token, client-certificate(-data)/client-key(-data), basic auth disabled by default | checked by default |
| Local | server host is `127.0.0.1`, `localhost`, `::1`, `host.docker.internal`, `*.local` without LAN reachability | unchecked, warning text |
| Exec | `users[].user.exec` present | disabled, grey, “Uses exec plugin `aws eks get-token`” |
| Auth provider | `auth-provider` (legacy gcp/oidc/azure) | disabled; OIDC: offer “Paste ID token” |
| Missing file | `client-certificate: /path` file refs | disabled; “File paths can't be read — re-export with `--flatten`” |

- **Explanation card** (when any exec/auth-provider): why it can't work on iOS, copyable commands to create a ServiceAccount + token (`kubectl create token … --duration=8760h`), “Add with Token” jumps to S2 prefilled with the server URL and CA.
- **Footer:** “Credentials are copied into the Keychain on this device. The original file is not kept.” Primary: `Add N Clusters`.

### S4 Fleet dashboard
- **Toolbar:** Settings (left), Alerts bell with badge, Add (+).
- **Large title** “Fleet”, subtitle: live dot · N clusters · updated Xs ago (pull to refresh).
- **Fleet Health card:** donut of cluster health (Healthy / Degraded / Critical / Unreachable) with “4/5 reachable” in the center; legend with counts; “N clusters need attention”.
- **KPI grid (2×2):** Nodes Ready (38/39, NotReady count), Pods Running (1,493; pending + failing), CPU % (used of capacity cores, bar), Memory % (used of capacity Gi, bar).
- **Needs Attention** (max 6, “See All” → Alerts inbox), ranked critical → warning → unknown, then recency. Sources: CrashLoopBackOff / ImagePullBackOff / CreateContainerConfigError pods, NotReady nodes, node pressure conditions, Pending > 5 min, failed Jobs, Deployments below minAvailable, PVC Pending, certificate expiry < 30 days, kubelet version skew, unreachable clusters, expiring credentials.
- **Cluster cards** (one per cluster, user-orderable, pinned first): status dot, name, env badge, 6h CPU sparkline, chevron; meta line provider · version · nodes; CPU and Memory bars; pods running/total; one-line issue summary (or “All workloads healthy”). Unreachable card: grey, cached timestamp, `Retry`.
- **Fleet CPU (24h)** area chart: usage vs capacity with requests as dashed line (only clusters with Prometheus; footnote lists coverage).
- **Recent Warnings:** latest Warning events across clusters (reason, count, age, message, object).
- **Footnote:** metrics sources coverage.
- **Health rules (cluster status):** Critical = unreachable API with prod flag *or* any NotReady node *or* ≥1 Deployment with 0 available; Degraded = any attention item of warning severity; Healthy = none; Unreachable = last N probes failed (separate grey state, never “healthy”).

### S5 Cluster dashboard
- **Title:** cluster name with chevron → menu of clusters (status dots) + “Manage Clusters…”. Subtitle: env badge · provider · region · version · API latency.
- **KPI strip (4):** Nodes ready/total · Pods healthy/total · Deployments available/total · Warning events (1h).
- **Time range** segmented: 1H · 6H · 24H · 7D (history needs Prometheus; otherwise the control is hidden and charts show “live” sampling since app open).
- **CPU card:** used / allocatable cores + %, area chart, requests (dashed indigo), capacity = top of chart.
- **Memory card:** same, purple series.
- **Pods card:** stacked bar + legend: Healthy, CrashLoop, Pending, Failed, Completed; namespaces count.
- **Nodes · CPU heat map:** one tile per node (short name + %), teal intensity < 80 %, orange ≥ 80 %, red outline = NotReady; legend; instance type summary. > 30 nodes → tiles become 8 pt dots grouped by node pool.
- **Failing Workloads:** ready-ratio ring rows (Deployments, StatefulSets, DaemonSets), failed Jobs, Pending pods with reason.
- **Workloads summary:** Deployments, StatefulSets, DaemonSets, Jobs, CronJobs with healthy/total.
- **Top Pods · CPU** (vs limit) — toggle CPU / Memory.
- **Warning Events** (latest 4 + count).
- **Control Plane & Versions:** API server health (`/readyz`) + p50 latency, version skew (kubelet versions histogram), serving certificate expiry (from TLS handshake), credentials (type + expiry), client cert expiry if used.
- **Metrics footnote:** which sources are active and how they were found.
- **Toolbar:** Refresh, ⋯ (Cluster settings, Open in new window [iPad], Copy server URL).

### S6 Alerts inbox
Grouped by cluster, severity-sorted rows identical to “Needs Attention”, swipe to Mute (1h / 24h / until resolved), filter by severity. Shows when background checks last ran.

### S7 Resource sections
Inset grouped list of sections with counts and problem badges: **Workloads** (Pods, Deployments, StatefulSets, DaemonSets, ReplicaSets, Jobs, CronJobs) · **Networking** (Services, Ingresses, NetworkPolicies, Endpoints/EndpointSlices) · **Config** (ConfigMaps, Secrets) · **Storage** (PVs, PVCs, StorageClasses) · **Cluster** (Nodes, Namespaces, Events, CRDs) · **Access** (ServiceAccounts, Roles, ClusterRoles, RoleBindings, ClusterRoleBindings) · **Custom Resources** (grouped by API group; discovered via `/apis`). Kinds the user cannot `list` are shown with a lock and explain on tap.

### S8 Resource list (generic)
- **Header:** large title (kind or section), context line (env badge · cluster · count · sort).
- **Search** (name, label value, image; `/` focuses on iPad).
- **Filter chips:** Namespace picker (All / recent / pinned), label selector chip (free text with validation: `app=web,tier in (api,worker),!canary`), sort (Status · Name · Age · Restarts · CPU · Memory), kind chips when a section has several kinds.
- **Rows:** lead indicator (ready ring for controllers, status icon for pods/jobs/nodes), name (truncate middle for generated names), subtitle (namespace · key status · age), trailing metric (ready x/y, restarts, CPU).
- **Swipe actions:** Restart, Scale, Delete (red) — each opens the confirmation sheet (§7). Long-press: context menu with all actions + Copy Name / Copy YAML.
- **Watch-driven:** rows animate on change (respect Reduce Motion), “N new events” toast instead of jumping.
- iPad: `Table` variant when content column is wide (sortable columns).

### S9 Workload detail (Deployment shown)
- Context line → name (Title 2, 28pt) → status pill + availability + revision + age.
- **Action row** (5 glass tiles): Scale · Restart · Rollback · Logs · YAML; overflow ⋯: Pause/Resume rollout, Delete, Copy, Port-forward, Create Job (CronJob).
- **Diagnosis banner** (if degraded).
- **Replicas card:** segment per replica coloured by state, stepper (changes open a confirm with dry-run), strategy summary, HPA (min/max/current/target) if present.
- **Pods** list (status, restarts, node, age), “Logs for all” (multi-pod merged stream with pod prefix colours).
- **Rollout history:** revisions from ReplicaSets (`deployment.kubernetes.io/revision`), image, age, hash; `Roll Back` on older revisions (patches template to that ReplicaSet's template; StatefulSet/DaemonSet use ControllerRevisions).
- **Containers:** image, requests/limits (limit-risk highlighting), ports, probes, env sources (secret values never shown).
- **Conditions**, **Labels & Selector** (tap a label → filter list), **Annotations** (collapsed), **Events**.
- StatefulSet: ordinal pods, PVC templates, partition. DaemonSet: desired/current/ready/updated per node. ReplicaSet: owner link.

### S10 Job / CronJob detail
Job: completions, parallelism, duration, backoff, pods, failure reason; actions: Logs, Delete, Re-run (create a copy). CronJob: schedule (cron + human “Every day at 02:00 UTC”, next 3 runs, timezone), last schedule/success, active jobs, history; actions: **Suspend / Resume**, **Trigger now** (creates Job from template, name `<cronjob>-manual-<ts>`), Edit schedule.

### S11 Pod detail
- Name in monospace, status pill, restarts, age.
- **Action row:** Logs · Shell (disabled with explanation if container not running) · Forward · YAML · Delete (red).
- **Diagnosis banner:** e.g. “OOMKilled · exit 137 · memory peaked at 255Mi of 256Mi limit · next restart in 4m 12s” with link to previous logs.
- **Containers** (incl. init + ephemeral): state, last state, restarts, image; tap → container sheet (env, mounts, probes, resources).
- **Usage** (metrics-server live; Prometheus history sparkline): CPU and memory bars with request marker and limit track end.
- **Details:** node, pod IP(s), QoS, service account, priority, controlled-by (link), tolerations / node selector (collapsed).
- **Volumes**, **Events**.

### S12 Logs viewer
- Toolbar: back, title “Logs” + pod, Share (export .log), ⋯ (font size, max lines, download full).
- Chips: **Container** picker · **Previous** (previous instance; auto-suggested when CrashLooping) · **Timestamps** · **Wrap** · **Since** (5m / 1h / 6h / all / custom) · multi-pod source when opened from a workload.
- **Search field:** live highlight, match count, ↑/↓ navigation, regex toggle, “show matching lines only”.
- Lines: timestamp (dim), level badge (parsed from common formats: `level=`, `INFO|WARN|ERROR`, JSON `"level"`), message. ERROR rows tinted; JSON lines pretty-print on tap.
- Divider markers: “Container terminated · OOMKilled · exit 137”, “Container restarted”, “Stream reconnected”.
- **Follow** mode: auto-scroll; scrolling up pauses and shows a floating glass “Jump to Live / N new lines” capsule.
- Limits: ring buffer of 50k lines in memory; older lines dropped with a notice.
- iPad: ⌘F search, ⌘K clear, ⌘↓ jump to live, ⌘+/– font.

### S13 Terminal (exec)
- Full-bleed SwiftTerm view, theme “Wheelhouse Dark” (bg `#0A0E13`, prompt seafoam), monospace 12–16 pt (pinch to zoom).
- Header line printed by the app: pod, container, shell, protocol, size.
- Toolbar: back, title “container · shell”, keyboard toggle, ⋯ (shell picker sh/bash/ash with auto-fallback, container picker, copy all, font size, reconnect).
- **iPhone extra key row** (input accessory): `Esc` `Ctrl` (sticky modifier; double-tap locks) `Tab` `←` `↑` `↓` `→` `|` `~` `/` `-`; long-press for `Alt`, `Home/End`, `PgUp/PgDn`, `F1–F12`.
- **iPad hardware keyboard:** full passthrough including Ctrl/Alt/Esc (`UIKeyCommand` with `wantsPriorityOverSystemBehavior`), accessory row hidden, ⌘C/⌘V copy/paste, ⌘K clear, ⌘W close session.
- Resize sends terminal size on the resize channel. Disconnect → overlay “Session ended (exit 0)” + Reconnect.
- If the pod's container isn't running: “Can't open a shell — container is waiting (CrashLoopBackOff). Open a shell in a running replica?” (picks a Ready sibling) or “Debug with ephemeral container…” (v1.1, needs `pods/ephemeralcontainers` permission).

### S14 YAML editor
- Toolbar: Cancel, title + “Edited · N changes”, **Review** (primary).
- Segmented **Edit | Diff**.
- Editor: line numbers, current-line highlight, syntax colours (keys, strings, numbers, booleans/null, comments), indentation guides, folding, bracket/quote pairing, soft-tab 2 spaces, inline lint errors from Yams parse (red squiggle + gutter dot).
- `metadata.managedFields`, `status`, `resourceVersion`, `uid`, `creationTimestamp` are hidden (toggle “Show server fields”, read-only).
- Keyboard accessory (iPhone): ⇥, ⇤, `-`, `:`, `"`, `#`, Find, Undo, dismiss.
- Read-only clusters and missing `update/patch` permission → editor opens read-only with banner.

### S15 Review changes
- Server **dry-run** result banner (success / validation errors with field paths / admission webhook denial message).
- **Unified diff** vs live object (fetched fresh; line numbers old/new, collapsed unchanged ranges) — iPad shows side-by-side.
- Summary rows: Apply method (**Replace / `PUT` with the object's `resourceVersion`**, optimistic concurrency; no server-side apply), field managers on the object (e.g. `argocd`, `helm`) → a banner warns that GitOps may revert the change, effect (“New rollout (rev 15)”). A `409 Conflict` re-fetches the live object and offers Rebase; fields that changed on both sides are listed in the review before Apply.
- Production banner; **Apply to `<cluster>`** primary → confirmation sheet (§7).
- If the object changed while editing (resourceVersion mismatch): “Changed on the server” with “Rebase my edits” / “Discard”.

### S16 Create from YAML
Blank editor or template picker (Deployment, Service, ConfigMap, Secret, Job, CronJob, Ingress, NetworkPolicy, PVC), multi-document support (`---`), target namespace picker (overrides missing `metadata.namespace`), dry-run per document, results list.

### S17 Nodes
- **List:** summary strip (Ready, NotReady, Cordoned, Pressure), search (name, label, taint), node-pool chips (from well-known labels: `cloud.google.com/gke-nodepool`, `eks.amazonaws.com/nodegroup`, `agentpool`, `node.kubernetes.io/instance-type`), rows with status icon, name, conditions/instance/zone subtitle, CPU and MEM mini meters. Swipe: Cordon/Uncordon.
- **Detail:** status pill, zone, instance type, kubelet version; actions Cordon/Uncordon · Drain · Pods · YAML; conditions; capacity vs allocatable vs requested (bars); taints; labels; pods on node (sorted by usage); events; OS/kernel/container runtime; age.

### S18 Drain sheet
- Explains: cordon, then evict via Eviction API (respects PDBs).
- Context: cluster (env badge), node, pods to evict (and DaemonSet pods skipped, mirror/static pods skipped).
- Options: Ignore DaemonSets (on), Delete emptyDir data (off; lists affected pods), Force unmanaged pods (off; lists them), Grace period (pod default / custom), Timeout (5 min).
- **PDB pre-check:** lists PDBs with `disruptionsAllowed == 0` and which pods will wait.
- Production: type the node name. Primary: **Cordon & Drain** (disabled until valid).
- **Progress state:** per-pod rows (Evicting → Terminating → Gone / Blocked by PDB (retrying) / Failed), overall progress, Cancel (stops evicting; node stays cordoned), completion: “Drained · Uncordon later from the node screen”. Draining continues only while the app is foregrounded — stated in the sheet; a Live Activity shows progress.

### S19 Networking
Service: type, cluster IP, external IP/LB hostname, ports (tap → port-forward), selector → matched pods, endpoints readiness. Ingress: class, hosts/paths table → backend service (tap to open), TLS secrets with cert expiry, LB address, “Open URL” in Safari. NetworkPolicy: pod selector, policy types, ingress/egress rules rendered as readable sentences (“Allow from pods `app=web` in namespace `checkout` on TCP 8080”). Endpoints/EndpointSlices: addresses with ready/serving/terminating.

### S20 Config
ConfigMap: keys list, value viewer (text/JSON/YAML auto-detect, monospace, copy), used-by. **Secret:** type pill, keys list with values **masked by default**; Reveal / Copy require Face ID (`LAContext` per action, or “for this session” option); values base64-decoded; TLS secrets show certificate summary (subject, SANs, expiry) without revealing the key; dockerconfigjson shows registries only. Copied values auto-clear after 60 s (`UIPasteboard` expiration, `localOnly`). Never shown in widgets, notifications, logs or screenshots (screen content hidden when the app resigns active).

### S21 Storage
PVC: status, capacity, access modes, storage class, bound PV, used by pods, usage % (if kubelet volume stats via Prometheus). PV: reclaim policy, source, claim. StorageClass: provisioner, default badge, binding mode, expansion.

### S22 Cluster: Namespaces, Events, CRDs, custom resources
Namespaces: status, labels, resource counts, quotas/limit ranges; actions: set as current, delete (type name always). Events: filter Warning/Normal, reason chips, involved object links, grouped by object. CRDs: group, versions, scope, instance count → generic list of custom resources (columns from `additionalPrinterColumns`), generic detail (status conditions if present, YAML).

### S23 Access
ServiceAccounts (secrets/tokens, image pull secrets, bound roles), Roles/ClusterRoles (rules rendered as a verb × resource matrix), Bindings (subjects → role). “Who can…?” helper (v1.1) using SubjectAccessReview when permitted.

### S24 Sessions & port-forwards
- Honest banner about background suspension.
- **Port Forwards:** `svc/name :port` → `localhost:<local>`, cluster, traffic counters; buttons: Open in in-app browser (HTTP/HTTPS ports), Copy address, Stop. Status: Active / Reconnecting / Suspended.
- **New Port Forward** sheet: source (pod/service; services resolve to a ready backing pod and re-resolve on pod change), remote port (picker from spec), local port (default same, or next free ≥ 1024), protocol hint.
- Suggestions from well-known services/ports (grafana 3000, prometheus 9090, argocd-server 443, kiali 20001).
- **In-app browser:** `WKWebView` with glass toolbar (URL, reload, share, “Open externally” disabled for localhost), shows which forward it uses, accepts self-signed certs for localhost forwards only after a prompt.
- **Shells** (resume), **Log Streams** (resume), **Recent** (ended).

### S25 Settings & S26 App lock — see §11. S27 error states — see §5. S28 iPad power layout — see §2.3 and §8.9.

---

## 5. Common states

Every data screen implements these states with the same components (`ContentUnavailableView` + banner):

| State | Trigger | UI | Actions |
|---|---|---|---|
| **Loading (first)** | No cache | Skeleton rows/cards (redacted placeholder), no spinners > 300 ms | — |
| **Refreshing** | Cache present | Cached content + subtle “Updating…” in subtitle | — |
| **Empty** | List returns 0 | Icon + “No Deployments in payments” + hint | Change namespace, Create from YAML |
| **Filtered empty** | 0 after filters | “No matches for `tier=backend`” | Clear filters |
| **Forbidden (403)** | RBAC | `hand.raised` + subject, verb, resource, namespace; raw message in code box; capability list from SelfSubjectRulesReview | Switch namespace, Copy RBAC rule (Role + RoleBinding YAML) |
| **Partially forbidden** | Some kinds/namespaces denied | Inline banner “Some namespaces hidden (no list permission)” | Details |
| **Unauthorized (401)** | Token expired/revoked | “Credentials for X expired on …” | Update credentials |
| **Unreachable** | DNS / TCP / timeout | `wifi.slash` + cause; diagnostics list DNS → TCP → TLS → Auth → API; localhost explanation when relevant | Retry, Edit connection |
| **TLS error** | Untrusted / hostname mismatch / expired | Certificate summary (subject, issuer, SHA-256, expiry) | Add CA, Trust this certificate (pin), Skip verification (with warning) |
| **Cached / stale** | Unreachable but cache exists | Content dimmed, “cached 2 h ago” chip, actions disabled | Retry |
| **Partial metrics** | metrics-server only | Charts show live samples since open; “History needs Prometheus” chip → cluster settings | Configure |
| **No metrics** | Neither found | Usage tiles show requests/limits only (“Requested 61%”), banner explains how to install metrics-server | Learn more |
| **Read-only cluster** | Per-cluster flag | `READ-ONLY` badge in context line; mutating actions hidden (not just disabled) | Turn off in cluster settings |
| **Demo** | Demo mode | `DEMO` badge, banner on first screen | Exit demo |
| **Offline device** | `NWPathMonitor` unsatisfied | Global banner under nav bar | — |

---

## 6. Key user flows

### F1 Onboarding & add cluster
1. Welcome → **Add Cluster** (or **Explore Demo**).
2. Choose Kubeconfig / Token.
3. Token path: enter name, URL, token, CA (or skip-TLS with warning) → auto connection test (version, RBAC, metrics).
4. Choose environment (Production prompts: “Destructive actions will require typing names”), read-only, iCloud sync.
5. **Add** → Fleet dashboard with the new cluster card animating in; first-run tip on the cluster card (“Tap for details, long-press to reorder”).
6. After the first cluster, prompt once to enable App Lock and Notifications (two separate, skippable cards).

### F2 Kubeconfig import
Files / Paste / Share Sheet → parse → per-context validation (Ready / Local / Exec / Auth-provider / Missing file) → select contexts → per-context environment suggestion (name contains `prod` → Production) → connection tests run in parallel with per-row results → **Add N clusters** → Keychain → Fleet. Exec contexts: explanation card → “Add with Token” prefilled.

### F3 Triage a CrashLoop pod
1. Notification “prod-eu-west · CrashLoopBackOff · payments-api…” (or Fleet → Needs Attention).
2. Tap → **Pod detail** (deep link) with diagnosis banner “OOMKilled · exit 137 …”.
3. **Previous logs** → Logs viewer opens with Previous on; search “OutOfMemory” → match highlighted near the termination divider.
4. Back → Deployment (controlled-by link) → **YAML** → change memory limit → **Review** (dry-run passes, diff shows limit change) → **Apply** → production type-to-confirm → rollout progress toast with live replica segments.
5. Alternative quick fix: **Restart** (confirmation sheet) or **Rollback** to revision 13.

### F4 Edit YAML → diff → apply
YAML action → editor (lint live) → **Review** → server dry-run (`dryRun=All`) → diff vs live → `resourceVersion` conflict check (409 → rebase) → confirm (production: type name) → apply (`PUT` replace with the fetched `resourceVersion`) → success toast with “View rollout” / errors mapped to line numbers.

### F5 Drain a node
Nodes (or NotReady alert) → node detail → **Drain** → sheet: pods to evict, options, PDB pre-check → type node name (prod) → Cordon & Drain → per-pod progress (eviction retries on 429 from PDBs with back-off) → done; node shows `SchedulingDisabled` and an **Uncordon** action.

### F6 Port-forward
Service or pod → **Forward** → choose remote port + local port → session starts (Sessions tab badge) → **Open in Browser** (in-app) → browsing works while app is foreground → leaving the app suspends; returning auto-reconnects → Stop.

---

## 7. Safety model

| Layer | Rule |
|---|---|
| **Context everywhere** | Context line (env badge · cluster · namespace · kind) on every resource screen and every sheet. Production badge is filled rose with a shield icon — never used for anything else. |
| **Confirmation sheet** (single component) | Title (“Restart payments-api?”), one-sentence effect, table: Cluster (badge) · Namespace · Resource (`kind/name`) · extra facts (replicas, pods affected), dry-run result, primary button labelled with the verb (“Restart Rollout”, “Delete Pod”, “Cordon & Drain”). Destructive verbs use the red button. |
| **Production** | **Every** mutation on a Production cluster (scale up or down, restart, rollback, delete, apply, drain, cordon / uncordon, suspend / resume, pause / resume rollout, trigger, create, and Undo from a toast) requires typing the resource name; field turns green on match; button disabled until then. There is no “non-disruptive” exemption and it cannot be disabled for Production. The one exception is opening an interactive shell (Exec): the confirmation sheet (warning, facts, `pods/exec` access review) uses a plain **Open Shell** button instead of typing the pod name, because typing is impractical on a phone. Optional for other environments. |
| **Live configuration** | Confirmation sheets and open screens always use the cluster's *current* settings: switching a cluster to Read-only or Production while a screen or sheet is open takes effect immediately (screens rebuild; the sheet re-checks before it runs). |
| **App lock** | The lock screen and the app-switcher privacy cover live in a separate overlay window above everything (sheets included) in every scene. Deep links and notification taps received while locked are held and replayed after unlock; links can never open a shell. |
| **Read-only mode** | Per cluster. Hides all mutating UI and the HTTP client refuses non-GET/WATCH verbs (defence in depth). Exec and port-forward are also blocked unless “Allow exec/port-forward in read-only” is on. |
| **Dry-run first** | Every apply/scale/patch runs a server dry-run before the confirm button enables; failures are shown in the sheet. |
| **Bulk actions** | Multi-select delete shows the full list and count; production requires typing the count. |
| **Undo where possible** | After scale/suspend/cordon, a 6 s “Undo” toast. Undo is **not** a shortcut: it opens the same confirmation sheet for the inverse action (dry-run, typed confirmation on Production). Delete is never undoable — said explicitly. |
| **Audit** | Local activity log (Settings → Activity) of every mutating request: time, cluster, verb, object, result. Never synced, never contains payload secrets. |
| **Secrets** | Masked, Face ID to reveal/copy, excluded from widgets/notifications/search index/state restoration snapshots. |

---

## 8. Design system

### 8.1 Colour tokens

System semantic colours for surfaces and text (`systemGroupedBackground`, `secondarySystemGroupedBackground`, `label`, `secondaryLabel`, `tertiaryLabel`, `separator`, `quaternarySystemFill`). Brand and status tokens live in the asset catalog with light/dark (and increased-contrast) variants:

| Token | Light | Dark | Use |
|---|---|---|---|
| `tint` (AccentColor) | `#0E8F89` | `#2DD4BF` | Primary actions, selection, links, CPU series |
| `onTint` | `#FFFFFF` | `#032622` | Text/icons on tint fills |
| `tintText` | `#0B7A75` | `#2DD4BF` | Tint-coloured text on light surfaces (AA) |
| `brand.navy` | `#0B2545` | — | Icon, splash |
| `brand.seafoam` | `#6EF0DC` | `#7DF5E2` | Icon highlights only |
| `status.healthy` / `…Text` | `#34C759` / `#1B8136` | `#30D158` / `#30D158` | Fills / text |
| `status.warning` / `…Text` | `#FF9500` / `#A85600` | `#FF9F0A` / `#FFB340` | |
| `status.critical` / `…Text` | `#FF3B30` / `#CC1F2B` | `#FF453A` / `#FF6B63` | |
| `status.unknown` / `…Text` | `#8E8E93` / `#6C6C70` | `#8E8E93` / `#AEAEB2` | Unreachable, stale, suspended |
| `status.info` / `…Text` | `#007AFF` / `#0060C7` | `#0A84FF` / `#409CFF` | Informational banners |
| `env.production` | `#D3245A` | `#FF4D7D` | Production badge + type-to-confirm only |
| `env.staging` | `#5856D6` | `#5E5CE6` | Staging badge |
| `env.development` | = tint | = tint | Dev badge |
| `env.personal` | `quaternarySystemFill` + `secondaryLabel` | | Home/personal badge |
| `chart.cpu` | = tint | | |
| `chart.memory` | `#AF52DE` | `#BF5AF2` | |
| `chart.requests` | `#5856D6` dashed 4/3 | `#5E5CE6` | Reference line |
| `chart.capacity` | `separator` | | Gridline at 100 % |
| `diff.add` / `diff.del` | green 16 % / red 13 % | 20 % / 20 % | Diff backgrounds |
| `log.highlight` / `current` | yellow 45 % / orange | 40 % / orange | Search matches |
| `terminal.bg` / `fg` / `prompt` | `#0A0E13` / `#D5DEE8` / `#5EEAD4` | same | Terminal theme |

Rules: status is always **colour + symbol + text**. Status *fills* (dots, bars, chart marks) use the base colour; status *text* uses the `…Text` variant for ≥ 4.5:1 contrast. Badge backgrounds are 15 % tints of the base colour.

### 8.2 Typography (SF Pro, Dynamic Type)

| Style | Size/weight (Large) | Use |
|---|---|---|
| `.largeTitle` bold | 34 | Tab roots, dashboards |
| `.title` / `.title2` bold | 28 / 22 | Resource names on detail screens (28 on iPhone detail, 22 in lists of headers) |
| `.title3` semibold | 20 | Section headers (“Needs Attention”) |
| `.headline` | 17 semibold | Card titles, cluster names |
| `.body` | 17 | List primary text |
| `.subheadline` | 15 | Chips, secondary rows |
| `.footnote` | 13 | Subtitles, events, footers |
| `.caption` / `.caption2` | 12 / 11 | Chart axes, legends, meters |
| KPI numerals | `.title2.bold().monospacedDigit()` | Counters, percentages |
| Code, logs, names of generated objects | `.system(.footnote, design: .monospaced)` (12–13) | YAML, logs, pod names, IPs |
| Terminal | SF Mono 12–16 (user setting, pinch) | |

Dynamic Type up to AX5: KPI grids reflow 4 → 2 → 1 columns; list rows move trailing metrics below the title; charts keep fixed height but axes labels scale; heat-map tiles switch to a list at AX sizes.

### 8.3 Spacing, radii, layout

| Token | Value |
|---|---|
| Spacing scale | 4 · 8 · 12 · 16 · 20 · 24 · 32 |
| Screen margins | 16 (iPhone), 20 (iPad columns) — use `.scenePadding()` / safe area |
| Card padding | 14 × 16 |
| Gap between cards | 12 |
| `radius.card` | 24, concentric (`ConcentricRectangle` / `.containerShape`) |
| `radius.tile` | 18–20 (KPI, action tiles) |
| Controls | Capsule (glass buttons 44 pt, chips 34 pt, segmented 36 pt) |
| `radius.small` | 8–10 (row icons, heat tiles), 12 (code boxes, fields 14) |
| Min hit target | 44 × 44 pt |

### 8.4 Liquid Glass usage rules

1. Glass **only** on the navigation/control layer: toolbars and their buttons, floating tab bar and search button, iPad sidebar, sheets, menus, context menus, HUDs (Face ID), floating capsules (“Jump to Live”, YAML key row).
2. Content (cards, lists, charts, code, logs, terminal) is opaque grouped surfaces — legibility first.
3. No glass on glass. Group toolbar buttons into one capsule (`GlassEffectContainer`) rather than many bubbles.
4. Tinted glass (`.glassProminent` / `.buttonStyle(.glassProminent)` with tint) only for the single primary action of a screen (Apply, Add, Review, Done).
5. Scroll-edge effect under toolbars (`.scrollEdgeEffectStyle(.soft)`); dashboards use the soft edge, code/logs use hard edge.
6. Reduce Transparency → glass becomes solid `secondarySystemBackground` with a hairline border (system handles most; custom capsules must follow).

### 8.5 Components (built once, reused)

| Component | Notes |
|---|---|
| `StatusPill(status, text, symbol)` | 22 pt capsule, 15 % tinted fill |
| `EnvBadge(env)` | 19 pt, caps, Production filled + shield |
| `ContextLine(cluster, namespace, kind)` | Under nav bar on resource screens |
| `KPITile(label, value, caption, meter?)` | 2×2 / 4-up grids |
| `Meter(value, request?, limit?)` | 4–8 pt bar, request marker, warn/crit colouring at 85 / 95 % |
| `ReadyRing(ready, desired)` | 32 pt ring, colour by ratio |
| `ResourceRow` | lead indicator · title/subtitle · trailing metric · chevron; swipe + context menu |
| `ClusterCard` | Fleet + iPad content column |
| `DiagnosisBanner` | Rule-based explanation + deep link |
| `ConfirmSheet` | §7; one implementation for all actions |
| `MetricChart` | Swift Charts AreaMark + LineMark + RuleMark (requests) ; selection via `chartXSelection` |
| `HeatGrid` | Node tiles |
| `CodeView` / `DiffView` / `LogView` | TextKit 2 based, monospaced |
| `EmptyState` | `ContentUnavailableView` styles per §5 |
| `GlassActionRow` | 4–5 action tiles under a detail header |

### 8.6 Iconography (SF Symbols)

| Kind / action | Symbol | Kind / action | Symbol |
|---|---|---|---|
| Fleet (tab) | custom `wheelhouse.helm` | Cluster (tab) | `gauge.with.dots.needle.67percent` |
| Resources (tab) | `square.stack.3d.up` | Sessions (tab) | `apple.terminal.on.rectangle` |
| Pod | `cube` | Deployment | `square.stack.3d.up` |
| ReplicaSet | `square.on.square` | StatefulSet | `cylinder.split.1x2` |
| DaemonSet | `circle.grid.3x3` | Job | `checkmark.square` |
| CronJob | `calendar.badge.clock` | Service | `point.3.connected.trianglepath.dotted` |
| Ingress | `arrow.right.to.line` | NetworkPolicy | `shield.lefthalf.filled` |
| Endpoints | `dot.radiowaves.left.and.right` | ConfigMap | `doc.plaintext` |
| Secret | `key` | PersistentVolume | `externaldrive` |
| PVC | `cylinder` | StorageClass | `tray.2` |
| Node | `server.rack` | Namespace | `folder` |
| Event | `bolt` | CRD / custom resource | `puzzlepiece.extension` / `cube.transparent` |
| ServiceAccount | `person.crop.circle` | Role / ClusterRole | `lock.shield` |
| RoleBinding | `link` | Logs | `text.alignleft` |
| Shell | `apple.terminal` | Port-forward | `arrow.left.arrow.right` |
| YAML | `curlybraces` | Scale | `plus.forwardslash.minus` |
| Restart | `arrow.triangle.2.circlepath` | Rollback | `arrow.uturn.backward` |
| Delete | `trash` | Cordon | `nosign` |
| Drain | `arrow.down.to.line` | Suspend / Resume / Trigger | `pause.circle` / `play.circle` / `play.circle.fill` |
| Healthy / Warning / Critical / Unknown | `checkmark.circle.fill` / `exclamationmark.triangle.fill` / `xmark.octagon.fill` / `questionmark.circle` | Unreachable | `wifi.slash` |
| Forbidden | `hand.raised` | Certificate | `checkmark.seal` |

Rendering: hierarchical by default; status symbols palette-rendered with status colours; `symbolEffect(.pulse)` only for live/following indicators (off with Reduce Motion).

### 8.7 Motion
Spring defaults; list changes use `.animation(.snappy)`; KPI numbers use `.contentTransition(.numericText())`; no looping animations except the live dot (static under Reduce Motion).

### 8.8 App icon
Six-spoke ship's helm in glass (rim + hexagonal hub) whose spoke handles are hexagonal **cluster nodes**, on a deep navy → teal gradient with a faint compass bearing ring. Not derived from the Kubernetes logo (no heptagon, no seven spokes). Delivered as `AppIcon.svg` (default), `AppIcon-dark.svg`, `AppIcon-tinted.svg` (grayscale; system applies tint). For Icon Composer split into layers: background, bearing ring, wheel (rim+spokes), handles, hub — enabling Liquid Glass specular/translucency per layer.

### 8.9 iPad specifics
- **Keyboard shortcuts** (all in the menu bar, discoverable by holding ⌘):

| Shortcut | Command | Shortcut | Command |
|---|---|---|---|
| ⌘1…⌘9 | Switch to cluster 1–9 | ⌘0 | Fleet |
| ⌘F | Search in list / logs | ⌘R | Refresh |
| ⌘N | Create from YAML | ⇧⌘N | Add Cluster |
| ⌘L | Show logs | ⌥⌘T | Open shell |
| ⌥⌘P | Port forward… | ⌘E | Edit YAML |
| ⌥⌘S | Scale… | ⌥⌘R | Restart rollout… |
| ⇧⌘C | Copy name | ⌘⌫ | Delete… |
| ⌃⌘S | Toggle sidebar | ⌘[ / ⌘] | Back / forward |
| ⌘↑ / ⌘↓ | Previous / next item in list | ⌘W | Close session/window |
| ⌥⌘N | Namespace picker | ⇧⌘L | Label filter |

- **Pointer:** hover effects on rows, glass buttons and chart marks (tooltip with value), right-click = context menu, drag a pod onto a split pane to open logs/shell there.
- **Multi-window:** `WindowGroup(for: ResourceRef.self)` for logs, shell, YAML; Stage Manager-friendly minimum sizes (logs 480×320, shell 520×320).
- **Power layout:** detail column splits into two panes (logs \| shell, or YAML \| diff) with a draggable divider.

---

## 9. Widgets

Built with WidgetKit + App Intents (configurable cluster). Data comes from a **snapshot written by the app and BGAppRefresh into the App Group container** (`group.app.wheelhouse`) — widgets never hold credentials or call the API themselves. Each widget shows “Updated hh:mm”; stale > 2 h shows a grey state. Tap targets deep link (§2.4).

| Family | Name | Content |
|---|---|---|
| `systemSmall` | Cluster Health | Status dot + name + status word; CPU and memory rings; failing pod count; nodes ready |
| `systemSmall` | Fleet | “N need attention” + cluster list with status dots |
| `systemMedium` | Fleet Overview | Fleet donut (reachable count) + 4 clusters with CPU bars |
| `systemLarge` | Failing Pods | Cluster header with env badge; FAILING / CPU / MEMORY / NODES stats; failing pods list (reason + restarts); node CPU strip |
| `accessoryCircular` | CPU gauge | Gauge 0–100 with value; or failing count with `xmark.octagon` |
| `accessoryRectangular` | Cluster summary | Name, top issue, nodes · CPU |
| `accessoryInline` | Fleet status | “⚠ 2 need attention” / “All 5 clusters healthy” |

Rendering modes: full colour, accented (tint applied to status layer via `widgetAccentable`), vibrant (Lock Screen), clear/tinted Home Screen (status colours collapse — symbols carry meaning). Optional **Live Activity** for drain/rollout progress.

---

## 10. Notifications & background alerts

**Honest scope (shown in Settings and onboarding):** iOS lets Wheelhouse check clusters in the background only when the system decides (BGAppRefreshTask; typically every 15 min to several hours, less in Low Power Mode, never after the user force-quits). Alerts are best-effort and not a pager replacement. A future option is push via a user-hosted relay (out of scope for v1).

| Rule (default on) | Detection | Interruption level | Grouping |
|---|---|---|---|
| CrashLoopBackOff | waiting reason CrashLoopBackOff and restarts increased ≥ 3 since last check | Time Sensitive | per cluster (`threadIdentifier = clusterID`) |
| Node NotReady | Ready condition False/Unknown > 5 min | Time Sensitive | per cluster |
| Job failed | Job condition Failed since last check | Active | per cluster |
| Cluster unreachable (opt-in) | 3 consecutive failures | Passive | fleet |
| Cert / credential expiry (opt-in) | < 14 days | Passive | fleet |

- Content: title `prod-eu-west · CrashLoopBackOff`, body `payments-api-7d9f8c6b5-x2k4q restarted 5× in 10 min (OOMKilled).` No secret values, no YAML. Option “Hide details on Lock Screen” → “An issue was detected in a production cluster”.
- Actions (category): **View Logs**, **Open Pod**, **Mute for 1 h** (mute works in background). No mutating actions from notifications.
- De-duplication by `(cluster, kind, namespace, name, reason)`; resolved alerts clear delivered notifications.
- Quiet hours; per-cluster opt-in; per-rule toggles; summary when > 5 alerts (“7 issues across 2 clusters”).
- Background budget: 25 s per refresh; queries are targeted (`fieldSelector`, `limit`), clusters checked in parallel with per-cluster timeout of 8 s; results also refresh the widget snapshot.

---

## 11. Settings

| Section | Items |
|---|---|
| **Clusters** | Ordered list (status dot, env badge) → Cluster settings; Add Cluster; Import kubeconfig |
| **Security** | App Lock (Face ID / Touch ID / Optic ID; falls back to passcode), Require unlock (Immediately / 1 min / 5 min / 15 min), Reveal secrets (Each time / Once per session), Hide content in App Switcher, Activity log |
| **iCloud** | iCloud Keychain sync summary (N of M clusters) → per-cluster toggles; explanation: “Cluster list and credentials sync end-to-end encrypted via iCloud Keychain to your devices signed in with the same Apple Account. Turning sync off removes the item from iCloud, not from this device.” |
| **Background Alerts** | Master toggle, Rules (per rule toggles + thresholds), Quiet hours, Lock-screen privacy, last background check time, honest footnote |
| **General** | Refresh interval (5/10/30 s/manual), default namespace behaviour (remember per cluster / always All), log font size & max lines, terminal theme & font, YAML editor options, Units (Gi vs GB, cores vs millicores) |
| **Demo Mode** | Toggle; reset demo data |
| **About** | Version, Privacy (“No analytics or tracking. Credentials never leave your devices except via iCloud Keychain if enabled.”), Acknowledgements (SwiftTerm, Yams licences), Support |

**Cluster settings:** name, icon/colour; Connection (server, auth type, token/cert expiry, TLS status, Update credentials, Re-test); Safety (Environment, Read-only, Type-to-confirm — locked on for Production, Allow exec/port-forward in read-only); Metrics (live source status; History: Auto-discover / Custom URL + token / Off; discovered Prometheus endpoint); Sync with iCloud Keychain; Background alerts for this cluster; Default namespace; Pinned namespaces; Remove cluster (deletes Keychain items; asks whether to remove from iCloud too).

---

## 12. Accessibility

- **VoiceOver**
  - Charts: `.accessibilityChartDescriptor` with title, axes, summary (“CPU last 6 hours, 29.3 of 48 cores, 61 percent, peak 66 percent at 08:10, requests 34.1 cores”) and Audio Graphs support.
  - Donut: “Fleet health: 1 healthy, 2 degraded, 1 critical, 1 unreachable.” Heat map: one element per node “ip-10-2-22-61, CPU 88 percent, above 80 percent”; rotor to jump to hot/NotReady nodes.
  - Rows combine into one element: “payments-api, Deployment, namespace payments, degraded, 2 of 3 ready, 1 pod CrashLoopBackOff.” Swipe actions exposed as custom actions.
  - Status pills read as text, not colour; env badge reads “Production cluster”.
  - Logs/terminal: per-line navigation; terminal supports VoiceOver reading of last output (“Speak last command output” custom action).
  - Confirmation sheet announces cluster, namespace and resource first.
- **Dynamic Type** to AX5 (§8.2); no truncation of critical info — names truncate in the middle and are always available in full via long-press/accessibility label.
- **Reduce Motion:** no pulsing dot, no numeric roll, cross-fades instead of slides for list updates; charts don't animate in.
- **Reduce Transparency:** glass → opaque materials (§8.4). **Increase Contrast:** high-contrast colour variants in asset catalog, heavier separators, status text uses darker/lighter variants.
- **Differentiate Without Color:** heat-map tiles gain pattern (diagonal hatch ≥ 80 %, outline for NotReady); diff lines keep `+`/`-` signs.
- Full keyboard access and Voice Control labels on all glass buttons; minimum 44 pt targets; Smart Invert-safe terminal and icons.
- Localization-ready (String Catalogs), RTL mirrored layouts (except code, logs, terminal and charts' time axis).

---

## 13. Technical architecture notes for engineers

**Stack:** Swift 6 (strict concurrency), SwiftUI + Observation (`@Observable`), iOS/iPadOS 27 minimum, Swift Charts, WidgetKit, App Intents, BackgroundTasks, LocalAuthentication, Security, Network. Targets: App, Widget extension, (optional) Notification Service extension; shared Swift package `WheelhouseKit`.

**Dependencies (SwiftPM)**

| Package | Use | Licence |
|---|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) | Terminal emulator view (`TerminalView`) for exec | MIT |
| [Yams](https://github.com/jpsim/Yams) | YAML parse/emit for kubeconfig, editor lint, diff normalisation | MIT |
| (optional) swift-collections | `Deque` ring buffer for logs | Apache-2.0 |

No Kubernetes client library: a small focused REST client is easier to keep Swift-6-clean and App-Store-friendly.

**Modules**

| Module | Responsibility |
|---|---|
| `KubeClient` (actor per cluster) | `URLSession` with a per-cluster delegate for TLS (custom CA anchors via `SecTrustSetAnchorCertificates`, pinning, skip-verify) and client-cert auth (`URLCredential(identity:certificates:persistence:)` from a `SecIdentity` imported with `SecPKCS12Import` or built from PEM cert+key stored in Keychain). Bearer tokens in `Authorization`. Typed `get/list/watch/create/patch/delete`, server-side apply (`PATCH` `application/apply-patch+yaml`, `fieldManager=wheelhouse`, `force` optional), `dryRun=All`. Errors decoded from `metav1.Status` into `KubeError.forbidden(subject,verb,resource,namespace)` etc. |
| `Discovery` | `/version`, `/api`, `/apis`, cached per cluster; drives Resource sections and CRD support; `additionalPrinterColumns` for generic lists. |
| `Watch` | `AsyncThrowingStream<WatchEvent<T>>` over `URLSession.bytes(for:)` line-delimited JSON (`watch=1&resourceVersion=…&allowWatchBookmarks=true`); reflector pattern (list → watch → relist on 410 Gone) feeding an `@Observable` store per kind/namespace; reference-counted so screens share watches; paused when not visible, resumed with backoff. |
| `Models` | Lightweight `Codable` structs for the kinds we render; everything else as `JSONValue` (generic resources, YAML). |
| `Logs` | `GET …/pods/{p}/log?follow=true&container=&previous=&timestamps=true&sinceSeconds=&tailLines=` streamed with `bytes(for:)`; parser for levels/JSON; ring buffer. |
| `Exec` | `URLSessionWebSocketTask` to `…/pods/{p}/exec?command=…&container=…&stdin=1&stdout=1&stderr=1&tty=1`, subprotocols `v5.channel.k8s.io` (fallback `v4.channel.k8s.io`). Frames prefixed with channel byte: 0 stdin, 1 stdout, 2 stderr, 3 error/status (JSON `Status`), 4 resize (`{"Width":,"Height":}`), 255 close (v5). Bridged to SwiftTerm `TerminalViewDelegate`. Note: client-cert auth on WebSockets uses the same session delegate challenge handling. |
| `PortForward` | Local listener with `NWListener` on `127.0.0.1:<port>`; each accepted `NWConnection` opens a WebSocket to `…/pods/{p}/portforward?ports=<remote>` with subprotocol `v4.channel.k8s.io` (portforward protocol: per port a data channel and an error channel, each first frame carries the port as 2-byte little-endian). Services resolve to a ready endpoint pod. Sessions managed by a `PortForwardManager` actor; suspended on background, re-established on `scenePhase == .active`. In-app browser `WKWebView` hits `http://127.0.0.1:<port>`. (Newer clusters also accept the WebSocket tunnelling protocol `SPDY/3.1+portforward.k8s.io` over WebSockets; keep the transport behind a protocol.) |
| `Metrics` | metrics-server: `GET /apis/metrics.k8s.io/v1beta1/nodes|pods`. Prometheus: auto-discovery by listing Services with well-known names/labels (`prometheus-operated`, `prometheus-k8s`, `kube-prometheus-stack-prometheus`, `app.kubernetes.io/name=prometheus`) in common namespaces, then querying through the API-server service proxy `…/api/v1/namespaces/{ns}/services/{name}:{port}/proxy/api/v1/query_range` (needs `services/proxy` RBAC) — or a user-provided URL + token. Queries are templated PromQL (cluster CPU/memory usage vs requests vs allocatable, per-node, per-pod, restarts). |
| `Health` | Pure functions that derive cluster status, attention items and diagnosis banners from store snapshots — unit-testable, shared with background refresh. |
| `Credentials` | Keychain wrapper: `kSecClassGenericPassword` items (token, PEM key, CA) and `kSecClassIdentity`/certificate items; `kSecAttrAccessibleAfterFirstUnlock` (needed for background refresh) — option for `WhenUnlockedThisDeviceOnly` per cluster; `kSecAttrSynchronizable = true` **only** for clusters opted into iCloud sync (non-synced items use `…ThisDeviceOnly`). Cluster metadata (non-secret) in SwiftData/JSON, synced via the same synchronizable Keychain item (single source) to avoid a CloudKit dependency. Identities synced as PKCS#12 data in a generic password item (identities themselves are not synchronizable). |
| `AppLock` | `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`; lock overlay window on `scenePhase` changes; secrets reveal uses a fresh `LAContext` per reveal. Privacy snapshot overlay when inactive. |
| `Background` | `BGAppRefreshTask` (`app.wheelhouse.refresh`) runs `Health` checks for opted-in clusters, posts `UNUserNotification`s, writes widget snapshot to the App Group, calls `WidgetCenter.shared.reloadAllTimelines()`. |
| `WidgetData` | Codable snapshot (`FleetSnapshot`) in App Group container; widgets read only this. |
| `Demo` | `KubeClient` protocol with a mock implementation backed by bundled JSON fixtures + simulated watch events and metrics (used for previews, UI tests, App Review). |

**Concurrency:** one `actor` per cluster client; stores are `@MainActor @Observable`; watch streams run in structured `TaskGroup`s owned by a per-cluster `ClusterSession` and cancelled on cluster removal / app background. All model types `Sendable`. Throttle UI updates (coalesce watch events at 10 Hz).

**Performance:** lists use `List` with stable IDs (`uid`), pagination via `limit`/`continue` for > 500 items, table projections (`Accept: application/json;as=Table;g=meta.k8s.io;v=v1`) for generic lists to avoid decoding full objects; protobuf not needed for v1.

**Testing:** unit tests for Health rules, kubeconfig parsing (fixtures for EKS/GKE/AKS/k3s/kind/minikube), exec/port-forward framing; snapshot tests of components in light/dark/AX5; UI tests against Demo mode; integration tests against kind in CI (macOS runner).

**Privacy manifest:** no tracking; required-reason APIs declared (UserDefaults, file timestamps). Local network usage description (for LAN clusters) and Face ID usage description.

---

## 14. Open questions

1. **Monetisation:** free, paid up-front, or free with a Pro tier (e.g. > 2 clusters, widgets, alerts)? Affects onboarding and Settings.
2. **OIDC login:** v1 accepts pasted ID tokens only. Should we add an in-app OIDC device/auth-code flow (refresh tokens) for clusters using Dex/Keycloak/Azure AD? This is the main workaround for exec-plugin users.
3. **Cloud provider sign-in:** support EKS/GKE/AKS token generation natively (AWS SigV4 presigned STS for EKS is feasible on-device; GKE/AKS need OAuth)? Big value for the “exec” group, larger scope.
4. **Push alerts:** keep best-effort BGAppRefresh only, or offer an optional self-hosted relay (in-cluster agent → APNs) for reliable alerts?
5. **Default for skip-TLS:** allow at all on Production-flagged clusters, or block it?
6. **Read-only + exec/port-forward:** should read-only mode block exec and port-forward by default (current proposal: yes)?
7. **Helm / GitOps awareness:** show Helm release and Argo CD/Flux ownership and warn before editing GitOps-managed objects (proposal: warning in v1, Helm view in v1.1)?
8. **Sync scope:** sync only cluster list + credentials (proposal) or also preferences, pinned namespaces and alert rules via iCloud key-value store?
9. **Localisation for launch:** English only, or English + German/French/Japanese?
10. **Tagline:** “Every cluster, at the helm.” (proposed) vs. the original “Your clusters, at the helm.”
