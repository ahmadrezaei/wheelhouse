import Testing
import Foundation
@testable import WheelhouseKit

private func line(_ id: Int, _ text: String) -> LogLine { LogLine(id: id, message: text) }

/// ARCHITECTURE-MAC section 12.3.2: per-stream line and byte caps, line truncation, the 64 MB total and memory-pressure trimming.
@Suite("Log buffer caps")
@MainActor
struct LogBufferCapTests {
    @Test func unlimitedBufferBehavesAsBefore() {
        var buffer = LogRingBuffer(capacity: 5)
        let dropped = buffer.append(contentsOf: (0..<8).map { line($0, "x") })
        #expect(dropped == 3)
        #expect(buffer.count == 5)
        #expect(buffer[0].id == 3)
        #expect(buffer.byteCount == 0)            // bytes are tracked only when a limit is set
    }

    @Test func capacityIsClampedToTheHardMaximum() {
        let buffer = LogRingBuffer(capacity: 500_000, limits: .desktop)
        #expect(buffer.capacity == 50_000)
        #expect(LogLimits.desktop.maxBufferBytes == 16 * 1024 * 1024)
        #expect(LogLimits.desktop.maxLineBytes == 16 * 1024)
        #expect(LogLimits.desktop.maxTotalBytes == 64 * 1024 * 1024)
    }

    @Test func byteCapDropsTheOldestLines() {
        let limits = LogLimits(maxLines: 1_000, maxLineBytes: .max, maxBufferBytes: 1_000, maxTotalBytes: 0)
        var buffer = LogRingBuffer(capacity: 1_000, limits: limits)
        let text = String(repeating: "a", count: 100)
        for i in 0..<30 { buffer.append(contentsOf: [line(i, text)]) }
        #expect(buffer.byteCount <= 1_000)
        #expect(buffer.count == 10)
        #expect(buffer[buffer.count - 1].id == 29)
        #expect(buffer.droppedCount == 20)
    }

    @Test func aSingleHugeLineIsKept() {
        let limits = LogLimits(maxLines: 10, maxLineBytes: .max, maxBufferBytes: 100, maxTotalBytes: 0)
        var buffer = LogRingBuffer(capacity: 10, limits: limits)
        buffer.append(contentsOf: [line(0, String(repeating: "z", count: 500))])
        #expect(buffer.count == 1)                // the newest line is never dropped
    }

    @Test func linesOver16KBAreTruncatedWithASuffix() {
        let big = String(repeating: "é", count: 20_000)             // 40,000 bytes
        let cut = LogLimits.desktop.truncated(line(1, big))
        #expect(cut.message.utf8.count < 16 * 1024 + 64)
        #expect(cut.message.hasSuffix("bytes truncated"))
        #expect(cut.message.hasPrefix("éé"))
        let short = line(2, "hello")
        #expect(LogLimits.desktop.truncated(short) == short)
        #expect(LogLimits.unlimited.truncated(line(3, big)).message == big)
    }

    @Test func truncationNeverSplitsACharacter() {
        let limits = LogLimits(maxLines: 10, maxLineBytes: 5, maxBufferBytes: .max, maxTotalBytes: 0)
        let cut = limits.truncated(line(1, "ab😀cd"))               // the emoji spans bytes 2..<6
        #expect(cut.message.hasPrefix("ab"))
        #expect(!cut.message.contains("\u{FFFD}"))
    }

    @Test func trimKeepsTheLastLines() {
        var buffer = LogRingBuffer(capacity: 100, limits: .desktop)
        buffer.append(contentsOf: (0..<50).map { line($0, "abc") })
        let dropped = buffer.trim(keepingLast: 10)
        #expect(dropped == 40)
        #expect(buffer.count == 10)
        #expect(buffer[0].id == 40)
        #expect(buffer.byteCount == 30)
    }

    @Test func streamTrimWithNothingToDropDoesNotRepublish() {
        let stream = LogStream(capacity: 100, limits: .desktop)
        let before = stream.revision
        #expect(stream.trim(keepingLast: 10) == 0)
        #expect(stream.revision == before)
    }

    @Test func totalBudgetDropsNonVisibleStreamsFirst() async {
        let budget = LogMemoryBudget.shared
        let saved = budget.maxTotalBytes
        budget.maxTotalBytes = 4_000
        defer { budget.maxTotalBytes = saved }
        let limits = LogLimits(maxLines: 1_000, maxLineBytes: 1_000, maxBufferBytes: 1_000_000, maxTotalBytes: 4_000)
        let hidden = LogStream(capacity: 1_000, limits: limits)
        let visible = LogStream(capacity: 1_000, limits: limits)
        hidden.isVisible = false
        let text = String(repeating: "q", count: 100)
        for i in 0..<30 { hidden.appendMarker(text + String(i)) }
        for i in 0..<30 { visible.appendMarker(text + String(i)) }
        try? await Task.sleep(for: .milliseconds(600))   // flush interval
        #expect(visible.count == 30)                      // the visible stream is untouched while a hidden one can give
        #expect(hidden.count < 30)
        #expect(budget.totalBytes <= 4_000 + 300)
    }
}
