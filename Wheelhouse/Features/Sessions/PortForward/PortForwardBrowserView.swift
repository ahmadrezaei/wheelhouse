import SwiftUI
import WebKit
import WheelhouseKit
import WheelhouseUI

/// In-app browser for a local port-forward (`http://127.0.0.1:<port>`). Self-signed certificates are accepted for the
/// loopback address only after an explicit prompt.
struct PortForwardBrowserView: View {
    let forward: PortForwardInfo
    @Environment(\.dismiss) private var dismiss
    @State private var controller = BrowserController()
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.tintText)
                    Text("\(forward.target.title) → \(forward.localAddress)").font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if controller.isLoading { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, Spacing.l).padding(.vertical, 8)
                .background(.bar)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Using forward \(forward.target.title) on local port \(forward.localPort)")

                if let url = forward.url {
                    BrowserWebView(url: url, controller: controller)
                        .overlay(alignment: .top) { if controller.isLoading { ProgressView(value: controller.progress).progressViewStyle(.linear) } }
                } else {
                    EmptyState(.error(message: "Invalid address."))
                }
            }
            .navigationTitle(controller.title ?? "Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { controller.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!controller.canGoBack).accessibilityLabel("Back")
                    Button { controller.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!controller.canGoForward).accessibilityLabel("Forward")
                    Spacer()
                    Button { controller.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload")
                    Spacer()
                    if let url = controller.currentURL ?? forward.url {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share")
                    }
                    // Localhost addresses are meaningless outside the device, so "Open in Safari" is intentionally unavailable.
                    Button {} label: { Image(systemName: "safari") }.disabled(true).accessibilityLabel("Open externally, unavailable for localhost")
                }
            }
            .alert("Untrusted Certificate", isPresented: $controller.showTrustPrompt) {
                Button("Trust for This Session") { controller.resolveTrust(true) }
                Button("Cancel", role: .cancel) { controller.resolveTrust(false) }
            } message: {
                Text("\(forward.target.title) presents a certificate that can’t be verified (usually self-signed). Trust it for this forward only?")
            }
        }
    }
}

@MainActor @Observable
final class BrowserController {
    var title: String?
    var isLoading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    var currentURL: URL?
    var showTrustPrompt = false
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored private var pendingTrust: (@MainActor (Bool) -> Void)?
    @ObservationIgnored var trustedLocalhost = false

    func askTrust(_ completion: @escaping @MainActor (Bool) -> Void) {
        pendingTrust = completion
        showTrustPrompt = true
    }

    func resolveTrust(_ allow: Bool) {
        if allow { trustedLocalhost = true }
        pendingTrust?(allow)
        pendingTrust = nil
    }
}

struct BrowserWebView: UIViewRepresentable {
    let url: URL
    let controller: BrowserController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.allowsBackForwardNavigationGestures = true
        context.coordinator.observe(web)
        controller.webView = web
        web.load(URLRequest(url: url))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let controller: BrowserController
        private var observations: [NSKeyValueObservation] = []

        init(_ controller: BrowserController) { self.controller = controller }

        func observe(_ web: WKWebView) {
            observations = [
                web.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.title = w.title } },
                web.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.isLoading = w.isLoading } },
                web.observe(\.estimatedProgress) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.progress = w.estimatedProgress } },
                web.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.canGoBack = w.canGoBack } },
                web.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.canGoForward = w.canGoForward } },
                web.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.controller.currentURL = w.url } },
            ]
        }

        /// Loopback pages (the forwarded port) stay in the app. Any other web link opens in Safari.
        nonisolated static func isLoopback(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        }

        /// What to do with a link: load it in the page, or hand it to the system.
        nonisolated static func opensExternally(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "http", "https": return !isLoopback(url)
            case "mailto", "tel": return true
            default: return false
            }
        }

        private func openExternally(_ url: URL) { UIApplication.shared.open(url) }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            // Only top-level navigations and link clicks are intercepted; embedded frames load as usual.
            if navigationAction.targetFrame?.isMainFrame == false { return .allow }
            if Self.opensExternally(url) { openExternally(url); return .cancel }
            return .allow
        }

        /// `target="_blank"` / `window.open`: stay in this web view for loopback, otherwise Safari. Never silently drop it.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if Self.opensExternally(url) { openExternally(url) } else { webView.load(navigationAction.request) }
            return nil
        }

        func webView(_ webView: WKWebView, respondTo challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let trust = challenge.protectionSpace.serverTrust else { return (.performDefaultHandling, nil) }
            let host = challenge.protectionSpace.host
            guard host == "127.0.0.1" || host == "localhost" else { return (.performDefaultHandling, nil) }
            if SecTrustEvaluateWithError(trust, nil) { return (.performDefaultHandling, nil) }
            if controller.trustedLocalhost { return (.useCredential, URLCredential(trust: trust)) }
            let allowed = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in controller.askTrust { cont.resume(returning: $0) } }
            return allowed ? (.useCredential, URLCredential(trust: trust)) : (.cancelAuthenticationChallenge, nil)
        }
    }
}
