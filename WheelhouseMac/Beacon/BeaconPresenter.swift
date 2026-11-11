import AppKit
import Observation
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Shows Beacon's approval sheet and change-request confirmation sheets, one at a time, in a small window of their own.
///
/// Beacon asks from the background, so there may be no workspace window to attach a sheet to (and `MacShell` is not ours to edit).
/// The window comes forward when a request arrives and goes away when the queue is empty. Requests wait their turn; a request whose
/// task is cancelled (the client went away, the timeout passed, Beacon stopped, the app locked) leaves the queue or closes at once.
@MainActor @Observable
final class BeaconPresenter {
    enum Item: @unchecked Sendable {   // only ever touched on the main actor
        case approval(BeaconApprovalRequest)
        case confirm(ConfirmRequest)
    }

    /// One queued or visible request. The id is unique per ask, so a withdrawn ask never closes someone else's sheet.
    struct Shown: Identifiable, @unchecked Sendable {
        let id: String
        let item: Item
    }

    private struct Entry {
        let shown: Shown
        let finish: @MainActor (Resolution) -> Void
    }

    /// `dismissed` is a withdrawal (lock, Stop, cancel); `userDismissed` is the person closing the sheet.
    enum Resolution { case approval(BeaconApprovalDecision), dismissed, userDismissed }

    /// The sheet on screen now.
    private(set) var current: Shown?
    @ObservationIgnored private var currentFinish: (@MainActor (Resolution) -> Void)?
    @ObservationIgnored private var queue: [Entry] = []
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let activity: any ActivityLogging

    init(registry: ClusterRegistry, activity: any ActivityLogging) {
        self.registry = registry
        self.activity = activity
    }

    var pendingCount: Int { queue.count + (current == nil ? 0 : 1) }

    // MARK: Asking

    func ask(_ request: BeaconApprovalRequest) async -> BeaconApprovalDecision {
        let resolution = await run(.approval(request))
        switch resolution {
        case .approval(let decision): return decision
        case .userDismissed: return .deny
        case .dismissed: return .withdrawn
        }
    }

    /// Shows a confirmation. Returns when the sheet closed (after the person confirmed, declined, or the task was cancelled).
    func confirm(_ request: ConfirmRequest) async {
        _ = await run(.confirm(request))
    }

    private func run(_ item: Item) async -> Resolution {
        let shown = Shown(id: UUID().uuidString, item: item)
        let id = shown.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.append(Entry(shown: shown) { continuation.resume(returning: $0) })
                advance()
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(id) }
        }
    }

    private func advance() {
        guard current == nil, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        currentFinish = next.finish
        current = next.shown
        showWindow()
    }

    /// Closes the sheet or drops the queue entry for an ask whose task went away.
    func withdraw(_ id: String) {
        if let i = queue.firstIndex(where: { $0.shown.id == id }) {
            queue.remove(at: i).finish(.dismissed)
        } else if current?.id == id {
            resolve(.dismissed)
        }
    }

    /// Closes everything: Beacon stopped, or the app locked (a sheet must not survive until unlock).
    func withdrawAll() {
        let waiting = queue
        queue = []
        waiting.forEach { $0.finish(.dismissed) }
        if current != nil { resolve(.dismissed) }
    }

    func resolve(_ resolution: Resolution) {
        guard current != nil else { return }
        let finish = currentFinish
        current = nil
        currentFinish = nil
        finish?(resolution)
        if queue.isEmpty { window?.orderOut(nil) } else { advance() }
    }

    // MARK: Window

    private func showWindow() {
        if window == nil {
            let hosting = NSHostingController(rootView: BeaconPresenterRoot(presenter: self).environment(registry).environment(\.activityLog, activity))
            let w = NSWindow(contentViewController: hosting)
            w.title = "Beacon"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 360, height: 120))
            window = w
        }
        window?.center()
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct BeaconPresenterRoot: View {
    let presenter: BeaconPresenter

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right").font(.largeTitle).foregroundStyle(.secondary)
            Text(presenter.current == nil ? "Nothing is waiting." : "An AI tool is asking for your attention.").foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 360, height: 120)
        .sheet(item: Binding(get: { presenter.current }, set: { [shownID = presenter.current?.id] new in
            // Only the sheet that was on screen when this was built may be dismissed by it, never the next one in the queue.
            if new == nil, presenter.current?.id == shownID { presenter.resolve(.userDismissed) }
        })) { item in
            switch item.item {
            case .approval(let request): BeaconApprovalSheet(request: request) { presenter.resolve(.approval($0)) }
            case .confirm(let request): ConfirmSheet(request)
            }
        }
    }
}
