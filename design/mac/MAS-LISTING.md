# Wheelhouse for Mac, App Store edition: App Store Connect text

For the macOS platform of app 6831379262. Paste each block as is. Character counts are in the table at the end (Python `len`). The app is not submitted yet.

Guidelines to keep in mind when editing: 2.3 (the text describes this edition only, and no feature it lacks), 4.2 (it is a full native app and works without a cluster in Demo mode), and the open-source edition is mentioned only as text and website links, never as a download button in the app.

## Subtitle (30 characters, shared with iOS)

The iOS subtitle is already set in App Store Connect and is not stored in this repository, so the owner must compare. Proposed text that fits both platforms:

```
Kubernetes clusters, native
```

It promises no feature the Mac edition lacks, and it is true on iPhone and iPad too. The subtitle is shared: changing it changes the iOS listing too. Compare it with the current iOS subtitle in App Store Connect and keep whichever is accurate for both.

## Promotional text (170 characters maximum)

```
A native, sandboxed Kubernetes manager for Mac. Watch every cluster, read logs and YAML, and make changes with a confirmation. Free and open source, no account.
```

## Description (4000 characters maximum)

```
Wheelhouse is a native, sandboxed Kubernetes manager for Mac. It connects straight to your clusters' API servers. There is no account, no backend and no analytics. It is free and open source.

Watch your whole fleet

• One overview of every cluster: health, nodes, workloads, alerts and metrics.
• Pods, Deployments, Services, Nodes, Events, CRDs and more, in fast tables you can filter and sort.
• Logs that stream live, with search and filters. YAML you can read, copy and edit.
• Open a shell in a pod. Forward a port and preview it in the app.
• A workspace with tabs, split panes, the Compass command palette and a Rail of your favorite clusters.
• Desktop widgets, and an optional menu bar item that keeps an eye on your clusters when the window is closed. Alerts for crash loops, nodes that are not ready, failed jobs and unreachable clusters.

Made for production

• Clusters you import start read-only. Changes need you to allow them first.
• On Production clusters every change waits for your confirmation. Production clusters never use plain HTTP.
• Connections are checked against the CA certificate in your kubeconfig.
• Credentials are kept in the Keychain. Clusters you choose to sync through iCloud Keychain appear on your iPhone, iPad and Mac. An app lock is available.

More in this edition

• Chart Room: browse Helm releases straight from the cluster. See history, values and manifests, and compare two revisions. It is read-only.
• Survey: see vulnerabilities from Trivy Operator reports, and risky RBAC and pod settings found by built-in rules.
• Tides: see the state of Flux and Argo CD applications, with target and live revision side by side.
• First Mate: an optional assistant that answers questions about your clusters. You bring your own Anthropic API key. Wheelhouse asks for your consent first, shows exactly what was sent, and redacts Secret values. Requests go from your Mac to your own Anthropic account, and the developer never sees them. First Mate proposes actions and never makes a change without your confirmation.
• Demo mode: try a simulated fleet with no cluster and no network.

Works inside the App Sandbox

You grant access to your .kube folder once, and Wheelhouse reads kubeconfig files only from folders you allow, or files you import. It does not download or run other programs.

Not included in this edition:
• A terminal
• Sign-in through exec plugins (for EKS, GKE and AKS kubeconfigs that call aws, gcloud or kubelogin). Kubeconfigs with a token or a client certificate work fully.
• Discovery of clusters in your cloud accounts
• Helm install, upgrade, rollback and repositories
• Scanning images with Trivy on your Mac
• Flux diff
• The MCP server for AI assistants

An open-source edition with these features is available from the project's website.

Requires an Apple silicon Mac with macOS 27 or later. English only.

Wheelhouse is open source under the MIT License.
```

## Keywords (100 characters maximum)

```
kubernetes,k8s,containers,cluster,pods,helm,devops,yaml,logs,kubeconfig,flux,argo
```

This is the list from plan section 6, with `kubectl` swapped for `containers` because this edition has no terminal. Apple indexes the app name and subtitle already, so "kubernetes" is partly redundant while the subtitle holds it. A variant that frees that space:

```
k8s,cluster,pods,helm,devops,yaml,logs,kubeconfig,flux,argo,containers,deployments,manifest
```

## URLs

| Field | URL |
|---|---|
| Support URL | https://ahmadrezaei.github.io/wheelhouse/mac/support.html |
| Marketing URL | https://ahmadrezaei.github.io/wheelhouse/mac/ |
| Privacy Policy URL | https://ahmadrezaei.github.io/wheelhouse/privacy.html |
| Edition differences (linked from the app, not an App Store Connect field) | https://ahmadrezaei.github.io/wheelhouse/mac/editions.html |

## App Privacy labels

Answer: **Data Not Collected.** Wheelhouse has no server and no analytics, and the developer receives nothing. Nothing leaves the Mac except traffic to the user's own clusters and, only if the user turns on First Mate, requests to Anthropic.

Explanation, if App Review asks: First Mate is off until the user adds their own Anthropic API key and agrees to a consent sheet. Requests go from the app to Anthropic with the user's key, and belong to the user's own Anthropic account. The developer has no access to the key, the requests or the answers, so the developer collects nothing. The privacy policy says this. The answers are the same as the iOS app's.

## Age rating

Category: Developer Tools. Answer conservatively.

- Violence, sexual content, nudity, profanity, horror, gambling, alcohol, drugs, contests: None.
- Unrestricted web access: No. The app does not browse the web. The port-forward preview shows a service on the user's own loopback address.
- User-generated content shared between users: No. Messaging or chat between users: No.
- AI chat feature, if the questionnaire asks: Yes. First Mate is a chat assistant that answers questions about the user's own clusters, using a third-party model with the user's own API key. It has no feed, and it shares nothing between users.
- Medical or wellness, loot boxes, age assurance: No.

Expected rating: 4+. If the questionnaire raises it because of the AI feature, accept the result.

## Copyright

```
2026 Ahmad Rezaei
```

Confirm the legal name with the owner. The repository license is MIT.

## Screenshots

Target: 2880 x 1800 pixels (a 1440 x 900 point window on a Retina display), window only, Demo fleet only. The owner approves them before upload.

The UI test `WheelhouseMASUITests/WheelhouseMASScreenshots.swift` (scheme `WheelhouseMASUI`) launches the MAS Debug app with `-WHDemoMode -WHResetState`, checks that only the four demo clusters are in the sidebar, and saves six window screenshots: fleet overview, workloads (pods), pod logs, YAML, Chart Room releases (read-only) and Survey. UI automation starts fine on this Mac, but XCUI drags could not resize the window, so the test skips until the window is 1440 x 900. Owner steps:

1. Build: `xcodebuild build-for-testing -project Wheelhouse.xcodeproj -scheme WheelhouseMASUI -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/dd-mas`.
2. Launch `.build/dd-mas/Build/Products/Debug/WheelhouseMAS.app` with `-WHDemoMode -WHResetState`, resize the window to 1440 x 900 points (for example with System Events: `tell application "System Events" to tell process "WheelhouseMAS" to set size of window 1 to {1440, 900}`), then quit with Command-Q. The app saves the frame.
3. Run `xcodebuild test-without-building ... -scheme WheelhouseMASUI -resultBundlePath .build/shots.xcresult`. The PNGs are attachments in the result bundle (and are written to `design/mac/screenshots-mas/` when the runner may write there). Check each image is 2880 x 1800 and shows demo data only.

## Counts

| Field | Characters |
|---|---|
| Subtitle (max 30) | 27 |
| Promotional text (max 170) | 160 |
| Description (max 4000) | 2924 |
| Keywords (max 100) | 81 |
| Keywords variant (max 100) | 91 |
