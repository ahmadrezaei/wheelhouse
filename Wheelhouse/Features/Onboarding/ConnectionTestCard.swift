import SwiftUI
import WheelhouseKit
import WheelhouseUI

enum ConnectionTestState: Equatable {
    case idle
    case running
    case done(ConnectionTestResult)
}

/// Result of the connection test: version, latency, node count, RBAC capabilities — or a precise error explanation.
struct ConnectionTestCard: View {
    let state: ConnectionTestState
    let isLocalhost: Bool
    var onRun: () -> Void

    var body: some View {
        Group {
            switch state {
            case .idle:
                Button(action: onRun) { Label("Test connection", systemImage: "bolt.horizontal") }
            case .running:
                HStack { ProgressView(); Text("Testing connection…").foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
            case .done(let r):
                if let error = r.error { failure(error) } else { success(r) }
                Button(action: onRun) { Label("Re-run test", systemImage: "arrow.clockwise") }
            }
        }
    }

    @ViewBuilder private func success(_ r: ConnectionTestResult) -> some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.healthy).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Connected · Kubernetes \(r.version ?? "?")").font(.body.weight(.semibold))
                Text([r.latencyMilliseconds.map { "\($0) ms" }, r.nodeCount.map { "\($0) node\($0 == 1 ? "" : "s")" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        ForEach(r.capabilities) { cap in
            HStack {
                Image(systemName: symbol(cap.allowed)).foregroundStyle(color(cap.allowed)).frame(width: 24)
                Text(cap.title)
                Spacer()
                Text(label(cap.allowed)).font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
        if r.capabilities.contains(where: { $0.allowed == false }) {
            Text("This identity can do less than an admin. Wheelhouse will hide or disable what you can’t do.").font(.footnote).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func failure(_ error: KubeError) -> some View {
        let info = Self.explain(error, isLocalhost: isLocalhost)
        VStack(alignment: .leading, spacing: Spacing.s) {
            Label(info.title, systemImage: info.symbol).font(.body.weight(.semibold)).foregroundStyle(Palette.criticalText)
            Text(info.message).font(.footnote)
            if let detail = info.detail { Text(detail).font(.whCodeSmall).textSelection(.enabled).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code)) }
        }
        .accessibilityElement(children: .combine)
    }

    struct Explanation { var title: String; var message: String; var detail: String?; var symbol: String }

    static func explain(_ error: KubeError, isLocalhost: Bool) -> Explanation {
        switch error {
        case .tlsUntrusted(let summary):
            Explanation(title: "Certificate not trusted",
                        message: "The server’s certificate could not be verified. Paste or import the cluster’s CA certificate. For a non-production cluster you can also skip verification (not recommended).",
                        detail: summary, symbol: "checkmark.seal")
        case .unauthorized:
            Explanation(title: "Credentials rejected (401)", message: "The server reached us but did not accept this token or certificate. It may have expired, been revoked, or belong to another cluster.", detail: nil, symbol: "key.slash")
        case .forbidden(_, _, _, let m):
            Explanation(title: "Access denied (403)", message: "The credentials are valid but may not read cluster information.", detail: m, symbol: "hand.raised")
        case .unreachable(let cause):
            Explanation(title: "Can’t reach the server", message: isLocalhost
                        ? "127.0.0.1 / localhost points at this device. A cluster running on your Mac is only reachable from the Simulator or the Mac itself — use its LAN address or a tunnel on a real iPhone."
                        : "Check the address, port, VPN/firewall and that the API server is reachable from this device's network.",
                        detail: cause, symbol: "wifi.slash")
        default:
            Explanation(title: "Connection failed", message: error.summary, detail: nil, symbol: "exclamationmark.triangle")
        }
    }

    private func symbol(_ a: Bool?) -> String { a == true ? "checkmark.circle.fill" : a == false ? "minus.circle.fill" : "questionmark.circle" }
    private func color(_ a: Bool?) -> Color { a == true ? Palette.healthy : a == false ? Palette.unknown : Palette.warning }
    private func label(_ a: Bool?) -> String { a == true ? "Allowed" : a == false ? "Not allowed" : "Unknown" }
}
