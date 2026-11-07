import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// Mac placeholder with the same `YAMLCodeEditor` and `CodeEditorController` API as iOS. M1b replaces it with the TextKit 2
/// `NSTextView` editor (`NSRulerView` gutter, `YAMLTokenizer` highlighting, `NSTextFinder`).
@MainActor @Observable
final class CodeEditorController {
    @ObservationIgnored fileprivate weak var textView: NSTextView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() { textView?.undoManager?.undo(); refresh() }
    func redo() { textView?.undoManager?.redo(); refresh() }
    func find() {
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        textView?.performTextFinderAction(item)
    }
    func dismissKeyboard() { textView?.window?.makeFirstResponder(nil) }
    func focus() { textView?.window?.makeFirstResponder(textView) }

    func jump(toLine line: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        var index = 0, current = 1
        while current < line, index < ns.length {
            index = NSMaxRange(ns.lineRange(for: NSRange(location: index, length: 0)))
            current += 1
        }
        tv.setSelectedRange(NSRange(location: min(index, ns.length), length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
    }

    fileprivate func refresh() {
        let u = textView?.undoManager?.canUndo ?? false
        let r = textView?.undoManager?.canRedo ?? false
        if u != canUndo { canUndo = u }
        if r != canRedo { canRedo = r }
    }
}

struct YAMLCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wraps: Bool
    var diagnostics: [YAMLDiagnostic] = []
    var controller: CodeEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.string = text
        tv.isEditable = isEditable
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        controller.textView = tv
        if tv.string != text { tv.string = text }
        tv.isEditable = isEditable
        tv.textContainer?.widthTracksTextView = wraps
        tv.isHorizontallyResizable = !wraps
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLCodeEditor
        init(_ parent: YAMLCodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            parent.controller.refresh()
        }
    }
}
