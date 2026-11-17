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
            if controller.isSandboxed { FolderAccessSection(controller: controller) }
            Section("Sources") {
                ForEach(controller.contexts.map(\.fileName).uniqued(), id: \.self) { Text($0).font(.system(.body, design: .monospaced)) }
                ForEach(controller.issues.sorted(by: { $0.key < $1.key }), id: \.key) { path, why in
                    HStack {
                        VStack(alignment: .leading) { Text((path as NSString).lastPathComponent); Text(why).font(.caption).foregroundStyle(.secondary) }
                        if let folder = controller.accessNeeded[path] {
                            Spacer()
                            Button("Grant Folder…") { Task { await controller.chooseAccessFolder(for: folder) } }
                        }
                    }
                }
            }
            Section {
                if !controller.isSandboxed { Button("Reload Shell Environment") { Task { await controller.reloadShellEnvironment() } } }
            } footer: {
                Text("Wheelhouse reads these files where they are and never changes them.")
            }
        }
    }

    /// The App Store edition reads only folders the person granted.
    private struct FolderAccessSection: View {
        let controller: MooringsController
        var body: some View {
            Section {
                ForEach(controller.grantedFolders) { grant in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(FolderGrantPolicy.tildePath(grant.source.path ?? "", home: controller.accountHome)).font(.system(.body, design: .monospaced))
                            if let problem = grant.problem {
                                Text(problem == .folderGone ? "This folder was moved or deleted. Grant it again." : "macOS didn’t allow access. Grant it again.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if grant.problem != nil {
                            Button("Grant Folder…") {
                                Task {
                                    switch grant.source.kind {
                                    case .kubeFolder: await controller.chooseKubeFolder()
                                    case .accessGrant: await controller.chooseAccessFolder(for: grant.source.path ?? "")
                                    default: await controller.chooseExtraFolder()
                                    }
                                }
                            }
                        }
                        Button("Remove") { Task { await controller.removeGrant(grant.source) } }
                    }
                }
                if let error = controller.grantError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                HStack {
                    Button("Grant .kube Folder…") { Task { await controller.chooseKubeFolder() } }.disabled(controller.gateActive)
                        .help(controller.gateActive ? "Development builds never open ~/.kube." : "Choose your .kube folder.")
                    Button("Add Folder…") { Task { await controller.chooseExtraFolder() } }
                }
            } header: {
                Text("Folder access")
            } footer: {
                Text("The App Store edition can only read folders you grant. Grant folders, not single files: tools replace kubeconfig files when they save.")
            }
        }
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
