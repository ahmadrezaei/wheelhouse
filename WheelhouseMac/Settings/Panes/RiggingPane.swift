import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Settings → Rigging: the packs on this Mac. Lists built-in packs, folders and git packs; each can be switched on or off, shows where it
/// came from (and the pinned commit of a git pack) and what it adds. Adding a pack shows its full declaration first (DESIGN-MAC 6.14).
struct RiggingPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @State private var candidate: RiggingStore.Candidate?
    @State private var showGit = false
    @State private var gitURL = ""
    @State private var gitRef = ""
    @State private var working = false
    @State private var problem: String?
    @State private var detail: String?

    private var store: RiggingStore { env.rigging.store }

    var body: some View {
        Form {
            Section {
                ForEach(store.installed) { item in row(item) }
            } header: {
                Text("Packs")
            } footer: {
                Text("A pack is data only: it adds views, commands and health rules for custom resources. It cannot run code, make network calls or read files. Commands are inserted into a guarded terminal and never run; port forwards always ask you first.")
            }
            Section {
                HStack {
                    Button("Add Pack from Folder…") { chooseFolder() }
                    Button("Add Pack from Git…") { showGit = true }
                    if working { ProgressView().controlSize(.small) }
                }
                if let problem { Text(problem).foregroundStyle(Palette.criticalText).textSelection(.enabled) }
            } footer: {
                Text("Git packs are fetched with your git (https only, no hooks, no submodules) into Wheelhouse's own folder and pinned to one commit. They never update by themselves.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Rigging")
        .sheet(item: $candidate) { c in
            RiggingDeclarationSheet(candidate: c) { approved in
                if approved { store.approve(c) } else { store.discard(c) }
                candidate = nil
            }
        }
        .sheet(isPresented: $showGit) { gitSheet }
        .accessibilityIdentifier("settings-rigging")
    }

    @ViewBuilder private func row(_ item: RiggingStore.Installed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { item.entry.enabled && !item.changedSinceApproval }, set: { store.setEnabled(item.entry.name, $0) })) {
                    VStack(alignment: .leading) {
                        Text(item.entry.name).fontWeight(.medium)
                        Text(item.pack?.metadata.description ?? item.problem ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(item.pack == nil || item.changedSinceApproval)
                Spacer()
                if let pack = item.pack { Text("v\(pack.metadata.version)").font(.caption).foregroundStyle(.secondary) }
                Button(detail == item.id ? "Hide" : "Details") { detail = detail == item.id ? nil : item.id }.buttonStyle(.link)
            }
            Text(item.entry.source.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if item.changedSinceApproval {
                HStack {
                    Label("Its rigging.yaml changed since you approved it, so it is off.", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(Palette.warningText)
                    Button("Review…") { review(item) }
                }
            }
            if detail == item.id, let loaded = item.loaded {
                ForEach(RiggingDeclaration.sections(for: loaded.pack)) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title).font(.caption.weight(.semibold))
                        ForEach(section.lines, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    }.padding(.top, 4)
                }
            }
            if item.entry.source.kind != .builtIn {
                HStack {
                    if item.entry.source.kind == .git { Button("Check for a Newer Commit…") { update(item) }.disabled(working) }
                    Button("Remove", role: .destructive) { store.remove(item.entry.name) }
                }.font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    private func review(_ item: RiggingStore.Installed) {
        guard let loaded = item.loaded else { return }
        candidate = RiggingStore.Candidate(source: item.entry.source, loaded: loaded, replaces: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Pack Folder"
        panel.message = "Choose a folder that contains a rigging.yaml."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { candidate = try store.candidate(folder: url); problem = nil } catch { problem = error.localizedDescription }
    }

    private func update(_ item: RiggingStore.Installed) {
        guard let url = item.entry.source.location else { return }
        fetch(url: url, ref: item.entry.source.ref)
    }

    private func fetch(url: String, ref: String?) {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do { candidate = try await store.candidate(gitURL: url, ref: ref) } catch { problem = error.localizedDescription }
        }
    }

    private var gitSheet: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Add Pack from Git").font(.headline)
            TextField("https://…", text: $gitURL).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            TextField("Branch, tag or commit (optional)", text: $gitRef).textFieldStyle(.roundedBorder).autocorrectionDisabled()
            Text("Only https addresses without a user name or token. Nothing is run; you will see everything the pack adds before it is turned on.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { showGit = false }.keyboardShortcut(.cancelAction)
                Button("Fetch") {
                    showGit = false
                    fetch(url: gitURL, ref: gitRef.isEmpty ? nil : gitRef)
                }.disabled(gitURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

/// The full declaration of a pack, shown before it is turned on. Nothing is stored until the person presses Enable.
struct RiggingDeclarationSheet: View {
    let candidate: RiggingStore.Candidate
    let finish: (Bool) -> Void

    var body: some View {
        let pack = candidate.loaded.pack
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack {
                Image(systemName: "puzzlepiece.extension").font(.title2)
                VStack(alignment: .leading) {
                    Text("\(pack.metadata.name) \(pack.metadata.version)").font(.headline)
                    Text(candidate.source.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let d = pack.metadata.description { Text(d) }
            Text("Read this before turning it on. This is everything the pack adds.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ForEach(candidate.sections) { section in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(section.title).font(.subheadline.weight(.semibold))
                            ForEach(section.lines, id: \.self) { Text($0).font(.callout.monospaced()).textSelection(.enabled) }
                        }
                    }
                    DisclosureGroup("Full rigging.yaml") {
                        Text(candidate.loaded.text).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260)
            HStack {
                Spacer()
                Button("Cancel") { finish(false) }.keyboardShortcut(.cancelAction)
                Button(candidate.replaces ? "Approve and Enable" : "Enable Pack") { finish(true) }
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }
}
