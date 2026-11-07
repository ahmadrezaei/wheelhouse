import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// Mac placeholder with the same `PortForwardBrowserView(forward:)` API as iOS. The Mac default is **Open in Browser**
/// (`NSWorkspace.open`). M1b adds the optional in-app `WKWebView` preview tab here, the ONLY WebView in the app
/// (ARCHITECTURE-MAC §12.3.4 item 11); `import WebKit` is allowed in this file alone.
struct PortForwardBrowserView: View {
    let forward: PortForwardInfo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Spacing.l) {
            Image(systemName: "arrow.left.arrow.right").font(.largeTitle).foregroundStyle(Palette.tintText)
            Text("\(forward.target.title) → \(forward.localAddress)").font(.headline.monospaced())
            if let url = forward.url {
                Button { NSWorkspace.shared.open(url) } label: { Label("Open in Browser", systemImage: "safari") }
                    .buttonStyle(.borderedProminent)
            } else {
                Text("Invalid address.").foregroundStyle(.secondary)
            }
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(Spacing.xxl)
        .frame(minWidth: 380, minHeight: 220)
    }
}
