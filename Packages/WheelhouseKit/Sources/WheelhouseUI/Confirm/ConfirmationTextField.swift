import SwiftUI

/// The text field of the typed confirmation (ARCHITECTURE-MAC §9.2).
///
/// iOS: exactly the `TextField` the sheet always used (monospaced, no autocapitalisation, no autocorrection).
/// macOS: a hardened `NSTextField` (see `ConfirmationTextField+macOS.swift`) that accepts only hardware keyboard input.
public struct ConfirmationTextField: View {
    private let prompt: String
    @Binding private var text: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    public var body: some View {
        #if os(macOS)
        HardenedConfirmationFieldRepresentable(prompt: prompt, text: $text)
            .frame(minHeight: 22)
        #else
        TextField(prompt, text: $text)
            .font(.whCode).whNoAutocapitalization().autocorrectionDisabled()
        #endif
    }
}
