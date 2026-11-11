import AppKit
import Observation
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// A request for a decision, waiting for its sheet.
@MainActor
final class GangwaySheetTicket {
    let id = UUID()
    let request: ConfirmRequest
    private var continuation: CheckedContinuation<Bool, Never>?

    init(request: ConfirmRequest, continuation: CheckedContinuation<Bool, Never>) {
        self.request = request
        self.continuation = continuation
    }

    var isResolved: Bool { continuation == nil }

    func resolve(_ answer: Bool) {
        continuation?.resume(returning: answer)
        continuation = nil
    }
}

/// What a window's sheet host shows.
@MainActor @Observable
final class GangwaySheetSlot {
    var current: GangwaySheetTicket?
}

/// Shows Gangway's confirmation sheets (ARCHITECTURE-MAC section 3.6, step 5), on the window that holds the terminal the request came from.
///
/// Each window gets one invisible hosting view that presents a SwiftUI sheet, so the existing `ConfirmSheet` (typed confirmation on
/// Production, the 1 s input delay for terminal origins, the live-configuration re-check) is used unchanged. Sheets of one window queue; a
/// window that cannot be seen declines (nothing is ever approved without a person looking at it). The app lock dismisses every sheet, and a
/// cancelled confirmation (the hold timed out) closes its sheet.
@MainActor
final class GangwaySheetCoordinator {
    private final class WeakWindow { weak var window: NSWindow?; init(_ window: NSWindow?) { self.window = window } }
    @MainActor private struct WindowState {
        let slot = GangwaySheetSlot()
        var queue: [GangwaySheetTicket] = []
        weak var host: NSView?
    }

    private let registry: ClusterRegistry
    private let activity: any ActivityLogging
    private var panes: [String: WeakWindow] = [:]
    private var names: [String: String] = [:]
    private var states: [ObjectIdentifier: WindowState] = [:]

    init(registry: ClusterRegistry, activity: any ActivityLogging) {
        self.registry = registry
        self.activity = activity
    }

    /// The pane's terminal is in `window` (called when its view moves to a window).
    func register(pane: String, name: String, window: NSWindow?) {
        panes[pane] = WeakWindow(window)
        names[pane] = name
    }

    func unregister(pane: String) {
        panes[pane] = nil
        names[pane] = nil
    }

    /// The confirmer Gangway uses.
    nonisolated var confirmer: any GangwayConfirming { Presenter(coordinator: self) }

    struct Presenter: GangwayConfirming {
        let coordinator: GangwaySheetCoordinator
        func confirm(_ sheet: GangwaySheet) async -> Bool { await coordinator.present(sheet) }
    }

    func present(_ sheet: GangwaySheet) async -> Bool {
        guard let first = sheet.holds.first, case .terminal(let pane) = first.origin, let window = panes[pane]?.window, window.isVisible, !window.isMiniaturized,
              let cluster = registry.config(for: first.clusterID) else {
            record(sheet, "declined: the terminal's window is not visible")
            return false
        }
        if Task.isCancelled { return false }
        let key = ObjectIdentifier(window)
        let ticketBox = TicketBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let request = GangwaySheetBuilder.request(for: sheet, cluster: cluster, paneName: names[pane] ?? "Terminal") { [weak ticketBox] in ticketBox?.ticket?.resolve(true) }
                let ticket = GangwaySheetTicket(request: request, continuation: continuation)
                ticketBox.ticket = ticket
                enqueue(ticket, in: window, key: key)
            }
        } onCancel: {
            Task { @MainActor in ticketBox.ticket.map { self.cancel($0) } }
        }
    }

    @MainActor private final class TicketBox { var ticket: GangwaySheetTicket? }

    private func enqueue(_ ticket: GangwaySheetTicket, in window: NSWindow, key: ObjectIdentifier) {
        var state = states[key] ?? WindowState()
        if state.host == nil || state.host?.window !== window { state.host = installHost(in: window, slot: state.slot) }
        states[key] = state
        if state.slot.current == nil { state.slot.current = ticket } else { states[key]?.queue.append(ticket) }
    }

    /// A sheet went away (answered, cancelled or dismissed): its ticket answers "no" if nothing else did, and the next one shows.
    func sheetClosed(_ ticket: GangwaySheetTicket) {
        ticket.resolve(false)
        for key in states.keys {
            if states[key]?.slot.current === ticket { states[key]?.slot.current = nil }
            guard states[key]?.slot.current == nil, states[key]?.queue.isEmpty == false else { continue }
            // The next sheet waits one turn: SwiftUI must finish dismissing this one first.
            Task { @MainActor [weak self] in
                guard let self, var state = self.states[key], state.slot.current == nil, !state.queue.isEmpty else { return }
                let next = state.queue.removeFirst()
                self.states[key] = state
                state.slot.current = next
            }
        }
    }

    private func cancel(_ ticket: GangwaySheetTicket) {
        guard !ticket.isResolved else { return }
        ticket.resolve(false)
        for key in states.keys {
            states[key]?.queue.removeAll { $0 === ticket }
            if states[key]?.slot.current === ticket { states[key]?.slot.current = nil }
        }
    }

    /// The app locked: every sheet closes and every waiting request is declined.
    func dismissAll() {
        for key in states.keys {
            let tickets = (states[key]?.queue ?? []) + [states[key]?.slot.current].compactMap { $0 }
            states[key]?.queue = []
            states[key]?.slot.current = nil
            tickets.forEach { $0.resolve(false) }
        }
    }

    /// Follows the app lock without polling: re-arms an observation of `isLocked` after each change.
    func follow(lock: MacLockCoordinator) {
        if lock.isLocked { dismissAll() }
        withObservationTracking { _ = lock.isLocked } onChange: { [weak self, weak lock] in
            Task { @MainActor in
                guard let self, let lock else { return }
                self.follow(lock: lock)
            }
        }
    }

    var pendingCount: Int { states.values.reduce(0) { $0 + $1.queue.count + ($1.slot.current == nil ? 0 : 1) } }

    private func installHost(in window: NSWindow, slot: GangwaySheetSlot) -> NSView? {
        guard let content = window.contentView else { return nil }
        let host = PassthroughHostingView(rootView: GangwaySheetHost(slot: slot, coordinator: self, registry: registry, activity: activity))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        host.setAccessibilityElement(false)
        content.addSubview(host)
        return host
    }

    private func record(_ sheet: GangwaySheet, _ result: String) {
        guard let first = sheet.holds.first else { return }
        activity.record(ActivityEntry(cluster: first.clusterID, origin: first.origin.changeOrigin, verb: "confirmation", object: GangwaySheetBuilder.describe(first), result: result,
                                      commandLine: first.reportedCommand))
    }
}

/// A hosting view that never takes a click.
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The invisible view that presents the sheet.
private struct GangwaySheetHost: View {
    @Bindable var slot: GangwaySheetSlot
    let coordinator: GangwaySheetCoordinator
    let registry: ClusterRegistry
    let activity: any ActivityLogging

    var body: some View {
        Color.clear
            .sheet(item: $slot.current) { ticket in
                ConfirmSheet(ticket.request)
                    .environment(registry)
                    .environment(\.activityLog, activity)
                    .tint(Palette.tint)
                    .frame(minWidth: 520, minHeight: 480)
                    .onDisappear { coordinator.sheetClosed(ticket) }
            }
    }
}

extension GangwaySheetTicket: Identifiable {}
