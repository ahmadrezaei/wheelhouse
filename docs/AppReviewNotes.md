# App Review notes: App Transport Security

Wheelhouse sets `NSAppTransportSecurity` > `NSAllowsArbitraryLoads = YES`. This is why, and what limits it.

**Why ATS is relaxed.** Wheelhouse is a Kubernetes client. The only servers it talks to are Kubernetes API servers (and optional Prometheus endpoints) that the user types in or imports from their own kubeconfig. These servers are almost always reached by IP address or an internal host name, and they present certificates issued by the cluster's own private certificate authority, which is supplied in the kubeconfig. The app cannot know the host names in advance, so per-domain exceptions are not possible. ATS performs its own system-trust evaluation for non-local hosts and rejects a private CA even after the app has validated the certificate itself, so the connection fails unless ATS is relaxed.

**What the app does instead.**
- Every connection is validated in the app (`URLSessionDelegate` server-trust handling backed by `SecTrust`) against the CA certificates the user supplied for that cluster, with host name checking. A connection is accepted only when that validation succeeds.
- Skipping certificate validation exists only as an explicit, per-cluster switch for non-production test clusters. It cannot be enabled for clusters marked Production.
- Production clusters are HTTPS only. The app refuses to send any request (including WebSocket exec and port-forward, and a user-supplied Prometheus URL) over `http://` to a cluster marked Production, and will not save such a configuration.
- The app contains no advertising, analytics, web browsing of third-party sites or any other internet traffic. It does not load content from arbitrary web sites.
- Plain HTTP can only be used for non-production clusters the user configured themselves (for example a local development cluster), and for the in-app preview of a port-forward, which loads `http://127.0.0.1:<port>` served by a tunnel on the device itself.

**Suggested text for the App Review "Notes" field.**

> Wheelhouse is a Kubernetes cluster manager. Users enter the address of their own Kubernetes API server (often an IP address or internal host name) and, in most cases, the private CA certificate from their kubeconfig. Because these hosts and CAs are user-specified, ATS cannot be configured per domain, and ATS's own system trust evaluation rejects private CAs, so NSAllowsArbitraryLoads is set. The app performs its own strict TLS validation against the user-provided CA for every connection, never accepts an unvalidated certificate unless the user explicitly disables verification for a non-production cluster, and refuses plain HTTP for clusters marked Production. No other network traffic is made.

# App Review notes: Wheelhouse for Mac (App Store edition)

This section is for the macOS platform of the app. The ATS text above applies to the Mac too. The one other network destination is described under First Mate below.

**What the app is.** Wheelhouse for Mac is a native, sandboxed Kubernetes manager. It shows the state of the user's own clusters (workloads, logs, YAML, events, metrics, Helm releases, security findings) and lets the user make changes after a confirmation. It talks directly to the clusters' API servers the user configures. There is no backend, no account and no analytics. It is free and open source (MIT).

**How to try it without a cluster: Demo mode.**
1. Launch the app. On the first-run screen (the Welcome screen, shown when no cluster is configured), click **Explore Demo**.
2. The sidebar fills with a simulated fleet. Nothing is read from the Mac and no network is used. Open **Fleet**, then a cluster, then **Workloads > Pods**. Double-click a pod, then use the **Logs** and **YAML** tiles.
3. To leave Demo mode: Wheelhouse > Settings > General > **Exit Demo Mode**. The same pane has **Explore Demo** if you left the first-run screen.

**Review cluster.** Demo mode is simulated. It shows the fleet, resources, logs, YAML, events and metrics. Pod shell, port-forward, Chart Room, Tides, Survey and First Mate need a real cluster (First Mate also needs an API key). For that, the owner attaches a service-account kubeconfig in the review notes field. It uses a token, so it needs no credential plugin. The account has the `view` role, plus `pods/portforward` and `pods/exec` in one namespace that contains a small web server Service. The token is revoked after review. No credentials are stored in this repository.

To use it: save the kubeconfig as a file, then on the Welcome screen click **Import kubeconfig** (or File > **Import File…**) and choose the file. The open panel grants access to that file, so no folder grant is needed. Imported clusters are read-only by default: turn on **Allow exec and port-forward** in the import sheet to try port-forward.

**Entitlements and why.**
- `com.apple.security.app-sandbox`: the app is sandboxed.
- `com.apple.security.network.client`: connections to the user's Kubernetes API servers and, optionally, Prometheus endpoints. Also `api.anthropic.com`, only after the user adds a key and consents to First Mate (see below).
- `com.apple.security.network.server`: the port-forward feature. When the user starts a port-forward, the app opens a listener on `127.0.0.1` only, so the user's browser or tools can reach a pod or service. The listener is loopback-only, is started only by a user action and is closed when the forward stops. The app never listens on a public interface.
- `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`: the user chooses their `.kube` folder (and, if needed, other folders) in an open panel, and the app remembers the choice with a bookmark. The app reads kubeconfig files only inside the folders the user granted, and the bookmarks are read-only. It never asks for access to the whole home folder and refuses it if chosen. Read-write is used only by save panels where the user exports Activity records or Survey findings to a file they name.
- Keychain access groups and an app group: cluster credentials stay in the Keychain (optionally synced through the user's iCloud Keychain, like the iPhone and iPad app), and the app shares a small status snapshot with its widgets.

**Login item.** The app can keep running in the menu bar and start at login. Both are **off by default**. The user turns them on in Settings > General > Menu bar and Rail ("Show Crow's Nest in the menu bar", "Open Wheelhouse at login"). The login item uses `SMAppService`.

**First Mate (optional AI assistant).** First Mate is off until the user adds their own Anthropic API key. Before the first message, the app asks for explicit consent that cluster data will be sent to the user's own Anthropic account, and it explains what is sent. Data goes only to Anthropic's API, using the user's key, and never to the developer. Every request can be inspected afterwards with **What Was Sent…**. Secret values are redacted before anything leaves the Mac. The key is stored in the Keychain on the user's device. First Mate never runs commands on the Mac: it proposes Kubernetes API actions, and the user must confirm each one.

**No downloaded or executed code.** The App Store edition does not download, install or run any code. It does not start other programs: the terminal, exec-plugin sign-in (aws, gcloud, kubelogin), Helm, Trivy, Landfall, the MCP server (Beacon) and Rigging are not included, and the process layer refuses to start any program when the app is sandboxed. It has no updater; updates come from the App Store. Helm releases are read-only, read directly from the cluster.

**Clusters that need a credential plugin.** The app shows "Uses `aws` (exec plugin). The App Store edition can't run credential plugins." for such contexts and links to https://ahmadrezaei.github.io/wheelhouse/mac/editions.html. This page explains the two editions. Short in-app notes (for example "Helm changes need the open-source edition.") link to the same page. The app has no download button and no direct download link for the other edition. The open-source edition is free and is described on the website and in the description.

**Folder grant flow (only needed to test kubeconfigs from a `.kube` folder).** Open Settings > Moorings and click **Grant .kube Folder…**. Choose the `.kube` folder in the open panel and confirm. The app refuses the home folder itself. If a kubeconfig refers to files in another folder (for example `~/.minikube`), the cluster row shows "Needs access" and a **Grant Folder** button. Settings > Moorings lists the granted folders and can remove them.

> Suggested text for the notes field: Wheelhouse for Mac is a sandboxed Kubernetes manager. To try it without a cluster, launch it and click "Explore Demo" on the first screen: it loads a simulated fleet with no network. A service-account kubeconfig for a real test cluster is attached below (import it on the Welcome screen). network.server is used only for loopback (127.0.0.1) listeners that the user starts for port-forwarding. The login item and menu bar mode are off by default. First Mate uses the user's own Anthropic key, asks for consent, shows what was sent and redacts Secrets. The app downloads and runs no code and starts no other programs.
