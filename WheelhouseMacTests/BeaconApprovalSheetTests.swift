import Testing
import AppKit
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// Return must not approve a new client: no button of the approval sheet is the default (Return) button.
@Suite("Beacon approval sheet")
@MainActor
struct BeaconApprovalSheetTests {
    @Test func noButtonIsTheDefaultButton() async throws {
        let request = BeaconApprovalRequest(
            clientName: "Claude Code", launcher: BeaconLauncher(pid: 1, path: "/usr/local/bin/claude"), secretState: .unbound,
            clusters: [ClusterConfig(id: "dev", name: "dev", server: URL(string: "https://dev.example.com")!, environment: .development)])
        var decided: BeaconApprovalDecision?
        let host = NSHostingController(rootView: BeaconApprovalSheet(request: request) { decided = $0 })
        let window = NSWindow(contentViewController: host)
        window.setContentSize(NSSize(width: 520, height: 520))
        window.orderBack(nil)
        try await Task.sleep(for: .milliseconds(1_300))   // past the 1 s input delay
        window.contentView?.layoutSubtreeIfNeeded()
        // SwiftUI draws its own buttons, so the window-level default button (what Return presses) is what can be checked.
        #expect(window.defaultButtonCell == nil)
        // Return pressed in the window approves nothing.
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            _ = window.performKeyEquivalent(with: event)
        }
        #expect(decided == nil)
        window.close()
    }
}
