import SwiftUI
import WheelhouseKit

/// Full-screen states from DESIGN.md §5, built on `ContentUnavailableView`.
public enum EmptyStateKind {
    case loading
    case empty(title: String, systemImage: String = "tray", hint: String? = nil)
    case filteredEmpty(filter: String)
    case error(message: String)
    case forbidden(subject: String? = nil, verb: String? = nil, resource: String? = nil, namespace: String? = nil, message: String? = nil)
    case unauthorized(clusterName: String)
    case unreachable(cause: String)
    case credentialsMissing(clusterName: String)
    case tlsError(summary: String?)

    /// Maps an API error to the matching state.
    public init(error: KubeError, clusterName: String = "this cluster") {
        switch error {
        case .forbidden(let verb, let resource, let ns, let message): self = .forbidden(verb: verb, resource: resource, namespace: ns, message: message)
        case .unauthorized: self = .unauthorized(clusterName: clusterName)
        case .unreachable(let cause): self = .unreachable(cause: cause)
        case .tlsUntrusted(let summary): self = .tlsError(summary: summary)
        default: self = .error(message: error.summary)
        }
    }
}

public struct EmptyState<Actions: View>: View {
    private let kind: EmptyStateKind
    private let actions: Actions

    public init(_ kind: EmptyStateKind, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.kind = kind
        self.actions = actions()
    }

    public var body: some View {
        switch kind {
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityLabel("Loading")
        case .empty(let title, let image, let hint):
            ContentUnavailableView { Label(title, systemImage: image) } description: { if let hint { Text(hint) } } actions: { actions }
        case .filteredEmpty(let filter):
            ContentUnavailableView { Label("No Matches", systemImage: "line.3.horizontal.decrease.circle") } description: {
                Text("Nothing matches \(Text(filter).font(.whCode)).")
            } actions: { actions }
        case .error(let message):
            ContentUnavailableView { Label("Something Went Wrong", systemImage: "exclamationmark.triangle") } description: { Text(message) } actions: { actions }
        case .forbidden(let subject, let verb, let resource, let namespace, let message):
            ContentUnavailableView {
                Label("Access Denied", systemImage: "hand.raised")
            } description: {
                VStack(spacing: 8) {
                    Text([subject.map { "\($0) " } ?? "You ", "cannot ", verb ?? "access", resource.map { " \($0)" } ?? "", namespace.map { " in \($0)" } ?? ""].joined())
                    if let message { Text(message).font(.whCodeSmall).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code)).textSelection(.enabled) }
                }
            } actions: { actions }
        case .unauthorized(let name):
            ContentUnavailableView { Label("Credentials Rejected", systemImage: "key.slash") } description: { Text("The credentials for \(name) were rejected (401). They may have expired or been revoked.") } actions: { actions }
        case .unreachable(let cause):
            ContentUnavailableView { Label("Can’t Reach Cluster", systemImage: "wifi.slash") } description: { Text(cause) } actions: { actions }
        case .credentialsMissing(let name):
            ContentUnavailableView { Label("Credentials not on this device", systemImage: "key.slash") } description: {
                Text("\(name) needs credentials that are not stored on this device. If it syncs through iCloud Keychain they may not have arrived yet; otherwise edit the cluster and enter them again.")
            } actions: { actions }
        case .tlsError(let summary):
            ContentUnavailableView { Label("Certificate Not Trusted", systemImage: "checkmark.seal") } description: {
                VStack(spacing: 6) {
                    Text("The server’s certificate could not be verified. Add the cluster’s CA certificate to trust it.")
                    if let summary { Text(summary).font(.whCodeSmall).textSelection(.enabled) }
                }
            } actions: { actions }
        }
    }
}

/// Inline banners: states that sit above content instead of replacing it.
public enum BannerKind {
    case partialMetrics
    case noMetrics
    case readOnly
    case demo
    case offline
    case partiallyForbidden(detail: String)
    case cached(age: String)
    case custom(tone: StatusTone, symbol: String, title: String, message: String?)

    var content: (tone: StatusTone, symbol: String, title: String, message: String?) {
        switch self {
        case .partialMetrics: (.info, "chart.line.uptrend.xyaxis", "Live samples only", "History needs Prometheus. Configure it in cluster settings.")
        case .noMetrics: (.info, "gauge.with.dots.needle.0percent", "No metrics source found", "Showing requests and limits only. Install metrics-server for live usage.")
        case .readOnly: (.info, "lock.fill", "Read-only cluster", "Changes are disabled. Turn off read-only mode in cluster settings.")
        case .demo: (.warning, "sparkles", "Demo mode", "You’re exploring sample clusters. Nothing here is real.")
        case .offline: (.warning, "wifi.slash", "You’re offline", "Showing cached data where available.")
        case .partiallyForbidden(let detail): (.warning, "hand.raised", "Some data is hidden", detail)
        case .cached(let age): (.unknown, "clock.arrow.circlepath", "Cached \(age) ago", "Actions are disabled until the cluster is reachable again.")
        case .custom(let tone, let symbol, let title, let message): (tone, symbol, title, message)
        }
    }
}

public struct StateBanner<Action: View>: View {
    private let kind: BannerKind
    private let action: Action
    public init(_ kind: BannerKind, @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.kind = kind
        self.action = action()
    }
    public var body: some View {
        let c = kind.content
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.symbol).foregroundStyle(c.tone.color).font(.body)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.subheadline.weight(.semibold)).foregroundStyle(c.tone.textColor)
                if let m = c.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                action
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(c.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Redacted placeholder rows for the first load (no spinner).
public struct SkeletonList: View {
    private let rows: Int
    public init(rows: Int = 6) { self.rows = rows }
    public var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { _ in
                ResourceRow(title: "placeholder-resource-name", subtitle: "namespace · Running · 3d", lead: .symbol("cube", .unknown), trailing: "1/1")
                    .padding(.horizontal, Spacing.l)
                Divider().padding(.leading, Spacing.l)
            }
        }
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading")
    }
}
