import SwiftUI
import WheelhouseKit

/// Terminal: the pod shell's font size and scrollback (the Deck Terminal settings arrive with M5b).
struct TerminalPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppPreferences.self) private var preferences

    private let options = [1_000, 5_000, 10_000, 20_000]

    var body: some View {
        @Bindable var preferences = preferences
        @Bindable var mac = env.macPreferences
        Form {
            Section("Pod shell") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $preferences.terminalFontSize, in: 9...24, step: 1).frame(width: 180)
                        Text("\(Int(preferences.terminalFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Picker("Scrollback", selection: $mac.terminalScrollbackLines) {
                    ForEach(options, id: \.self) { n in Text("\(n.formatted()) lines\(n == 5_000 ? " (default)" : "")").tag(n) }
                }
            }
            Section {
                Text("Applies to shells you open from now on. About 12 MB of memory per full 5,000-line terminal at 120 columns; the scrollback is never trimmed under memory pressure because it is your data.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Terminal")
    }
}
