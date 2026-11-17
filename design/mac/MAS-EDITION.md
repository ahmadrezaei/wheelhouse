# Wheelhouse for Mac: Mac App Store edition (plan)

Status: proposal for the owner, 2026-11-17. Nothing here is built. Paths are relative to the repo root.

## 0. Summary

A sandboxed edition is possible, but it is the iPad feature set plus a Mac UI. It loses the terminal, exec-plugin clusters (EKS, GKE, AKS), cloud discovery, Helm writes, local Trivy and Beacon. **Recommendation: do not build it now.** First turn on, and test, the iPad app on Apple silicon Macs. That needs no new build. Revisit if users ask for it (§8). If you do build it, use **universal purchase on app 6831379262**.

## 1. Bundle ID and App Store record

**Recommendation: universal purchase.** Use bundle `com.ahmadrezaei.wheelhouse` with macOS added to app 6831379262. D2 and §1.7 of `ARCHITECTURE-MAC.md` kept this ID free for this reason. A separate record would need a different store name, because names are unique, and it would split ratings.

What universal purchase means:

| Topic | Effect / decision |
|---|---|
| iCloud | No iCloud container is involved. Sync is iCloud Keychain only: `Wheelhouse/Wheelhouse.entitlements` has no ubiquity keys. The MAS app lists `JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared`, the same group as iOS and the GitHub app, so synced clusters appear. |
| Private keychain group | New: `JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas`. It holds the Anthropic key and similar items. It is not shared with the GitHub app's `…wheelhouse.mac` group. |
| App group | New: `JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas`. It must **not** reuse the GitHub app's `JCZY58QP3L.com.ahmadrezaei.wheelhouse`, which holds `FleetSnapshot` and `beacon/beacon.sock` (§1.8); the two apps would fight over them. iOS uses `group.com.ahmadrezaei.wheelhouse`, but app groups never sync, so iOS does not matter here. The group is read through `WH_APP_GROUP` / `WHAppGroup`, so no code change is needed. |
| Versions | Each platform has its own version train in App Store Connect, so the Mac can start at 1.0. Add `MAS_MARKETING_VERSION` / `MAS_BUILD_NUMBER` and do not use the shared `MARKETING_VERSION 1.0.2` / `CURRENT_PROJECT_VERSION 7` (`project.yml` lines 21–22). Start Mac builds at 1000 so they never collide with iOS build numbers. Check this against Apple's current rules on the first upload. |
| Review coupling | Each platform version is reviewed on its own. Shared across both: name, subtitle, category, age rating, privacy policy URL, privacy labels and price. Per platform: description, keywords, screenshots, What's New, and the support and marketing URLs. First Mate is new to this record. Re-answer the age-rating questions (an AI chat feature), and make sure `docs/privacy.html` covers it (it already mentions Anthropic). |
| Designed for iPad | Once the native Mac version is live, it replaces the iPad build on Macs. The two routes cannot both be listed. |

Living alongside the GitHub app (`…wheelhouse.mac`):
- **Defaults and files.** The sandbox puts the MAS app's defaults and `AppPaths.root` inside `~/Library/Containers/com.ahmadrezaei.wheelhouse/`, so nothing collides. `AppPaths.caches` hard-codes `releaseBundleID` (`Safety/AppPaths.swift`). Inside the container this is harmless, but it should come from the bundle ID.
- **`wheelhouse://`.** Both apps register it, and LaunchServices picks one. Check in the spike that a MAS widget tap opens the MAS app. If it does not, give widget links an edition-specific scheme taken from Info.plist.
- **Login item.** `SMAppService.mainApp` is per app, so both apps can run Crow's Nest and send duplicate notifications. When the MAS app sees `…wheelhouse.mac` running (`NSRunningApplication`), it should show a note.
- **Beacon / MCP.** Not in MAS 1.0, so nothing collides. If it is added later, register it as `wheelhouse-mas`.
- **App file name.** Both apps are `Wheelhouse.app` in /Applications. Test the install with TestFlight. If it clashes, rename only the MAS bundle file.

## 2. Feature matrix (checked against the code)

§2.3 is mostly right. The corrections are Beacon, Helm and Rigging.

| Feature | MAS | Code |
|---|---|---|
| Fleet, resources, logs, pod exec, port-forward (+ preview), YAML, metrics, iCloud Keychain sync, app lock, demo mode | Kept | Shared `Wheelhouse/Features`, Kit |
| Workspace, Compass, Rail, Activity, Settings | Kept | `WheelhouseMac/Workspace`, `Compass`, `Rail`, `Activity` |
| Moorings discovery | **Reduced**: folder grants by bookmark (§3). No shell `KUBECONFIG` | `WheelhouseDesktop/Moorings`, `Process/ShellEnvironment.swift` not started |
| Exec credential plugins | **Removed, shown clearly** | `Credentials/ExecCredentialProvider.swift` fails closed |
| Deck Terminal, `wh-pty-exec` | Removed | `WheelhouseMac/DeckTerminal`, `Process/PTYProcess.swift`, `Terminal/*` |
| Gangway | Removed (nothing to proxy for) | `WheelhouseMac/Gangway/MacGangway.swift`, `WheelhouseDesktop/Gangway` |
| Landfall | Removed | `WheelhouseMac/Landfall`, `WheelhouseDesktop/Landfall` |
| Chart Room | **Read-only**: the native Kit read path (`WheelhouseKit/Helm/HelmReleaseCatalog.swift`, `HelmReleaseCodec`, `HelmCompare`). **No bundled helm.** This differs from §2.3 and removes the 2.5.2 risk and 55 MB | Hide `HelmFlowSheet`, `HelmFlowModel`, `HelmRepoViews`, `HelmToolbox+Live`; `Tools/HelmRunner.swift`, `HelmCLI.swift`, `HelmRepoTools.swift` |
| Survey | **Reduced**: Trivy Operator reports and RBAC / pod-security rules (`WheelhouseKit/Security`) | Hide `Survey/ScanCoordinator.swift`, `ScanSettingsSection`; `Tools/TrivyCLI.swift`, `ManagedTrivy.swift` |
| Tides | Kept apart from Flux diff | Hide `Tides/FluxDiffView.swift` (uses `flux` through `Subprocess` and Gangway) |
| First Mate | Kept | `WheelhouseMac/FirstMate`, `WheelhouseKit/AI` |
| Crow's Nest, login item, activation policy | Kept, opt-in | `CrowsNest/LoginItem.swift` (`SMAppService` is allowed in the sandbox), `ActivationPolicyController.swift` |
| Widgets | Kept, as a new `WheelhouseMASWidgets` target using `WheelhouseMacWidgets` sources, id `com.ahmadrezaei.wheelhouse.widgets` | `project.yml` |
| Beacon, `wheelhouse-mcp` | **Removed in 1.0**; spike for 1.1 | The helper must be sandboxed. `BeaconPeer` walks the parent process chain, which the sandbox may deny. `BeaconClientConfig` runs `claude` and writes Claude's config outside the container. `BeaconRequirements` require Developer ID markers. |
| Rigging | Removed (not in Mac 1.0 either). Later: folders only; `Rigging/GitPackFetcher.swift` runs `git` | FeatureRegistry |
| Sparkle, Updates pane | Removed (2.4.5(vii)) | `Updates/MacUpdater.swift`, `Settings/Panes/UpdatesPane.swift` |
| Export Context / merge into `~/.kube/config` | Becomes a Save panel | `Safety/KubeconfigWriter.swift` |

**Gating: a mix, chosen to touch as little as possible.**
1. **A separate XcodeGen target, `WheelhouseMAS`.** It uses the same sources as `WheelhouseMac` minus `Updates/**` and `UpdatesPane.swift`. It has no Sparkle, no `wh-pty-exec` or `wheelhouse-mcp` dependency and no helm build phases, plus its own Info.plist values, entitlements and configs. The `WheelhouseMac` block is not edited. The ~120 duplicated lines are acceptable; a templated target would mean editing the GitHub target.
2. **The `WH_MAS` compilation condition, set only on `WheelhouseMAS`,** for short seams:
   - `WheelhouseMacApp.swift` (no `MacUpdater`);
   - `SettingsPane.swift` (hide the Updates, Terminal, Landfall, Beacon and Rigging panes);
   - `FeatureRegistry.releaseEnabled` (a MAS set without `deckTerminal`, `landfall`, `beacon`, `rigging`);
   - `MacAppEnvironment.make` / `startServices` (no `ShellEnvironment` probe, no `LandfallModel`, no `gangway.follow`, no `beacon.maintainHelperLink`, no `DirectKubeconfig`).

   Disabled features stay compiled but unreachable, the same way Rigging ships in Mac 1.0. This avoids touching the many files that reference Beacon and Rigging.
3. **A runtime `Edition.isSandboxed` check in `WheelhouseDesktop/Safety`,** read from the `com.apple.security.app-sandbox` entitlement with `SecTaskCopyValueForEntitlement`. `Subprocess`, `PTYProcess`, `ExecCredentialProvider`, `CLIRunner` and `HelmRunner` throw `.unavailableInAppStoreEdition` when it is true. This is defence in depth, and it gives exec contexts a clear error. It changes nothing in the GitHub edition, which is not sandboxed. Compilation conditions do not reach SwiftPM targets, so a runtime check is the clean way to do this inside the package.
4. **Capability flags inside kept features:** `ChartRoomCapabilities.writes`, `SurveyCapabilities.localScans` and `TidesCapabilities.fluxDiff`, all false when `Edition.isSandboxed`.

**DevSafety (D22) must learn the MAS identity.** Today `DevSafety.evaluate` turns the gate off only for `com.ahmadrezaei.wheelhouse.mac` with a Developer ID signature, so a store build would stay in dev mode for ever. Add a second accepted identity: bundle `com.ahmadrezaei.wheelhouse`, `WHDevSafety = NO`, an Apple Mac App Store signature (requirement `anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists`), and team `JCZY58QP3L` from `kSecCodeInfoTeamIdentifier`. A local Apple Distribution export keeps the gate on, which is the safe default. Check the exact requirement for TestFlight-signed builds on the first upload. `DevSafetyTests` gets new truth-table rows.

## 3. Kubeconfig access in the sandbox

What the code does today:
- `KubeconfigDiscoveryPolicy.defaultSources` uses the shell's `KUBECONFIG`, else `~/.kube/config`.
- `MooringsService.resolvedSources` adds `~/.kube/*.yaml`, `~/.kube/configs/*`, Landfall and user sources. `MooringsSource` stores only a `path`.
- `KubeconfigLoader.readFile` and `DiscoveredSecrets.readFile` open files directly.
- `FileWatcher` runs one FSEventStream over the parent folders.
- `KubeconfigFileInliner` inlines referenced files on import.

The design:
1. **First run.** Show a "Grant access to your .kube folder" sheet. It opens an `NSOpenPanel` at `DevSafetyPolicy.accountHome/.kube` (the real home, not the container), with `showsHiddenFiles = true` and folders only. Store an app-scoped, read-only bookmark (`.withSecurityScope`, `.securityScopeAllowOnlyReadAccess`).
2. **Model.** Add `bookmark: Data?` to `MooringsSource`. Without a shell, `defaultSet` becomes `~/.kube/config` inside the granted folder. "Add Folder…" adds more bookmarked folders, for users whose `KUBECONFIG` points elsewhere. **Grant folders, never single files**: tools replace kubeconfigs atomically, which changes the inode.
3. **Access.** A new `SecurityScopedAccess` resolves the bookmarks at launch, refreshes stale ones, and holds `startAccessingSecurityScopedResource` for the app's lifetime for watched folders. It stops when a source is removed.
4. **Watching.** `FileWatcher` does not change. FSEvents works on folders the app can access. Its roots are now limited to granted folders. The 600 s safety rescan stays.
5. **Referenced files** (CA, client cert and key, `tokenFile`; minikube's `~/.minikube/...` is the common case). Map `EPERM` / `EACCES` to a new `needsAccess(folder)` state, separate from `KubeconfigError.missingFiles`. The row shows "Needs access to ~/.minikube" with **Grant Folder…** (an open panel at the common parent folder). Import in `MacImportCoordinator` / `KubeconfigFileInliner` asks the same way, then inlines the files.
6. **Exec plugins.** Keep the `AuthSummary.exec` row and add `ClusterCheckResult.unavailableInEdition`. The row shows a badge, "Uses `aws` (exec plugin). The App Store edition can't run credential plugins.", with Learn More linking to a docs page. Suggested fixes: a service-account token kubeconfig, or the open-source edition. Adopting such a context is disabled. Nothing fails silently.
7. **Debug builds of the MAS target** read `.testcluster/kubeconfig` through a temporary-exception entitlement in the Debug entitlements only. `mas-entitlement-check.sh` fails the release if any temporary exception is present.

A home-relative temporary exception for `/.kube/` in Release was considered and rejected: it is a likely review rejection.

## 4. Entitlements, signing, pipeline

`WheelhouseMAS/Resources/WheelhouseMAS.entitlements`:
- `com.apple.security.app-sandbox`
- `com.apple.security.network.client`
- `com.apple.security.network.server` (port-forward listeners on 127.0.0.1)
- `com.apple.security.files.user-selected.read-write` (import, folder grants, Save panel export)
- `com.apple.security.files.bookmarks.app-scope`
- `keychain-access-groups`: `JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas`, `JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared`
- `com.apple.security.application-groups`: `JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas`

The widget gets the sandbox and the app group. There are no other executables in the bundle.

**Signing.**
- Certificates: Apple Distribution (the iOS one) plus a **Mac Installer Distribution** certificate.
- Mac App Store provisioning profiles for the app and the widget.
- Automatic signing with `-allowProvisioningUpdates`. Hardened runtime can stay on.

**`scripts/release-mac-appstore.sh <version> <build>`:**
1. Preflight: clean tree; build number higher than the last; the ASC API key path, key ID and issuer come from environment variables (the script never reads `.secrets/`).
2. Set `MAS_*` versions and run `xcodegen generate`.
3. Run `scripts/lint-mac.sh`, `swift test` and the MAS unit tests.
4. `xcodebuild archive -scheme WheelhouseMAS -configuration Distribution`.
5. `scripts/mas-entitlement-check.sh`. It fails on: any entitlement outside the list; a temporary exception; anything in `Contents/Helpers`; Sparkle in the bundle; `WHDevSafety` other than `NO`; a non-empty `WHDefaultTestKubeconfig`; the `WHTestHook` symbols (same as `mac-entitlement-check.sh`).
6. `xcodebuild -exportArchive -exportOptionsPlist scripts/ExportOptions-AppStore.plist` with `method app-store-connect`, `destination upload`, `teamID JCZY58QP3L`, `uploadSymbols true`, `manageAppVersionAndBuildNumber false`.
7. Print the TestFlight next steps.

No iOS release script is committed (only `ExportOptions-DeveloperID.plist`), so this script also documents the iOS flow. `release-mac.sh`, `ExportOptions-DeveloperID.plist`, `mac-entitlement-check.sh` and the `WheelhouseMac` target are not touched.

**Privacy manifest.** Copy `WheelhouseMac/Resources/PrivacyInfo.xcprivacy` (UserDefaults CA92.1 and 1C8F.1, FileTimestamp C617.1) and **add SystemBootTime 35F9.1**. `ProcessInfo.systemUptime` is used in `Workspace/PaneFocusSync.swift` and Kit `MCP/BeaconLimiter.swift`, and both existing manifests miss it. Fix the GitHub manifest separately.

**Export compliance.** Set `ITSAppUsesNonExemptEncryption = false`, as iOS does. The app uses only system TLS, and Gangway's TLS server is not in this edition.

## 5. App Review risks

| Guideline | Risk | Answer |
|---|---|---|
| 2.4.5(i) sandbox and entitlements | Is `network.server` justified? | Notes: loopback-only port-forward listeners, started by the user. |
| 2.4.5(iii) auto-launch | Login item | Off by default; turned on in Settings. |
| 2.4.5(iv), 2.5.2 downloaded or executed code | helm, Trivy download, Rigging packs, git | None of these ship. If Rigging returns: declarative data from user-chosen folders. First Mate never runs code on the Mac; it proposes Kubernetes API actions the user confirms. |
| 2.4.5(vii) updates | Sparkle | Not linked; the check script enforces it. |
| 2.1 completeness, review access | Reviewers need a cluster | Demo mode on the first-run screen (`registry.enterDemoMode`). Plus an owner-run review cluster with a read-only service-account token kubeconfig, attached to the notes and rotated after review. `docs/AppReviewNotes.md` covers ATS only; add a Mac section. |
| 4.2 / 4.2.3 minimum functionality, standalone | "Exec clusters need cloud CLIs" | Token and certificate kubeconfigs work fully. The limits are stated in the app and the listing. |
| 5.1.1 / 5.1.2(i) data to a third-party AI | First Mate with the user's own Anthropic key | Explicit consent on first use, "What was sent" (`WhatWasSentView.swift`), Secret redaction in `ClusterToolbox`, the key in the keychain on this device only, disclosed in the privacy policy. |
| 2.3 accurate metadata | Promising terminal or EKS support | The listing describes this edition only. |
| Links to the full edition | Possible "go install from outside" pushback | It is free, so 3.1 does not apply. Link from the description, the support URL and a docs page. In the app, explain and link to docs; no download button. |

## 6. Store listing

- **Screenshots.** 16:10, at 2880×1800 (2560×1600, 1440×900 and 1280×800 are also accepted); 1–10 of them. Generate them from Demo mode through a UI-test scheme (`-WHDemoMode`). The owner approves them.
- **Description.** Lead with "a native, sandboxed Kubernetes manager for Mac". Then a short "This edition does not include" list: terminal, exec-plugin sign-in (EKS, GKE, AKS), cloud discovery, Helm install and upgrade, local Trivy, MCP server. Then a line: "A full open-source edition is available from the project's GitHub page."
- **Keywords** (100 characters, per platform): kubernetes,k8s,kubectl,cluster,pods,helm,devops,yaml,logs,kubeconfig,flux,argo
- **Privacy labels** (shared with iOS): Data Not Collected. Requests to Anthropic go from the user's own key to the user's own account, and the developer has no access.

## 7. Milestones

Separate worktrees run by Sonnet workers; every milestone gets an Opus review.

| # | Scope | Files | Tests | Risk | Tokens |
|---|---|---|---|---|---|
| M0 (owner) | Decide; add macOS to app 6831379262; enable macOS on App IDs `com.ahmadrezaei.wheelhouse` and `.widgets`; Mac Installer Distribution certificate; MAS profiles; app group `…wheelhouse.mas` | App Store Connect, developer portal | n/a | n/a | n/a |
| M1 spike | Throwaway sandboxed build: bookmark on `~/.kube`, FSEvents, shared keychain group in the sandbox, port-forward listener and preview, login item, widget URL routing, Beacon parent-chain check | scratch only | manual | Medium | 500k |
| M2 target | `WheelhouseMAS` + `WheelhouseMASWidgets` targets, entitlements (Release and Debug), `WH_MAS`, schemes, the Sparkle and Updates seams | `project.yml`, `WheelhouseMAS/Resources/*`, `WheelhouseMacApp.swift`, `SettingsPane.swift` | builds, entitlement dump | Medium (goes first: `project.yml`) | 500k |
| M3 safety | `Edition.isSandboxed`, MAS identity in `DevSafety`, process layer fails closed | `Safety/DevSafety.swift`, `CodeSignature.swift`, new `Safety/Edition.swift`, `Process/Subprocess.swift`, `PTYProcess.swift`, `Credentials/ExecCredentialProvider.swift` | `DevSafetyTests` truth table; fail-closed tests | **High** (safety); Opus review required | 600k |
| M4 Moorings | Bookmarks, `SecurityScopedAccess`, first-run grant, `needsAccess`, exec badge, Save-panel export | `Moorings/*`, `WheelhouseMac/Moorings/*`, `Import/*`, `MooringsPane.swift` | injected resolver; stale bookmark; EPERM mapping | **High** | 800k |
| M5a trim | MAS `releaseEnabled`, `MacAppEnvironment` start-up seams, hidden panes and commands | `FeatureRegistry.swift`, `MacAppEnvironment.swift` (not the Moorings part), `MacCommands.swift` | registry tests | Medium | 500k |
| M5b capabilities | Chart Room read-only, Survey without local scans, Tides without Flux diff | `ChartRoom/*`, `Survey/*`, `Tides/TidesDetailView.swift` | view-model tests | Medium | 600k |
| M6 release | `release-mac-appstore.sh`, `ExportOptions-AppStore.plist`, `mas-entitlement-check.sh`, privacy manifest | `scripts/*`, `WheelhouseMAS/Resources/PrivacyInfo.xcprivacy` | dry run with `--no-upload` | Low | 400k |
| M7 listing | Review notes, listing text, screenshot UI test, "Two editions" docs page | `docs/AppReviewNotes.md`, `docs/mac/*`, UI test | n/a | Low | 400k |
| M8 (owner) | TestFlight on a separate macOS user, review cluster, screenshots, submit | n/a | manual | Medium | n/a |

**Waves:**
1. M1 and M2 in parallel.
2. M3.
3. M4, M5a, M5b and M6 in parallel. M4 owns the Moorings construction in `MacAppEnvironment`; M5a owns the rest of that file.
4. M7.

**Totals:**
- About 4.3M worker tokens, plus 8 Opus reviews at about 200k (1.6M), plus about 25% for fix rounds: **about 7–8M tokens**.
- Agent wall-clock: about 2–3 days.
- Calendar: 1–3 weeks, including owner steps and review.

**Owner-only steps:** M0, review cluster hosting and rotation, screenshot approval, TestFlight install, the age-rating and privacy answers, and submission.

## 8. Recommendation

**Not worth building now.** Compared with the free GitHub edition, the MAS app loses exactly what makes the Mac version special: the guarded terminal, exec-plugin clusters (most cloud users), Landfall, Helm writes and Beacon. What is left is close to the iPad app with a Mac UI. Running it would add a second release pipeline, a second review queue and a second support story, with no revenue to pay for them. The things it would add are discovery in the store, installs on managed Macs that allow only App Store apps, and store updates. Those are real, but they can wait for user demand.

**Cheaper first step: the iPad app on Apple silicon Macs.**
- `project.yml` and `Wheelhouse.xcodeproj/project.pbxproj` do not set `SUPPORTS_MACOS_DESIGNED_FOR_IPHONE_IPAD`, so the Xcode default (YES) applies. App Store Connect offers iPad apps on Apple silicon Macs unless you opt out. The app may already be listed: check **Pricing and Availability → iPhone and iPad Apps on Apple Silicon Macs**.
- The iOS-only APIs behave acceptably on a Mac:
  - `BGTaskScheduler` (`BackgroundRefresh+iOS.swift`) just won't run;
  - Face ID falls back to Touch ID or the password through LocalAuthentication;
  - the shared keychain group and iCloud Keychain sync work;
  - import works through the Files picker;
  - the share extension and widgets on the Mac are not verified.
- Users see a resizable iPad window with "Designed for iPad" in the store. There is no Mac menu bar, Compass or workspace, and the app does not read `~/.kube`. It costs no build: set `SUPPORTS_MACOS_DESIGNED_FOR_IPHONE_IPAD: YES` explicitly, test on a Mac, and keep the checkbox on.
- Point Mac power users to the GitHub edition from the website, as `README.md` already does.

**Revisit the MAS edition** if issues or email ask for it, or if managed-Mac users need it. If you go ahead, run the M1 spike first. It costs about 0.7M tokens and settles bookmarks, keychain access in the sandbox and widget routing before you commit.

### Critical files for implementation
- `project.yml`
- `Packages/WheelhouseKit/Sources/WheelhouseDesktop/Safety/DevSafety.swift`
- `Packages/WheelhouseKit/Sources/WheelhouseDesktop/Moorings/MooringsService.swift`
- `WheelhouseMac/App/MacAppEnvironment.swift`
- `WheelhouseMac/App/FeatureRegistry.swift`

## 9. M1 sandbox spike findings (2026-11-17)

The spike (`spikes/mas-sandbox/`, branch `worktree-agent-a50b69f5f24a036e7`, commit 87ffb06, not merged) ran a minimal sandboxed app with development signing. The automatic wildcard Mac team profile accepted the team-prefixed keychain and app groups; no portal step was needed for development builds. These findings **override** the sections they name.

| Question | Result | What the implementation does |
|---|---|---|
| Bookmarks | App-scoped read-only bookmarks resolve after relaunch; a moved folder resolves stale with the new path; a deleted folder fails with Cocoa error 4. Reads fail with EPERM before `startAccessingSecurityScopedResource()` and again after `stop`. Writes through a read-only bookmark fail with EPERM. | §3.3: holding access for the app's lifetime is **required**. Refresh a stale bookmark while accessing it and save it again. Error 4 means "folder gone, ask again". Bookmarks come only from panel, drop or open URLs. |
| Reading outside a grant | `open`, `access(R_OK)` and `opendir` give **EPERM**; `stat` succeeds; a missing path gives ENOENT; `Data(contentsOf:)` gives Cocoa 257 with POSIX 1. EACCES never appeared. | §3.5: `needsAccess` = `stat` succeeds and `open` gives EPERM (or Cocoa 257 / POSIX 1). **Not EACCES**: a folder grant can't fix file modes. ENOENT stays `missingFiles`. Symlink targets outside the grant are untested: name the target's folder in the prompt. |
| FSEvents | Atomic replaces (write temp + rename, the kubectl pattern) are delivered on a granted folder, also after relaunch through a bookmark. Ungranted folders deliver events too (path and flags only). | §3.4: `FileWatcher` unchanged. Limiting roots to granted folders is a choice, not an OS rule; a watcher on an ungranted `~/.minikube` can clear `needsAccess` when the user grants it. |
| Real home | `getpwuid_r` gives `/Users/<user>`; `NSHomeDirectory()`, `$HOME` and `homeDirectoryForCurrentUser` give the container. `DevSafetyPolicy.accountHome` already uses `getpwuid_r`. | Use `accountHome` for the panel's start folder. Never use `NSHomeDirectory()` for the account home in MAS. |
| Keychain | Add, read and delete with an explicit group in the data-protection keychain work. A group not in the entitlements gives -34018. With no group, items land in the **first** listed group. | §4: keep `…wheelhouse.mas` **first** in `keychain-access-groups`. Two groups and `.shared` synchronizable items in the sandbox are checked on TestFlight on a separate macOS user. |
| Loopback listener | `NWListener` on 127.0.0.1 (same parameters as `PortForwardManager.bind`) binds and accepts. | `PortForwardManager` unchanged. |
| Login item | `SMAppService.mainApp.status` is readable (`notFound` for a build-folder app). | Owner check on TestFlight. |
| Subprocess | `/usr/bin` and `/bin` tools run (`true`, `zsh -c`, `id`); the child inherits the sandbox and its `$HOME` is the container. Third-party binaries (container copies, Homebrew, where `aws` lives) fail with `posix_spawn` EPERM. `Process.run()` reports EPERM and ENOENT as the same Cocoa error 4. | **M3: fail-closed must be an explicit code check** (`Edition.isSandboxed`); the OS does not stop system tools. Never infer "denied" from the Cocoa error; read errno through `access(X_OK)` when a reason is needed. |
| Parent lookup | `sysctl(KERN_PROC_PID)` works up the ancestor chain; `proc_pidpath` works for same-user ancestors; `proc_listallpids` is denied. | Beacon (later): walk the chain, never enumerate pids. |
| Widget scheme | Not measurable without registering a second app. LaunchServices has no explicit default for `wheelhouse:` and picks by an undocumented ranking. | §1: give MAS its own scheme `wheelhouse-mas`. `DeepLink.scheme` (Kit `Models/DeepLink.swift:37`, plus `importURL`/`isImport`) reads the scheme from Info.plist with a fallback to `wheelhouse`; the parser accepts both and emits the edition's own. |

Owner checks from the spike: (A) the open-panel grant, relaunch and stale-rename flow in the spike app (about 3 minutes); (B) the login item on a TestFlight build; (C) delete `~/Library/Containers/com.ahmadrezaei.wheelhouse.masspike` and `~/Library/Group Containers/JCZY58QP3L.com.ahmadrezaei.wheelhouse.masspike` (test data only; the automated shell can't); (D) a widget tap with both editions installed.
