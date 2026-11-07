import Testing
@testable import SwiftTerm

/// Minimal proof that the plugin-free vendored copy builds and that the headless core runs.
@Suite struct VendoredSwiftTermTests {
    @Test func headlessTerminalProcessesInput() {
        let terminal = HeadlessTerminal(queue: .main) { _ in }
        terminal.terminal.feed(text: "hello")
        #expect(terminal.terminal.getLine(row: 0)?.translateToString(trimRight: true) == "hello")
    }
}
