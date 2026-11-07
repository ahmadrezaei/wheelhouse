import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// Mac placeholder with the same SwiftUI-facing API as the iOS `LogsTableView`. M1b replaces the body with the
/// view-based `NSTableView` (fixed-height rows, cell reuse, follow and scroll-away logic, `NSMenu`, in-view find, and the log
/// buffer caps of ARCHITECTURE-MAC §12.3.2). Until then it shows the last 2,000 lines as read-only text.
struct LogsTableView: NSViewRepresentable {
    let lines: [LogLine]
    let settings: LogsDisplaySettings
    let matcher: LogMatcher?
    let follow: Bool
    let scrollTarget: LogsModel.ScrollTarget?
    var onUserScrolledAway: () -> Void
    var onReachedBottom: () -> Void
    var onSelect: (LogLine) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        let shown = lines.suffix(2_000)
        let text = shown.map { $0.text(timestamps: settings.timestamps) }.joined(separator: "\n")
        guard tv.string != text else { return }
        tv.font = .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular)
        tv.string = text
        if follow { tv.scrollToEndOfDocument(nil) }
    }
}
