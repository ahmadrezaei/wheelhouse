import AppKit
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Keeps the session alive for as long as the pane's view exists, and ends its shell when the view goes (the pane closed).
@MainActor
final class DeckTerminalHolder {
    let session: DeckTerminalSession
    init(session: DeckTerminalSession) { self.session = session }
    deinit {
        let session = session
        Task { @MainActor in await session.close() }
    }
}

/// A Deck Terminal pane: the banner, the terminal and the pane's menu. The shell starts when the pane first appears.
struct DeckTerminalPane: View {
    let spec: TerminalSpec
    @Environment(MacAppEnvironment.self) private var env
    @State private var holder: DeckTerminalHolder?

    var body: some View {
        Group {
            if let holder {
                DeckTerminalContent(session: holder.session)
            } else {
                Color.clear
            }
        }
        .onAppear { if holder == nil { holder = DeckTerminalHolder(session: DeckTerminalSession(env: env, spec: spec)) } }
    }
}

private struct DeckTerminalContent: View {
    let session: DeckTerminalSession
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.paneIsVisible) private var paneIsVisible

    var body: some View {
        VStack(spacing: 0) {
            if let model = session.model { DeckBanner(session: session, model: model) }
            ZStack {
                TerminalSurfaceHost(surface: session.surface)
                    .background(WindowReader { window in env.gangwaySheets.register(pane: session.paneID, name: session.title, window: window) })
                    .accessibilityLabel("Terminal, \(session.title)")
                if let error = session.startError {
                    EmptyState(.empty(title: "The terminal could not start", systemImage: "terminal", hint: error))
                        .background(.background)
                }
            }
        }
        .task { await session.start() }
        .onChange(of: session.title) { _, title in
            if let window = session.surface.view.window { env.gangwaySheets.register(pane: session.paneID, name: title, window: window) }
        }
        .onChange(of: env.lock.isLocked) { _, _ in session.model?.refreshBanner() }
        .toolbar { }
        .contextMenu {
            Button("New Shell") { Task { await session.restart() } }
            if case .available = session.directAvailability {
                Button("New Direct Shell (no guard)…") { Task { await openDirect() } }
            }
        }
    }

    private func openDirect() async {
        guard await AppLockController.authenticate(reason: "Open a shell that is not guarded by Wheelhouse") else { return }
        await session.restart(direct: true)
    }
}

/// The strip above the terminal.
private struct DeckBanner: View {
    let session: DeckTerminalSession
    let model: LocalShellModel

    var body: some View {
        let (text, tone, icon) = Self.content(model.banner)
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tone)
            Text(text).font(.callout).lineLimit(2)
            if let restored = session.restoredFrom {
                Text("Restored in \((restored as NSString).abbreviatingWithTildeInPath)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if model.canRestore {
                Button("Restore") { restore() }.controlSize(.small)
            }
            if model.isDirect {
                Button("Back to Guarded") { Task { await session.restart() } }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(tone.opacity(0.12))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("terminal-banner")
    }

    private func restore() {
        switch model.restore() {
        case .inserted, .refused: break
        case .needsNewShell: Task { await session.restart() }
        }
    }

    static func content(_ banner: ShellBanner) -> (String, Color, String) {
        switch banner {
        case .starting: ("Starting…", .secondary, "hourglass")
        case .guarded: ("kubectl and helm changes need confirmation.", Palette.healthyText, "lock.shield")
        case .awaitingMarks: ("Guarded. Waiting for the shell's first prompt.", Palette.infoText, "lock.shield")
        case .perRequest(let why): (why + ".", Palette.infoText, "exclamationmark.shield")
        case .unguarded(let why): ("Unguarded: \(why)", Palette.criticalText, "lock.open")
        case .integrationLost: ("This shell stopped reporting to Wheelhouse; KUBECONFIG is not verified.", Palette.infoText, "questionmark.shield")
        case .noIntegration: ("This shell has no Wheelhouse integration: changes it makes through Gangway ask for confirmation one request at a time, but its startup files may point it elsewhere.", Palette.infoText, "shield")
        case .direct: ("Direct: this shell is not guarded. Changes are not confirmed.", Palette.criticalText, "lock.open")
        case .sessionEnded(let why): ("The guarded session ended (\(why)). Restore opens a new shell.", Palette.infoText, "lock.slash")
        case .ended: ("The shell exited.", .secondary, "xmark.circle")
        }
    }
}

/// Reports the window the view is in.
private struct WindowReader: NSViewRepresentable {
    let onWindow: @MainActor (NSWindow?) -> Void

    final class Tracker: NSView {
        var onWindow: (@MainActor (NSWindow?) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            MainActor.assumeIsolated { onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Tracker {
        let view = Tracker()
        view.onWindow = onWindow
        return view
    }
    func updateNSView(_ view: Tracker, context: Context) { view.onWindow = onWindow }
}
