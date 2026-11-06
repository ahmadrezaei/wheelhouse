# Wheelhouse

Wheelhouse is a native iPhone and iPad app for keeping an eye on — and hands on — several Kubernetes clusters at once.

- **Fleet dashboard** with health, capacity and the problems that need attention across every cluster.
- **Cluster dashboards** with nodes, workloads, events and CPU/memory from metrics-server or Prometheus (auto-detected).
- **Resource browser** for workloads, networking, config, storage, RBAC and custom resources, with search and namespaces.
- **Common actions** — scale, restart, delete, cordon/drain, suspend and trigger jobs — each previewed with a server-side dry run.
- **YAML** view, edit, diff and apply.
- **Live logs, a terminal into containers, and port forwarding.**
- **Safety**: mark clusters as production (typed confirmation for every change) or read-only.
- Face ID app lock, optional iCloud Keychain sync per cluster, Home Screen widgets and background alerts.
- Import a kubeconfig from Files or straight from the share sheet (WhatsApp, Telegram, Mail…), or add a cluster with a service-account token.

Wheelhouse talks directly to your clusters' API servers. It has no backend, no account and no analytics. See the [privacy policy](https://ahmadrezaei.github.io/wheelhouse/privacy.html).

## Requirements

- iOS / iPadOS 27 or later
- Xcode 27, [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Building

```bash
xcodegen generate
open Wheelhouse.xcodeproj
```

The app target is `Wheelhouse`; shared logic lives in the local Swift package `Packages/WheelhouseKit` (`WheelhouseKit` for the Kubernetes client, stores and streaming, `WheelhouseUI` for shared views). To build for your own device, change `bundleIdPrefix`, `DEVELOPMENT_TEAM` and the app group / keychain group in `project.yml`.

Launch with the `-WHDemoMode` argument (or tap Explore Demo on the welcome screen) to explore the app with a simulated fleet and no cluster.

See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together and [design/DESIGN.md](design/DESIGN.md) for the product and UI spec.

## Support

Questions and bug reports: [GitHub Issues](https://github.com/ahmadrezaei/wheelhouse/issues).

## License

[MIT](LICENSE)
