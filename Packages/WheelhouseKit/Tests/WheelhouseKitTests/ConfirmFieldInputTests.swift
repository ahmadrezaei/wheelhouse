#if os(macOS)
import Testing
import AppKit
import Carbon.HIToolbox
import SwiftUI
@testable import WheelhouseUI
import WheelhouseKit

/// The hardened typed-confirmation field (ARCHITECTURE-MAC §9.2): synthetic key events, paste and accessibility writes must not
/// change the value. (Real hardware events have `eventSourceStateID == hidSystemState`; none can be produced in a test.)
@MainActor
@Suite("ConfirmFieldInputTests")
struct ConfirmFieldInputTests {
    private func syntheticKeyDown(_ character: String = "a") throws -> NSEvent {
        let source = CGEventSource(stateID: .privateState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        var chars = Array(character.utf16)
        cg.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
        return try #require(NSEvent(cgEvent: cg))
    }

    @Test func aPrivateSourceEventIsNotHardware() throws {
        #expect(!ConfirmationFieldHardening.isHardwareKeyEvent(try syntheticKeyDown()))
    }

    @Test func aCombinedSessionEventIsNotHardwareEither() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        #expect(!ConfirmationFieldHardening.isHardware(cg))
    }

    @Test func anEventWithoutACGEventIsNotHardware() throws {
        let e = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                              characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        #expect(!ConfirmationFieldHardening.isHardwareKeyEvent(e))
    }

    @Test func theFieldEditorDropsSyntheticKeys() throws {
        let editor = HardenedFieldEditor()
        editor.string = ""
        editor.keyDown(with: try syntheticKeyDown("x"))
        editor.insertText("y", replacementRange: NSRange(location: NSNotFound, length: 0))   // what a key would end up doing: only via keyDown
        #expect(!editor.string.contains("x"))
    }

    @Test func pasteIsRefusedInEveryForm() {
        let pb = NSPasteboard(name: NSPasteboard.Name("wh.test.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("PASTED", forType: .string)
        let editor = HardenedFieldEditor()
        editor.paste(nil); editor.pasteAsPlainText(nil); editor.pasteAsRichText(nil)
        #expect(editor.string.isEmpty)
        #expect(!editor.readSelection(from: pb))
        #expect(editor.readablePasteboardTypes.isEmpty)
        #expect(editor.acceptableDragTypes.isEmpty)
        #expect(editor.validRequestor(forSendType: .string, returnType: .string) == nil)
        #expect(editor.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) == nil)
    }

    @Test func commandVIsSwallowed() throws {
        let editor = HardenedFieldEditor()
        let source = CGEventSource(stateID: .privateState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true))
        cg.flags = .maskCommand
        let e = try #require(NSEvent(cgEvent: cg))
        #expect(editor.performKeyEquivalent(with: e))
        #expect(editor.string.isEmpty)
    }

    @Test func accessibilityCannotSetTheValue() {
        let field = HardenedConfirmationTextField()
        field.stringValue = "typed"
        field.setAccessibilityValue("forged")
        #expect(field.stringValue == "typed")
        #expect(!field.accessibilityIsAttributeSettable(.value))
        #expect(!field.accessibilityIsAttributeSettable(.selectedText))
        let editor = HardenedFieldEditor()
        editor.string = "typed"
        editor.setAccessibilityValue("forged")
        editor.setAccessibilitySelectedText("forged")
        #expect(editor.string == "typed")
        #expect(!editor.accessibilityIsAttributeSettable(.value))
        #expect(!editor.accessibilityIsAttributeSettable(.selectedTextRange))
    }

    @Test func typingAidsAreOff() {
        let editor = HardenedFieldEditor()
        editor.isAutomaticSpellingCorrectionEnabled = true
        editor.isAutomaticTextCompletionEnabled = true
        editor.isAutomaticQuoteSubstitutionEnabled = true
        #expect(!editor.isAutomaticSpellingCorrectionEnabled && !editor.isAutomaticTextCompletionEnabled && !editor.isAutomaticQuoteSubstitutionEnabled)
        #expect(!editor.isContinuousSpellCheckingEnabled)
    }

    @Test func fieldUsesTheHardenedEditor() {
        let field = HardenedConfirmationTextField()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView?.addSubview(field)
        #expect(field.cell is HardenedFieldCell)
        #expect(field.cell?.fieldEditor(for: field) is HardenedFieldEditor)
    }

    @Test func secureEventInputIsBalanced() {
        // Secure input is system-wide: another app may already hold it, so compare with the state before, not with "off".
        let before = IsSecureEventInputEnabled()
        let token = SecureEventInputToken()
        token.enable(); token.enable()           // idempotent: one Enable call
        #expect(token.isEnabled && IsSecureEventInputEnabled())
        token.disable(); token.disable()
        #expect(!token.isEnabled)
        #expect(IsSecureEventInputEnabled() == before)   // exactly balanced
    }

    @Test func originForcesTypingOnProductionAndKeepsIOSBehaviourWhenNil() {
        let prod = ClusterConfig(name: "p", server: URL(string: "https://p.example.com")!, environment: .production)
        func request(origin: ChangeOrigin?, typeOnProd: Bool) -> ConfirmRequest {
            ConfirmRequest(title: "t", message: "m", verb: "v", cluster: prod, resource: "r", confirmationText: "x",
                           typeToConfirmOnProduction: typeOnProd, origin: origin) {}
        }
        #expect(request(origin: nil, typeOnProd: true).requiresTyping)
        #expect(!request(origin: nil, typeOnProd: false).requiresTyping)                                  // the shell exemption (iOS)
        #expect(request(origin: .firstMate(conversation: "c"), typeOnProd: false).requiresTyping)        // AI can never be exempt
        #expect(request(origin: .beacon(client: "b"), typeOnProd: false).requiresTyping)
        #expect(request(origin: .rigging(pack: "p"), typeOnProd: false).requiresTyping)
        #expect(!request(origin: .terminal(session: "s", reportedCommand: nil), typeOnProd: false).requiresTyping)
    }
}
#endif

#if os(macOS)
@MainActor
@Suite("ConfirmationFieldInputPolicy")
struct ConfirmationFieldInputPolicyTests {
    @Test func syntheticInputIsRefusedByDefaultAndAllowedOnlyThroughThePolicy() throws {
        let source = CGEventSource(stateID: .privateState)
        let cg = try #require(CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true))
        let e = try #require(NSEvent(cgEvent: cg))
        let policy = ConfirmationFieldInputPolicy()
        #expect(!ConfirmationFieldHardening.isHardwareKeyEvent(e, policy: policy))
        policy.allowSyntheticInput()
        #expect(ConfirmationFieldHardening.isHardwareKeyEvent(e, policy: policy))
        #expect(!ConfirmationFieldInputPolicy.shared.allowsSyntheticInput)   // the shared policy is untouched
    }
}
#endif
