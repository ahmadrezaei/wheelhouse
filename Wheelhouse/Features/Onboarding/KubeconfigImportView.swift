import SwiftUI
import UniformTypeIdentifiers
import WheelhouseKit
import WheelhouseUI

/// Per-context choices made on the import screen.
struct ImportOptions: Equatable {
    var environment: ClusterEnvironment
    var readOnly = false
    var iCloud = false
}

/// S3 / F2 — import contexts from a kubeconfig (Files, paste, or Open-in).
struct KubeconfigImportView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences
    @Environment(\.dismiss) private var dismiss

    @State private var config: Kubeconfig?
    @State private var sourceName: String?
    @State private var parseError: String?
    @State private var selection: Set<String> = []
    @State private var options: [String: ImportOptions] = [:]
    @State private var results: [String: ConnectionTestState] = [:]
    @State private var importing = false
    @State private var saveError: String?
    @State private var copied = false
    @State private var copiedDiagnosticsID: String?
    /// Cluster ids that were actually imported; everything else that was only tested must not keep a key in the Keychain.
    @State private var importedIDs: Set<ClusterID> = []

    var body: some View {
        List {
            sourceSection
            if let parseError { Section { Label(parseError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.criticalText) } }
            if let config {
                summarySection(config)
                contextsSection(config)
                if config.contexts.contains(where: { $0.needsToken }) || config.contexts.contains(where: { !$0.isImportable && $0.status != .local }) { helpSection(config) }
                Section { } footer: { Text("Credentials are copied into the Keychain on this device. The original file is not kept.") }
            }
        }
        .navigationTitle("Import")
        .whInlineNavigationTitle()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if router.sheet != nil { router.dismissSheet() } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(selection.count > 1 ? "Add \(selection.count) Clusters" : "Add Cluster") { Task { await importSelected() } }
                    .disabled(selection.isEmpty || importing)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.yaml, .plainText, .data, .item], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first { load(url: url) }
            else if case .failure(let e) = result { parseError = e.localizedDescription }
        }
        .onAppear { consumeInbox() }
        .onChange(of: KubeconfigInbox.shared.revision) { consumeInbox() }
        .onDisappear { removeUnimportedIdentities() }
        .task(id: config != nil) {
            guard DebugLaunch.autoTest, !didAutoTest, let kc = config else { return }
            didAutoTest = true
            Task { @MainActor in
            selection = Set(kc.contexts.filter { $0.isImportable || $0.status == .local }.map(\.id))
            await testSelected(kc)
            for (k, v) in results { if case .done(let r) = v { NSLog("WHAUTOTEST %@ version=%@ error=%@ latency=%@ caps=%@", k, r.version ?? "nil", String(describing: r.error), String(describing: r.latencyMilliseconds), String(describing: r.capabilities.map { "\($0.title)=\(String(describing: $0.allowed))" })) } }
            }
        }
        .alert("Couldn’t import", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(saveError ?? "") }
    }

    @State private var showImporter = false
    @State private var didAutoTest = false
    /// Stable cluster ids per context so the identity label used by the test matches the one used at import.
    @State private var ids: [String: ClusterID] = [:]

    // MARK: Sections

    private var sourceSection: some View {
        Section {
            Button { showImporter = true } label: { Label("Choose file…", systemImage: "folder") }
            HStack {
                Label("Paste from clipboard", systemImage: "doc.on.clipboard")
                Spacer()
                PasteButton(payloadType: String.self) { items in if let s = items.first { parse(s, name: "Pasted text") } }
                    .labelStyle(.iconOnly).buttonBorderShape(.capsule)
            }
        } header: { Text("Source") } footer: {
            Text("Export a self-contained file with \(Text("kubectl config view --flatten --minify").font(.whCodeSmall)). You can also share a kubeconfig to Wheelhouse from Files.")
        }
    }

    private func summarySection(_ kc: Kubeconfig) -> some View {
        Section {
            HStack(spacing: Spacing.m) {
                Image(systemName: "doc.text").font(.title2).foregroundStyle(Palette.tint)
                VStack(alignment: .leading) {
                    Text(sourceName ?? "kubeconfig").font(.headline)
                    Text("\(kc.contexts.count) context\(kc.contexts.count == 1 ? "" : "s") · \(kc.clusterCount) cluster\(kc.clusterCount == 1 ? "" : "s") · \(kc.userCount) user\(kc.userCount == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func contextsSection(_ kc: Kubeconfig) -> some View {
        Section {
            ForEach(kc.contexts) { ctx in row(ctx, isCurrent: ctx.name == kc.currentContext) }
            if selection.count > 0 {
                Button { Task { await testSelected(kc) } } label: { Label("Test selected connections", systemImage: "bolt.horizontal") }
            }
        } header: { Text("Contexts") }
    }

    private func row(_ ctx: KubeconfigContext, isCurrent: Bool) -> some View {
        let supported = ctx.isImportable || ctx.status == .local
        let selected = selection.contains(ctx.id)
        return VStack(alignment: .leading, spacing: Spacing.s) {
            Button {
                guard supported else { return }
                if selected { selection.remove(ctx.id) } else { selection.insert(ctx.id) }
            } label: {
                HStack(alignment: .top, spacing: Spacing.m) {
                    Image(systemName: !supported ? "minus.circle" : selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? Palette.tint : .secondary).frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(ctx.name).font(.whCode.weight(.medium)).lineLimit(1).truncationMode(.middle)
                            if isCurrent { FlagBadge("CURRENT", tone: .info) }
                        }
                        Text("\(ctx.clusterName) · \(authLabel(ctx.auth))").font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                        if let host = ctx.server?.host() { Text(host).font(.caption).foregroundStyle(.tertiary) }
                        if let reason = ctx.unsupportedReason {
                            Text(reason).font(.footnote).foregroundStyle(ctx.status == .local ? Palette.warningText : Palette.unknownText).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    statusPill(ctx)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!supported)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(supported ? "Double tap to \(selected ? "deselect" : "select")" : "Not supported on iOS")

            if let r = results[ctx.id] { resultLine(r, ctx: ctx) }
            if selected, let binding = Binding($options[ctx.id]) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Environment", selection: binding.environment) { ForEach(ClusterEnvironment.allCases) { Text($0.title).tag($0) } }
                    Toggle("Read-only", isOn: binding.readOnly).frame(minHeight: Spacing.minHit)
                    Toggle("Sync with iCloud Keychain", isOn: binding.iCloud).frame(minHeight: Spacing.minHit)
                }
                .padding(.leading, 40).font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func resultLine(_ r: ConnectionTestState, ctx: KubeconfigContext) -> some View {
        switch r {
        case .idle: EmptyView()
        case .running: HStack { ProgressView().controlSize(.small); Text("Testing…").font(.footnote).foregroundStyle(.secondary) }.padding(.leading, 40)
        case .done(let res):
            Group {
                if let e = res.error {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(e.summary, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.criticalText)
                        Button {
                            Pasteboard.copy(ConnectionTestCard.diagnosticsReport(
                                for: e, target: .init(host: ctx.server?.host() ?? "unknown", port: ctx.server?.port, authKind: authKind(ctx.auth)), trace: res.trace))
                            copiedDiagnosticsID = ctx.id
                        } label: {
                            Label(copiedDiagnosticsID == ctx.id ? "Copied" : "Copy diagnostics", systemImage: copiedDiagnosticsID == ctx.id ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                else { Label("Connected · \(res.version ?? "") · \(res.latencyMilliseconds ?? 0) ms", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.healthyText) }
            }
            .font(.footnote).padding(.leading, 40)
        }
    }

    private func helpSection(_ kc: Kubeconfig) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Label("Why some contexts can’t be imported", systemImage: "info.circle.fill").font(.headline)
                Text("Exec plugins (aws, gcloud, kubelogin) and legacy auth providers run programs on your computer, which iOS apps can’t do. Create a long-lived ServiceAccount token instead, then add the cluster with it:")
                    .font(.subheadline)
                Text(KubeconfigParser.serviceAccountTokenCommands()).font(.whCodeSmall).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: Radius.code))
                HStack {
                    Button { Pasteboard.copy(KubeconfigParser.serviceAccountTokenCommands()); copied = true } label: {
                        Label(copied ? "Copied" : "Copy commands", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                    if let ctx = kc.contexts.first(where: { $0.needsToken || $0.status == .basicAuth }) {
                        NavigationLink { AddClusterView(prefill: ClusterDraft(context: ctx)) } label: { Label("Add with Token", systemImage: "key") }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func statusPill(_ ctx: KubeconfigContext) -> some View {
        switch ctx.status {
        case .ready: StatusPill(tone: .healthy, text: "Ready")
        case .local: StatusPill(tone: .warning, text: "Local")
        case .exec: StatusPill(tone: .unknown, text: "Exec plugin")
        case .authProvider: StatusPill(tone: .unknown, text: "Auth provider")
        case .missingFile: StatusPill(tone: .unknown, text: "Missing file")
        case .basicAuth: StatusPill(tone: .unknown, text: "Basic auth")
        case .invalid: StatusPill(tone: .critical, text: "Invalid")
        }
    }

    /// Auth kind without account names, for the shareable diagnostics report.
    private func authKind(_ auth: KubeconfigAuth) -> String {
        switch auth {
        case .token: "token"
        case .clientCertificate: "clientCertificate"
        case .basic: "basic"
        case .exec: "exec"
        case .authProvider: "authProvider"
        case .missingFiles: "missingFiles"
        case .none: "none"
        }
    }

    private func authLabel(_ auth: KubeconfigAuth) -> String {
        switch auth {
        case .token: "Bearer token"
        case .clientCertificate: "Client certificate"
        case .basic(let u): "Basic auth (\(u))"
        case .exec(let c, _): "exec: \((c as NSString).lastPathComponent)"
        case .authProvider(let n): "auth-provider: \(n)"
        case .missingFiles: "File references"
        case .none: "No credentials"
        }
    }

    // MARK: Logic

    private func consumeInbox() {
        if let pending = KubeconfigInbox.shared.take() { parse(pending.text, name: pending.name) }
    }

    /// Test Connection builds a client-certificate key per tested context; drop those that did not become clusters.
    private func removeUnimportedIdentities() {
        for (_, id) in ids where !importedIDs.contains(id) { ClientIdentityBuilder.remove(label: ClientIdentityBuilder.label(for: id)) }
        ids = ids.filter { importedIDs.contains($0.value) }
    }

    private func load(url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { parseError = "That file isn’t readable text."; return }
        parse(text, name: url.lastPathComponent)
    }

    private func parse(_ text: String, name: String?) {
        parseError = nil; results = [:]
        do {
            let kc = try KubeconfigParser.parse(text)
            config = kc; sourceName = name
            selection = Set(kc.contexts.filter { $0.status == .ready }.map(\.id))
            options = Dictionary(uniqueKeysWithValues: kc.contexts.map { ($0.id, ImportOptions(environment: $0.suggestedEnvironment)) })
        } catch let e as KubeconfigError {
            config = nil
            parseError = switch e {
            case .notYAML: "This isn’t valid YAML."
            case .notAKubeconfig: "This doesn’t look like a kubeconfig (no clusters or contexts)."
            case .empty: "The kubeconfig has no contexts."
            }
        } catch { config = nil; parseError = error.localizedDescription }
    }

    private func build(_ ctx: KubeconfigContext) -> (ClusterConfig, ClusterSecrets)? {
        guard let made = ctx.makeClusterConfig() else { return nil }
        var cfg = made.config
        let secrets = made.secrets
        if let id = ids[ctx.id] { cfg.id = id } else { ids[ctx.id] = cfg.id }
        let o = options[ctx.id] ?? ImportOptions(environment: ctx.suggestedEnvironment)
        cfg.environment = o.environment
        cfg.readOnly = o.readOnly
        cfg.iCloudSync = o.iCloud
        cfg.skipTLSVerify = cfg.skipTLSVerify && o.environment != .production
        cfg.color = o.environment == .production ? .pink : o.environment == .staging ? .indigo : cfg.color
        return (cfg, secrets)
    }

    private func testSelected(_ kc: Kubeconfig) async {
        let targets = kc.contexts.filter { selection.contains($0.id) }
        for c in targets { results[c.id] = .running }
        await withTaskGroup(of: (String, ConnectionTestResult).self) { group in
            for c in targets {
                guard let (cfg, secrets) = build(c) else { continue }
                group.addTask {
                    let client = LiveKubeClient(config: cfg, secrets: secrets, tlsServerName: c.tlsServerName)
                    return (c.id, await ConnectionTester.run(client: client, namespace: cfg.defaultNamespace))
                }
            }
            for await (id, r) in group { results[id] = .done(r) }
        }
    }

    private func importSelected() async {
        guard let kc = config else { return }
        importing = true; defer { importing = false }
        var firstID: ClusterID?
        // Validate everything before adding anything, so a rejected context never leaves a half-imported set behind.
        let chosen = kc.contexts.filter { selection.contains($0.id) }.compactMap { ctx in build(ctx).map { (ctx, $0.0, $0.1) } }
        if let bad = chosen.first(where: { $0.1.violatesHTTPProductionRule }) {
            saveError = "“\(bad.0.name)” uses plain http:// and is marked Production. \(ClusterDraft.Problem.httpNotAllowedForProduction.message)"
            return
        }
        let isFirstRealCluster = registry.isDemoMode || registry.clusters.isEmpty
        do {
            if registry.isDemoMode { preferences.demoMode = false; registry.exitDemoMode() }
            for (_, cfg, secrets) in chosen {
                try registry.add(cfg, secrets: secrets)
                importedIDs.insert(cfg.id)
                firstID = firstID ?? cfg.id
            }
            if let firstID { registry.select(firstID) }
            removeUnimportedIdentities()
            if isFirstRealCluster, firstID != nil { Task { await FirstClusterNotifications.requestIfNeeded(preferences: preferences) } }
            if router.sheet != nil { router.dismissSheet() } else { dismiss() }
        } catch { saveError = error.localizedDescription }
    }
}
