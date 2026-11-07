import SwiftUI
import WheelhouseKit

/// Editor: the YAML editor's font size (the schema settings arrive with M7).
struct EditorPane: View {
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        @Bindable var mac = env.macPreferences
        Form {
            Section("YAML editor") {
                LabeledContent("Font size") {
                    HStack {
                        Slider(value: $mac.editorFontSize, in: 9...24, step: 1).frame(width: 180)
                        Text("\(Int(mac.editorFontSize)) pt").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
                Text("name: example\nreplicas: 3").font(.system(size: mac.editorFontSize, design: .monospaced)).foregroundStyle(.secondary)
            }
            Section {
                Text("Takes effect in editors you open from now on.").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Editor")
    }
}
