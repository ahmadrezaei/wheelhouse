import SwiftUI
import AppKit
import WebKit
import WheelhouseKit
import WheelhouseUI

/// Port-forward browser for the Mac (ARCHITECTURE-MAC section 1.6 row 14, section 12.3.4 item 11).
///
/// The default is **Open in Browser**: the system browser opens `http://127.0.0.1:<port>`. The optional **Preview** is the ONLY
/// `WKWebView` in the app (`import WebKit` is allowed in this file alone). It exists only while the user has it open: it is created
/// when Preview is switched on and released (its web content process exits) when Preview is closed, the sheet is dismissed, or the
/// window has been hidden or occluded for 30 seconds.
struct PortForwardBrowserView: View {
    let forward: PortForwardInfo
    @Environment(\.dismiss) private var dismiss
    @State private var controller = BrowserController()
    @State private var showsPreview = false
    @State private var copied = false
    @State private var hiddenSince: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showsPreview, let url = forward.url {
                BrowserWebView(url: url, controller: controller)
                    .overlay(alignment: .top) { if controller.isLoading { ProgressView(value: controller.progress).progressViewStyle(.linear) } }
                    .frame(minHeight: 320)
            } else {
                VStack(spacing: Spacing.m) {
                    Image(systemName: "arrow.left.arrow.right").font(.largeTitle).foregroundStyle(Palette.tintText).accessibilityHidden(true)
                    Text("Forwarding \(forward.target.title) to \(forward.localAddress)").font(.headline.monospaced()).multilineTextAlignment(.center)
                    Text("Open it in your browser, or preview it here. The preview is a lightweight web view that is released when you close it.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                .padding(Spacing.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 460, idealWidth: showsPreview ? 760 : 460, minHeight: showsPreview ? 460 : 260, idealHeight: showsPreview ? 560 : 260)
        .alert("Untrusted Certificate", isPresented: $controller.showTrustPrompt) {
            Button("Trust for This Session") { controller.resolveTrust(true) }
            Button("Cancel", role: .cancel) { controller.resolveTrust(false) }
        } message: {
            Text("\(forward.target.title) presents a certificate that can’t be verified (usually self-signed). Trust it for this forward only?")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { note in
            guard showsPreview, let window = note.object as? NSWindow, window.isKeyWindow || window.isVisible else { return }
            handleOcclusion(visible: window.occlusionState.contains(.visible))
        }
        .onDisappear { release() }
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image(systemName: "arrow.left.arrow.right").foregroundStyle(Palette.tintText)
            Text("\(forward.target.title) → \(forward.localAddress)").font(.footnote.monospaced()).lineLimit(1).truncationMode(.middle)
            Spacer()
            if showsPreview {
                Button { controller.webView?.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!controller.canGoBack).help("Back")
                Button { controller.webView?.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!controller.canGoForward).help("Forward")
                Button { controller.webView?.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
            }
            Button { copy() } label: { Label(copied ? "Copied" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc") }
            Button { showsPreview ? release() : (showsPreview = true) } label: {
                Label(showsPreview ? "Close Preview" : "Preview", systemImage: showsPreview ? "xmark" : "eye")
            }
            if let url = forward.url {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Browser", systemImage: "safari") }.buttonStyle(.borderedProminent)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Forward \(forward.target.title) on local port \(forward.localPort)")
    }

    private func copy() {
        Pasteboard.copy(forward.localAddress)
        copied = true
        Task { try? await Task.sleep(for: .seconds(2)); copied = false }
    }

    /// Tears the web view down: SwiftUI removes `BrowserWebView`, whose dismantle releases the `WKWebView`.
    private func release() {
        hiddenSince?.cancel(); hiddenSince = nil
        showsPreview = false
        controller.webView = nil
    }

    private func handleOcclusion(visible: Bool) {
        hiddenSince?.cancel(); hiddenSince = nil
        guard !visible else { return }
        hiddenSince = Task {
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled { release() }
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

struct BrowserWebView: NSViewRepresentable {
    let url: URL
    let controller: BrowserController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> WKWebView {
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

    func updateNSView(_ web: WKWebView, context: Context) {}

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.navigationDelegate = nil
        web.uiDelegate = nil
        coordinator.stopObserving()
    }

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

        func stopObserving() { observations.forEach { $0.invalidate() }; observations = [] }

        /// Loopback pages (the forwarded port) stay in the preview. Any other web link opens in the default browser.
        nonisolated static func isLoopback(_ url: URL) -> Bool {
            guard let host = url.host?.lowercased() else { return false }
            return host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
        }

        nonisolated static func opensExternally(_ url: URL) -> Bool {
            switch url.scheme?.lowercased() {
            case "http", "https": return !isLoopback(url)
            case "mailto", "tel": return true
            default: return false
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            if navigationAction.targetFrame?.isMainFrame == false { return .allow }
            if Self.opensExternally(url) { NSWorkspace.shared.open(url); return .cancel }
            return .allow
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if Self.opensExternally(url) { NSWorkspace.shared.open(url) } else { webView.load(navigationAction.request) }
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
