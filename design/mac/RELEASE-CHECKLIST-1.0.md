# Wheelhouse for Mac 1.0: release checklist

Mac 1.0 ships every feature except Rigging (M13). Rigging is built on its own branch and goes out in a later update.
`FeatureRegistry.releaseEnabled` holds what a Distribution build shows; the Settings ▸ Rigging pane is hidden there.

## Done in the release prep
- [x] Distribution builds enable every finished feature. Before this change `releaseEnabled` was empty, so a Distribution build would have shown no feature panes at all.
- [x] Rigging is left out of the Distribution build: no panes, no sidebar nodes and no Settings pane. The docs say it comes later.
- [x] Test-only hooks were audited: Gangway auto-approve and synthetic input are compiled only with `WH_TEST_HOOKS`, which is Debug only. The `-WH…` launch arguments (kubeconfig path, workspace file, reset, import, demo, perf) are honoured only while the development safety gate is on, and the gate is off only in Distribution.
- [x] Docs claims match what ships: Compass, Rail and Crow's Nest were corrected, and Rigging is marked as coming later.
- [x] Release notes drafted: `docs/mac/notes/Wheelhouse-1.0.0.html`. Read and edit them; the script refuses to publish notes that contain the word "placeholder".

## Owner steps, in order

### 1. One-time setup on this Mac
- [x] **Helm binary.** Downloaded with `scripts/fetch-helm.sh` and checked against the committed SHA-256 (helm 4.3.1). It is git-ignored, so a fresh checkout must run the script again.
- [x] **Notarization profile.** `wheelhouse-notary` is stored in the keychain (app-specific password, set up 2026-11-13).
  Original note: Run `xcrun notarytool store-credentials wheelhouse-notary ...` with an App Store Connect API key or an app-specific password. See the header of `scripts/release-mac.sh`.
- [x] **Sparkle private key.** It is in the login keychain and matches `WH_SU_PUBLIC_ED_KEY`; the release preflight checked this. Back the private key up somewhere safe if you haven't: losing it means no more updates for installed copies.
- [ ] The Developer ID Application certificate (team JCZY58QP3L) is already in the keychain.

### 2. Decisions still open
- [ ] **Pricing and support:** decision 24. Fill in the `.todo` placeholders in `docs/mac/getting-started.html` and `docs/mac/support.html`.
- [ ] **Languages:** decision 23 (same set as iOS).
- [ ] **Privacy page:** the effective date and contact in `docs/mac/privacy.html`.
- [ ] **Trivy download:** `Packages/WheelhouseKit/Sources/WheelhouseDesktop/Resources/trivy/pin.json` has `"version": null`, so the app offers no Trivy download, only a Trivy you install yourself. Either pin a release (every field, from its checksums after checking the signature) or ship as is.
- [ ] **GitHub private vulnerability reporting:** turn it on for the repo. `docs/mac/support.html` points security reports there.

### 3. Build the release candidate
- [x] Signed dry run on 2026-11-13: `scripts/release-mac.sh 1.0.0 1 --local --no-notarize --skip-tests` passed. Archive and Developer ID export succeeded, every Mach-O has the hardened runtime, a timestamp and the Developer ID signature, `mac-entitlement-check` passed for Distribution, and the signed DMG was built. Gatekeeper accepted it before notarization.
- [x] Notarized release candidate built on 2026-11-13: `.build/mac/releases/Wheelhouse-1.0.0.dmg`. Apple accepted it, it is stapled, and Gatekeeper reports "Notarized Developer ID" for both the DMG and the app. The script's test step was skipped because the same suites had passed on this code.
  Original step: run `scripts/release-mac.sh 1.0.0 1`. It runs lint and tests, archives Distribution, signs with Developer ID, applies the hardened runtime, runs the entitlement check, builds the DMG, and notarizes and staples it. It does **not** publish.

### 4. Smoke test on a separate macOS user
The Distribution build has the safety gate off and reads `~/.kube`, so never run it on your own user.
- [ ] Install the DMG on a fresh macOS user with no `~/.kube`. Gatekeeper must open it without warnings.
- [ ] Import `.testcluster/kubeconfig` (the minikube test cluster) and mark it Production.
- [ ] **Confirmations:**
  - a delete in the app shows the confirmation sheet;
  - on Production, a sheet from First Mate, Beacon or a terminal has no default button and needs typing.
- [ ] **Deck Terminal:**
  - `kubectl delete pod …` on Production asks for confirmation;
  - on a read-only cluster it is refused.
- [ ] **Lock:**
  - turn on the app lock in Settings ▸ Safety & Security, then lock the Mac;
  - the app shows the lock screen and Compass, the Rail and the menu bar panel reveal nothing.
- [ ] **Crow's Nest:**
  - close every window with Keep running on: the Dock icon goes away and a crash-looping test pod raises a notification;
  - clicking the notification opens a window.
- [ ] **Login item:** turn on "Open at login", log out and back in.
- [ ] **Widgets:** add Fleet Health and Cluster from the widget gallery and check they show data.
- [ ] **First Mate:** with a real key, ask about a failing pod; Secret values must not appear in "what was sent".
- [ ] **Beacon:** connect one MCP client (for example Claude Desktop); the approval asks for Touch ID; Stop Beacon disconnects it.
- [ ] **Updates:** Settings ▸ Updates ▸ Check Now reaches the feed without errors.
- [ ] **Battery:** after an hour in the menu bar, the battery menu does not list Wheelhouse.

### 5. Publish
- [ ] Run `scripts/release-mac.sh 1.0.0 1 --publish`. It asks you to type the version, then creates the appcast and the GitHub release (`mac-v1.0.0`) and pushes.
- [ ] Check the download page and the appcast URL in a browser.

## Known limits shipping in 1.0 (tracked for 1.1)
- **Memory:**
  - after an hour of heavy use with overlapping windows, the peak can reach about 230 MB against the 200 MB internal budget (the M4a soak gate is still open);
  - P2, the second performance pass on a Distribution build, has not run.
- **Not audited yet:**
  - accessibility (VoiceOver, keyboard, contrast) uses standard SwiftUI behaviour, without an audit pass;
  - the Mac UI test suite needs a one-time automation approval and has not run in this release cycle.
- **Features:**
  - Compass does not yet search Helm releases, GitOps apps or Survey findings;
  - `?` (Ask First Mate) and `!` (run in a terminal) show a hint only.
- **Crow's Nest:** with every window closed, a full health check runs every 5 minutes for Production clusters and every 15 for others, so notifications can arrive later than with a window open.
- **Rigging (M13)** is complete on branch `worktree-agent-ab42170c7ba45f2de`. It needs its security review rerun (the first attempt was cut off by a network error), its perf baseline, and a live fixture check before it ships.
