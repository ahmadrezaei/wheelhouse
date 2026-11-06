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
