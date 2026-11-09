import SwiftUI
import WheelhouseDesktop

/// Settings → Moorings: sources, the shell-environment banner and Reload Shell Environment.
struct MooringsPane: View {
    var body: some View {
        Form {
            if let c = MooringsController.shared { Content(controller: c) } else { Text("Moorings isn’t running.").foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle("Moorings")
    }

    private struct Content: View {
        let controller: MooringsController
        var body: some View {
            if let banner = controller.shellBanner { Section { Label(banner, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
            if !controller.serverNotices.isEmpty {
                Section("Changed servers") {
                    ForEach(controller.serverNotices.sorted(by: { $0.key < $1.key }), id: \.key) { _, text in Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
            }
            Section("Sources") {
                ForEach(controller.contexts.map(\.fileName).uniqued(), id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                ForEach(controller.issues.sorted(by: { $0.key < $1.key }), id: \.key) { path, why in
                    VStack(alignment: .leading) { Text((path as NSString).lastPathComponent); Text(why).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section {
                Button("Reload Shell Environment") { Task { await controller.reloadShellEnvironment() } }
            } footer: {
                Text("Wheelhouse reads these files where they are and never changes them.")
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
