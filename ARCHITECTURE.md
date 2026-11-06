# Wheelhouse — Architecture (foundation)

Design source of truth: `design/DESIGN.md` (§2 navigation, §5 states, §7 safety, §8 design system, §13 tech). This file lists the **stable APIs** feature engineers build on.

## Layout
```
project.yml                     XcodeGen spec → Wheelhouse.xcodeproj (run `xcodegen generate` after adding files/targets)
Packages/WheelhouseKit/         local Swift package (iOS 27, Swift 6)
  Sources/WheelhouseKit/        core, NO UI: Models Client Kubeconfig Credentials Store Health Metrics Demo WidgetData Preferences
  Sources/WheelhouseUI/         design system (SwiftUI + Charts), depends on WheelhouseKit
  Tests/WheelhouseKitTests/     Swift Testing unit tests
Wheelhouse/App/                 SHARED shell: app, SceneRoot, per-scene router, routes, deep-link routing, shells, lock windows, network
Wheelhouse/Features/<Name>/     one folder per engineer (ownership below)
Wheelhouse/Resources/           Assets.xcassets (AppIcon, AccentColor, wheelhouse.helm), PrivacyInfo.xcprivacy
WheelhouseWidgets/              widget extension (reads FleetSnapshot from the App Group)
```
Targets: `Wheelhouse` (app, `app.wheelhouse.ios`), `WheelhouseWidgets` (`…ios.widgets`). Deps: Yams 6.2.2 (Kit). **SwiftTerm 1.99.2 is declared but commented out in `project.yml`**: it ships a SwiftPM build-tool plugin (`SwiftTermBuildInfoPlugin`) that must be trusted once (Xcode GUI "Trust & Enable", or `xcodebuild -skipPackagePluginValidation`) — the Sessions owner enables it after that approval. Entitlements: App Group `group.app.wheelhouse`, keychain group `$(AppIdentifierPrefix)app.wheelhouse.shared`.

## Build & test
```
xcodegen generate
xcodebuild -project Wheelhouse.xcodeproj -scheme Wheelhouse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/dd-main build   # also: 'iPad Pro 13-inch (M5)'
xcodebuild -project Wheelhouse.xcodeproj -scheme Wheelhouse -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/dd-main test
```
**Run `test` with a derived-data path outside `~/Documents`** (e.g. `-derivedDataPath /tmp/wh-dd-test`): the simulator test host hangs forever on `opendir` of bundles under `~/Documents` (macOS privacy prompt it cannot show); `build` is unaffected. Use your own `-derivedDataPath` (e.g. `.build/dd-<feature>`) when building in parallel. Never point tools at `~/.kube`; use Demo mode or the dedicated test cluster.

## Kit core APIs
- **`KubeClientProtocol`** (Sendable): `version()`, `discovery()`, `list/get<T: KubeObject>`, `listRaw/getRaw(kind,…) -> JSONValue`, `watch<T>(…) -> AsyncThrowingStream<WatchEvent<T>,Error>`, `create/replace/patch/delete`, `logs(namespace:pod:options:) -> AsyncThrowingStream<String,Error>`, `podMetrics/nodeMetrics`, `proxyGET(namespace:service:port:path:query:)`, `execWebSocket/portForwardWebSocket -> KubeWebSocket` (wrapper over `URLSessionWebSocketTask`; you implement channel protocols). Extensions: `scale`, `restartRollout`, `setCronJobSuspended`, `setNodeUnschedulable`, `evict(pod:)`. Patches: `KubePatch.merge/.strategicMerge/.json/.apply` (SSA uses fieldManager `wheelhouse`, `MutationOptions(dryRun:force:)`).
- **`LiveKubeClient`** (actor) – URLSession + per-cluster delegate: custom CA anchors, skip-TLS (**ignored for production**, see `ClusterConfig.allowsInsecureTLS`; `ClusterConfig.tlsServerName` (kubeconfig `tls-server-name`, optional Codable) is the name the certificate is validated against, passed to `LiveKubeClient(config:secrets:tlsServerName:)` by the registry's client factory), client-cert identity (PEM → key + cert added to the keychain as ThisDeviceOnly items, identity queried back; see `ClientIdentityBuilder`), bearer token. **Read-only clusters throw `KubeError.readOnly` before any request** (also exec/port-forward unless `allowExecInReadOnly`).
- **`DemoKubeClient`** – same protocol, in-memory fleet (`DemoFleet.configs`: prod-eu-west *production*, staging, homelab-k3s, edge-oslo *unreachable*). Mutations really change state; watches emit simulated updates; exec/port-forward throw `.unsupported`.
- **`KubeError`**: `unreachable, tlsUntrusted, unauthorized, forbidden(verb,resource,namespace,message), notFound, conflict, invalid(message,causes), readOnly, gone, server(Status), decoding, unsupported, cancelled`; `.summary`, `.isTransient`. `EmptyStateKind(error:)` (UI) maps errors to screens.
- **`ResourceKind`** registry: statics (`.pod`, `.deployment`, …), `ResourceKind.builtIn`, `.builtIn(in: section)`, `.lookup("deploy…")`, `.custom(group:version:kind:plural:namespaced:)`, `collectionPath(namespace:)`, `itemPath(name:namespace:subresource:)`, `.symbol`, `.displayName`, `.section`. `ResourceRef(clusterID, kind, namespace, name)` identifies any object (Codable/Hashable).
- **Models**: `Pod Deployment StatefulSet DaemonSet ReplicaSet Job CronJob Service Ingress NetworkPolicy Endpoints EndpointSlice ConfigMap Secret PersistentVolume(Claim) StorageClass Node Namespace KubeEvent EventsV1Event CustomResourceDefinition ServiceAccount Role ClusterRole RoleBinding ClusterRoleBinding PodDisruptionBudget NodeMetrics PodMetrics Status`, `KubeList<T>` (skips undecodable items, `skippedItems`), `Unstructured` (any kind + `raw: JSONValue`), `JSONValue` (literals, `value(at:"a.b")`, `setValue`), `Quantity` (`cores`, `millicores`, `bytes`, `formatBytes`). Missing collections decode as empty (`@Lenient`). Use `KubeJSON.decoder`.
- **`ClusterRegistry`** (`@MainActor @Observable`, in the environment): `clusters`, `currentCluster/currentSession/currentClusterID`, `namespace(for:)`/`currentNamespace` (**nil = All namespaces**), `session(for:)`, `add/update/remove`, `enterDemoMode()/exitDemoMode()`, `refreshAllHealth()`, `fleetAttention`, `makeSnapshot()`.
- **`ClusterSession`**: `client`, `config`, `connection`, `version`, `latency`, `health`, `metricsAvailability`, `refreshHealth()`, `detectMetrics()`, `loadDiscovery()`, `metrics: MetricsService`, **`store(for:namespace:labelSelector:fieldSelector:)`**.
- **`ResourceStore<T>`** (list → watch → relist on 410, ref-counted, 10 Hz coalescing, cached items kept when stopped; **`pause()`/`resume()`** cancel and restart the watch while keeping consumers registered (used when the app backgrounds: `registry.stopAllSessions()` pauses, `resumeAllSessions()` resumes on `.active`); **`invalidate()`** cancels and drops all consumers when a cluster is removed or its credentials/config are replaced; `cancel()` is an alias):
```swift
struct PodsView: View {
  let session: ClusterSession; let ns: String?
  var body: some View {
    let pods = session.store(for: Pod.self, namespace: ns)          // shared instance per key
    List(pods.items) { PodRow($0) }
      .overlay { if pods.isLoading { EmptyState(.loading) } else if let e = pods.error, pods.items.isEmpty { EmptyState(EmptyStateKind(error: e)) } }
      .refreshable { await pods.refresh() }
      .task { await pods.run() }                                    // start/stop tied to the view
  }
}
```
  Custom resources: `session.unstructuredStore(kind:namespace:)`. Sorting: `store.sortOrder = { … }`.
- **`ClusterEvents`** (Kit): `registry.update/remove` post `ClusterEvents.invalidated` (`postInvalidated(id, removed:)`; read with `clusterID(from:)` / `wasRemoved(_:)`) and call `LiveKubeClient.invalidate()`. Long-lived holders (port-forwards, shells, log streams, open screens) observe it and drop anything bound to the old client/config. Mutations re-check the live config (read-only, environment) before running.
- **Missing credentials**: `ClusterSecrets.isMissingCredentials(for:)`. When true the registry never caches the session (only a short-lived transient one) and sets `ClusterSession.credentialsMissing`; the cluster dashboard and fleet `ClusterCard` then show "Credentials not on this device" with an **Edit Cluster** action instead of unreachable/unauthorized. Registry `update` also re-saves the Prometheus token (`PrometheusTokenStore`) when the iCloud flag changes; `remove` deletes it.
- **TLS** (`Client/TLSDelegate.swift`): `ClusterSessionDelegate` evaluates server trust through `TLSValidator.evaluate(trust, host:, anchors:)` using the custom CA anchors and `tlsServerName ?? host` as the name; failures are recorded as `TLSFailureInfo` (subject, SHA-256) for the TLS error screen. Skip-verify is honoured only for non-production clusters.
- **`DeepLink`** (Kit/Models): pure parser/builder for `wheelhouse://cluster/<id>[/ns/<ns>][/<kind>/<name>][?view=logs|yaml…]` with `KubeNames` validation of every segment; `view=shell` is deliberately unsupported (a link must never start exec). The App target maps it to a `Route` in `DeepLink+Routes.swift`.
- **`SecretRevealGate`** (Kit/Preferences): honours `revealSecretsOncePerSession` for Secret reveal (Resources Secret detail, YAML editor reveal/edit); reset whenever `AppLockController.isLocked` becomes true. Copying a secret always authenticates.
- **Health** (pure, unit-tested): `HealthEvaluator.evaluate(ClusterHealthInput) -> ClusterHealth` (status, `items: [AttentionItem]`, counts), `Pod.stateSummary()`, `PodDiagnoser.diagnose(pod, memoryPeakBytes:) -> PodDiagnosis?` (banner text), `HealthStatus` (healthy/warning/critical/unknown).
- **Metrics**: `MetricsAvailability`, `MetricsService.availability()`, `PrometheusClient.queryRange(PromQL.*, name:, range:) -> [TimeSeries]`, `MetricsRange`.
- **Other**: `KubeconfigParser.parse(text) -> Kubeconfig` (contexts with `status`, `unsupportedReason`, `makeClusterConfig()`), `KubeconfigParser.serviceAccountTokenCommands()`, `KeychainCredentialStore`, `ClusterMetadataStore`, `FleetSnapshot` + `WidgetDataStore`, `AppPreferences` (App Group defaults, in the environment), `AppGroup`.

## App shell (Wheelhouse/App)
- **`Route`** enum (fleet, alerts, cluster, resourceSections, resourceList, resourceDetail, yaml, createYAML, logs, shell, portForward, sessions, search, settings, addCluster, importKubeconfig) and **`RouteDestinationView`** (the only route → view switch).
- **`AppRouter`** (`@Environment(AppRouter.self)`): `push(route, from: column = .detail)` (relative; sheets, iPad content/detail column chosen automatically; views in the iPad content column read `@Environment(\.routeColumn)` and pass it so a detail route REPLACES the detail column; `RouteLink` does this itself), `open(route, registry:)` / `open(url:registry:)` (absolute, deep links), `dismissSheet()`. Prefer **`RouteLink(route:) { label }`** over `NavigationLink`. Deep links: `wheelhouse://cluster/<id>[/ns/<ns>][/<kind>/<name>][?view=logs|shell|yaml&container=&previous=1]` (`DeepLink`, `DeepLink.url(for:view:)`; `view=shell` is not supported).
- **Scenes & lock**: `SceneRoot` (one per window scene) owns that scene's `AppRouter`, handles `onOpenURL` / notification taps, and holds links arriving while locked until unlock. `LockWindowManager` shows the lock screen and app-switcher privacy cover in a dedicated overlay `UIWindow` per scene (above sheets); `AppLockController` only holds state (`isLocked`, `lockNow()`, `resetLock(preferences:)`, `authenticate(reason:)`). Lock-sensitive settings changes (turning the lock off, changing the timeout) authenticate first.
- iPhone: `TabView` Fleet · Cluster · Resources · Sessions · Search(role) with one `NavigationStack` per tab; iPad regular width: 3-column `NavigationSplitView` (sidebar clusters → sections); compact iPad falls back to tabs. Also: `AppLockController` (lock + `authenticate(reason:)` for secret reveal), `NetworkMonitor` (offline banner), privacy cover, `WindowGroup(for: ResourceRef.self)` window, ⌘0 / ⌘1–9 / ⇧⌘N / ⌘N commands. First launch with no clusters → `WelcomeView`.

## Design system (`import WheelhouseUI`)
Tokens: `Palette.*` (§8.1, single source), `Spacing`, `Radius`, `Font.whKPI/.whCode`, `StatusTone`, `Format.age/percent`. Components:
- `StatusPill(_ status: HealthStatus, text:)` / `StatusPill(tone:text:symbol:)` · `EnvBadge(_ env)` · `FlagBadge("READ-ONLY", tone:)`
- `ContextLine(cluster:namespace:kind:)` (adds READ-ONLY / DEMO / UNVERIFIED TLS flags) — put on every resource screen and sheet
- `KPITile(label:value:caption:meter:tone:)` · `Meter(value:request:limit:)` · `ReadyRing(ready:desired:)` · `Sparkline(values:)`
- `ResourceRow(title:subtitle:lead:trailing:)` (lead `.status/.ring/.symbol`) · `ClusterCard(cluster:health:version:cpu:memory:sparkline:onRetry:)`
- `DiagnosisBanner(diagnosis, actionTitle:action:)` · `GlassActionRow([GlassAction])` · `.whCard()` · `SectionHeader`
- `ConfirmRequest(title:message:verb:isDestructive:cluster:namespace:resource:confirmationText:facts:isDisruptive:dryRun:action:)` + `.confirmSheet($request)` — **the only way to run mutations**
- `MetricChart(title:series:unit:capacity:)` · `HeatGrid(tiles:)` · `CodeView(text, language:highlighter:)` (`CodeHighlighters.yaml/json`)
- `EmptyState(.loading/.empty/.filteredEmpty/.error/.forbidden/.unauthorized/.unreachable/.tlsError)` · `StateBanner(.partialMetrics/.noMetrics/.readOnly/.demo/.offline/…)` · `SkeletonList`
Glass only on the navigation/control layer (§8.4); content stays opaque.

## Conventions
- Swift 6 language mode, strict concurrency complete. Stores/sessions/registry are `@MainActor`; clients are actors/Sendable. No force unwraps on network data.
- **All mutations go through `ConfirmSheet`** (dry-run first via `MutationOptions(dryRun: true)`). Production: **every** mutation requires typing the confirmation text (`ConfirmRequest.requiresTyping(for:)`, evaluated against the live cluster config; unknown cluster defaults to requiring it). Read-only clusters: **hide** mutating UI (`cluster.readOnly`), the client refuses anyway.
- Never log or persist Secret values; reveal behind `AppLockController.authenticate`. Never read `~/.kube` or use real credentials in tests; use Demo / `InMemoryCredentialStore`.
- Put shared additions in your own feature folder; need a new `Route` or shared API? Ask the foundation owner.

## Feature folders (one owner each)
Dashboard (`FleetDashboardView ClusterDashboardView(clusterID:) AlertsInboxView`) · Resources (`ResourceSectionsView(clusterID:) ResourceListView(kind:clusterID:namespace:) ResourceDetailView(ref:)`) · YAML (`YAMLEditorView(ref:) CreateFromYAMLView(clusterID:namespace:)`) · Sessions (`SessionsView LogsView(pod:container:previous:) ExecTerminalView(pod:container:) PortForwardSetupView(target:)`) · Onboarding (`WelcomeView AddClusterView KubeconfigImportView`) · Settings (`SettingsView SearchView(initialQuery:)`) · Background (`BackgroundRefresh AlertNotifier`) · WheelhouseWidgets target.
