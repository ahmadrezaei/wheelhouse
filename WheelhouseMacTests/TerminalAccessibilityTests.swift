import AppKit
import Testing
@testable import WheelhouseMac

@MainActor
@Suite("TerminalAccessibilityTests", .serialized)
struct TerminalAccessibilityTests {
    private func makeView() throws -> (SwiftTermSurface, AccessibleTerminalView) {
        let surface = SwiftTermSurface(scrollback: 5_000)
        surface.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        return (surface, try #require(surface.view as? AccessibleTerminalView))
    }

    @Test func lineArithmeticUsesUTF16() {
        let text = TerminalAccessibilityText(rows: ["a😀b", "日本", ""], liveRowCount: 2, cursorLine: 1, cursorOffset: 1)
        #expect(text.value == "a😀b\n日本\n")
        #expect(text.length == 8)
        #expect(text.lineRanges == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 2), NSRange(location: 8, length: 0)])
        #expect(text.line(for: 0) == 0)
        #expect(text.line(for: 6) == 1)
        #expect(text.line(for: text.length) == 2)
        #expect(text.range(forLine: 0) == NSRange(location: 0, length: 5))
        #expect(text.range(forLine: 2) == NSRange(location: 8, length: 0))
        #expect(text.range(forLine: 9) == NSRange(location: 0, length: 0))
        #expect(text.string(for: NSRange(location: 5, length: 100)) == "日本\n")
        #expect(text.visibleRange == NSRange(location: 5, length: 3))
        #expect(text.insertionPoint == 6)
    }

    @Test func emptyAndFullLiveRanges() {
        let empty = TerminalAccessibilityText(rows: [], liveRowCount: 0, cursorLine: 0)
        #expect(empty.length == 0)
        #expect(empty.line(for: 3) == 0)
        #expect(empty.insertionPoint == 0)
        #expect(empty.lastOutput() == "")
        let all = TerminalAccessibilityText(rows: ["x", "y"], liveRowCount: 2, cursorLine: 1)
        #expect(all.visibleRange == NSRange(location: 0, length: 3))
        let none = TerminalAccessibilityText(rows: ["x", "y"], liveRowCount: 0, cursorLine: 1)
        #expect(none.visibleRange == NSRange(location: 0, length: 3))
    }

    @Test func lastOutputUsesThePromptThenFallsBack() {
        let withPrompt = TerminalAccessibilityText(rows: ["$ ls", "a", "", "b", "$ cat x", "hello", "world", "$ "], liveRowCount: 8, cursorLine: 7, cursorOffset: 2)
        #expect(withPrompt.lastOutput() == "hello\nworld")
        let noOutput = TerminalAccessibilityText(rows: ["$ true", "$ "], liveRowCount: 2, cursorLine: 1, cursorOffset: 2)
        #expect(noOutput.lastOutput() == "")
        let fallback = TerminalAccessibilityText(rows: ["old", "", "one", "two", ""], liveRowCount: 5, cursorLine: 4, cursorOffset: 0)
        #expect(fallback.lastOutput() == "one\ntwo")
        let onlyBlank = TerminalAccessibilityText(rows: ["", ""], liveRowCount: 2, cursorLine: 1)
        #expect(onlyBlank.lastOutput() == "")
    }

    @Test func theViewExposesTheScreenAsATextArea() throws {
        let (surface, view) = try makeView()
        surface.feed("first line\r\nsecond line\r\nprompt> ")
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .textArea)
        let value = try #require(view.accessibilityValue() as? String)
        #expect(value.contains("first line\nsecond line\nprompt>"))
        #expect(view.accessibilityNumberOfCharacters() == (value as NSString).length)
        let line = view.accessibilityInsertionPointLineNumber()
        #expect(view.accessibilityString(for: view.accessibilityRange(forLine: line))?.hasPrefix("prompt>") == true)
        #expect(view.accessibilitySelectedTextRange().length == 0)
        #expect(view.accessibilitySelectedText() == "")
        #expect(view.accessibilityVisibleCharacterRange().length > 0)
        #expect(view.accessibilityLine(for: 0) == 0)
    }

    @Test func wrappedRowsJoinIntoOneLine() throws {
        let (surface, view) = try makeView()
        let cols = surface.size.cols
        surface.feed(String(repeating: "w", count: cols * 2 + 5) + "\r\nnext")
        let lines = view.accessibilityText.rows
        #expect(lines.contains(String(repeating: "w", count: cols * 2 + 5)))
    }

    @Test func speakLastOutputAnnouncesTheOutput() throws {
        let (surface, view) = try makeView()
        var spoken: [String] = []
        view.announce = { spoken.append($0) }
        surface.feed("$ echo hi\r\nhi\r\n$ ")
        let action = try #require(view.accessibilityCustomActions()?.first)
        #expect(action.name == "Speak Last Output")
        #expect(action.handler?() == true)
        #expect(spoken == ["hi"])
    }

    @Test func changesPostOneTrailingNotificationOnlyWithVoiceOver() async throws {
        let (surface, view) = try makeView()
        var posts = 0
        view.postNotification = { _ in posts += 1 }
        view.voiceOverIsRunning = { false }
        surface.feed("quiet")
        try await Task.sleep(for: .milliseconds(400))
        #expect(posts == 0)
        view.voiceOverIsRunning = { true }
        for i in 0..<50 { surface.feed("burst \(i)\r\n") }
        try await Task.sleep(for: .milliseconds(500))
        #expect(posts == 1)
    }

    @Test func rebuildsAreThrottled() throws {
        let (surface, view) = try makeView()
        var clock = Date(timeIntervalSince1970: 1_000)
        view.now = { clock }
        surface.feed("one\r\n")
        let first = view.accessibilityText
        surface.feed("two\r\n")
        #expect(view.accessibilityText == first)
        clock = clock.addingTimeInterval(1)
        #expect(view.accessibilityText.value.contains("two"))
    }

    @Test func resizeAndFontChangesInvalidateTheText() throws {
        let (surface, view) = try makeView()
        view.now = { Date(timeIntervalSince1970: 5_000) }
        surface.feed("x")
        let before = view.accessibilityText
        view.now = { Date(timeIntervalSince1970: 6_000) }
        surface.fontSize = 18
        let after = view.accessibilityText
        #expect(after.value.contains("x"))
        #expect(before.value.contains("x"))
    }
}
