#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Hardened typed-confirmation input for the Mac (ARCHITECTURE-MAC §9.2):
///  - accepts a key event only if it comes from the HID system (`eventSourceStateID == hidSystemState`, source pid 0), so
///    events posted by other processes, AppleScript or accessibility clients are dropped;
///  - the accessibility value is readable (VoiceOver) but not settable;
///  - paste is refused everywhere (⌘V, the Edit menu, the context menu, drag and drop, Services);
///  - autocorrect, autofill and text completion are off;
///  - secure event input is on while the field is first responder, always balanced.
/// Whether synthetic key events are accepted. Always false, except that a development-only test hook in the app target may call
/// `allowSyntheticInput()` once (UI tests must type). Release and Distribution builds contain no caller (checked by
/// `scripts/mac-entitlement-check.sh`, which fails on any `WHTestHook` symbol outside Debug).
public final class ConfirmationFieldInputPolicy: @unchecked Sendable {
    public static let shared = ConfirmationFieldInputPolicy()
    private let lock = NSLock()
    private var synthetic = false
    public init() {}
    public var allowsSyntheticInput: Bool { lock.withLock { synthetic } }
    public func allowSyntheticInput() { lock.withLock { synthetic = true } }
}

enum ConfirmationFieldHardening {
    /// True only for an event that came from the HID system with no source process (or when the policy allows synthetic input).
    static func isHardwareKeyEvent(_ event: NSEvent, policy: ConfirmationFieldInputPolicy = .shared) -> Bool {
        if policy.allowsSyntheticInput { return true }
        guard let cg = event.cgEvent else { return false }
        return isHardware(cg)
    }

    static func isHardware(_ cg: CGEvent) -> Bool {
        cg.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
            && cg.getIntegerValueField(.eventSourceUnixProcessID) == 0
    }
}

/// Keeps `EnableSecureEventInput` and `DisableSecureEventInput` balanced for one owner.
final class SecureEventInputToken {
    private(set) var isEnabled = false
    func enable() { guard !isEnabled else { return }; EnableSecureEventInput(); isEnabled = true }
    func disable() { guard isEnabled else { return }; DisableSecureEventInput(); isEnabled = false }
    deinit { disable() }
}

/// The field editor `NSTextField` uses while editing. All input hardening lives here, because this is the view that receives keys.
final class HardenedFieldEditor: NSTextView {
    let secureInput = SecureEventInputToken()

    override func keyDown(with event: NSEvent) {
        guard ConfirmationFieldHardening.isHardwareKeyEvent(event) else { return }   // synthetic: dropped
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ConfirmationFieldHardening.isHardwareKeyEvent(event) else { return true }   // swallow synthetic equivalents
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "v" { return true }   // ⌘V
        return super.performKeyEquivalent(with: event)
    }

    // Paste in every form.
    override func paste(_ sender: Any?) {}
    override func pasteAsPlainText(_ sender: Any?) {}
    override func pasteAsRichText(_ sender: Any?) {}
    override func pasteFont(_ sender: Any?) {}
    override func pasteRuler(_ sender: Any?) {}
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [] }
    override func readSelection(from pboard: NSPasteboard) -> Bool { false }
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool { false }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool { false }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { [] }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }   // Services
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(NSText.paste(_:)) || item.action == #selector(NSTextView.pasteAsPlainText(_:)) || item.action == #selector(NSTextView.pasteAsRichText(_:)) { return false }
        return super.validateUserInterfaceItem(item)
    }

    // Typing aids off.
    override var isAutomaticSpellingCorrectionEnabled: Bool { get { false } set {} }
    override var isAutomaticQuoteSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticDashSubstitutionEnabled: Bool { get { false } set {} }
    override var isAutomaticTextReplacementEnabled: Bool { get { false } set {} }
    override var isAutomaticTextCompletionEnabled: Bool { get { false } set {} }
    override var isContinuousSpellCheckingEnabled: Bool { get { false } set {} }
    override var isGrammarCheckingEnabled: Bool { get { false } set {} }

    // Readable, not settable, through accessibility.
    override func setAccessibilityValue(_ accessibilityValue: Any?) {}
    override func setAccessibilitySelectedText(_ accessibilitySelectedText: String?) {}
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool { false }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { secureInput.enable() }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { secureInput.disable() }
        return ok
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { secureInput.disable() }   // sheet closed while editing
    }
}

final class HardenedFieldCell: NSTextFieldCell {
    private var editor: HardenedFieldEditor?
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        if editor == nil {
            let e = HardenedFieldEditor()
            e.isFieldEditor = true
            editor = e
        }
        return editor
    }
}

/// The confirmation `NSTextField`: never lets code set its value through accessibility.
final class HardenedConfirmationTextField: NSTextField {
    override class var cellClass: AnyClass? { get { HardenedFieldCell.self } set {} }

    override func setAccessibilityValue(_ accessibilityValue: Any?) {}
    override func accessibilityIsAttributeSettable(_ attribute: NSAccessibility.Attribute) -> Bool { false }
}

struct HardenedConfirmationFieldRepresentable: NSViewRepresentable {
    let prompt: String
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> HardenedConfirmationTextField {
        let field = HardenedConfirmationTextField()
        field.placeholderString = prompt
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.isEditable = true
        field.isAutomaticTextCompletionEnabled = false
        field.delegate = context.coordinator
        field.setAccessibilityLabel(prompt)
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }

    func updateNSView(_ field: HardenedConfirmationTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = prompt
        field.setAccessibilityLabel(prompt)
        // The binding only changes through typing; a reset to empty (new sheet) is the one programmatic write that is mirrored.
        if text.isEmpty, !field.stringValue.isEmpty { field.stringValue = "" }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: HardenedConfirmationFieldRepresentable
        init(_ parent: HardenedConfirmationFieldRepresentable) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}
#endif
