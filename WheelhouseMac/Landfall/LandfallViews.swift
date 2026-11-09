import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// The Landfall pane (DESIGN-MAC §6.11): provider tabs with CLI status, accounts with checkboxes, the cluster table and Add.
struct LandfallScreen: View {
    var body: some View {
        if let model = LandfallModel.shared {
            if model.isEnabled {
                LandfallContent(model: model)
            } else {
                ContentUnavailableView("Landfall is off in development builds", systemImage: "cloud",
                                       description: Text("Cloud CLIs talk to real accounts, so development builds never run them. Use the shipped app."))
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }
}

private struct LandfallContent: View {
    @Bindable var model: LandfallModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Provider", selection: $model.provider) {
                ForEach(CloudProvider.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            .onChange(of: model.provider) { _, _ in Task { await model.loadStatus() } }

            LandfallStatusBar(model: model)
            if let notice = model.notice { Text(notice).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            HSplitView {
                LandfallAccountList(model: model).frame(minWidth: 200, idealWidth: 240, maxWidth: 320)
                LandfallClusterTable(model: model).frame(minWidth: 420)
            }
        }
        .padding(16)
        .task { await model.loadStatus() }
        .sheet(item: $model.signIn) { request in
            SignInSheet(model: SignInModel(command: request.spec), title: request.title)
                .onDisappear { Task { await model.signInFinished() } }
        }
        .sheet(item: $model.mergeReview) { review in LandfallMergeSheet(model: model, review: review) }
        .confirmationDialog("Add as Production?", isPresented: Binding(get: { model.productionConfirmation != nil }, set: { if !$0 { model.productionConfirmation = nil } }),
                            presenting: model.productionConfirmation) { rows in
            Button("Add \(rows.count == 1 ? "Cluster" : "\(rows.count) Clusters")") { Task { await model.add(rows) } }
            Button("Cancel", role: .cancel) {}
        } message: { rows in
            let reasons = rows.filter { $0.isSuggestedProduction }.flatMap { c in (c.suggestion?.reasons ?? []).map { "\(c.name): \($0)" } }
            Text("Suggested as Production:\n" + reasons.prefix(6).joined(separator: "\n")
                 + "\n\nThey are added read-only. Wheelhouse does not contact them until you press Check.")
        }
    }
}

private struct LandfallStatusBar: View {
    let model: LandfallModel
    var body: some View {
        HStack {
            switch model.statuses[model.provider] {
            case .installed(let version): Label("\(model.provider.tool) \(version)", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .notFound(let hint):
                Label("\(model.provider.tool) was not found. Install it with `\(hint)`.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .signedOut:
                Label("Signed out", systemImage: "person.crop.circle.badge.exclamationmark").foregroundStyle(.orange)
            case .failed(let why): Label(why, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .disabled(let why): Label(why, systemImage: "lock")
            case nil: ProgressView().controlSize(.small)
            }
            Spacer()
            if model.needsSignIn { Button("Sign In…") { Task { await model.requestSignIn() } } }
            Button("Rescan") { Task { await model.scan(force: true) } }.disabled(model.isWorking)
            if model.isWorking { ProgressView().controlSize(.small) }
        }
    }
}

private struct LandfallAccountList: View {
    let model: LandfallModel
    var body: some View {
        List {
            Section(model.provider.accountNoun + "s") {
                ForEach(model.accounts[model.provider] ?? []) { account in
                    let scan = model.scans[account.id]
                    Toggle(isOn: Binding(get: { model.selectedAccountIDs.contains(account.accountID) },
                                         set: { model.toggleAccount(account, on: $0); Task { await model.scan(force: false) } })) {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            Text(scan.map { "Scanned \($0.scannedAt.formatted(.relative(presentation: .named)))" } ?? (account.detail ?? "Not scanned"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !model.issues.isEmpty {
                Section("Problems") {
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}

private struct LandfallClusterTable: View {
    @Bindable var model: LandfallModel

    var body: some View {
        VStack(alignment: .leading) {
            Table(model.clusters, selection: $model.selection) {
                TableColumn("Name") { c in
                    VStack(alignment: .leading) {
                        Text(c.name)
                        if let why = c.unsupportedReason { Text(why).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                TableColumn("Region") { c in Text(c.region).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
                TableColumn("Version") { c in Text(c.version ?? "").foregroundStyle(.secondary) }.width(min: 50, ideal: 70)
                TableColumn("Status") { c in Text(c.status) }.width(min: 60, ideal: 80)
                TableColumn("Endpoint") { c in
                    switch c.access {
                    case .publicEndpoint: Text("Public")
                    case .privateEndpoint: Text("Private").help("Needs a VPN or bastion.")
                    case .unknown: Text("")
                    }
                }.width(min: 50, ideal: 70)
                TableColumn("Tags") { c in
                    Text(c.tags.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                TableColumn("Suggested") { c in
                    if let s = c.suggestion { Text("✦ \(s.label)").help(s.reasons.joined(separator: "\n")) }
                }.width(min: 80, ideal: 100)
                TableColumn("") { c in LandfallRowAction(model: model, cluster: c) }.width(min: 150, ideal: 190)
            }
            HStack {
                Spacer()
                let chosen = model.clusters.filter { model.selection.contains($0.id) }
                Button("Add \(chosen.count) Cluster\(chosen.count == 1 ? "" : "s")") { model.requestAdd(chosen) }
                    .disabled(chosen.isEmpty || model.isWorking)
            }
        }
    }
}

private struct LandfallRowAction: View {
    let model: LandfallModel
    let cluster: CloudCluster

    var body: some View {
        switch model.rowState(cluster) {
        case .alreadyAdded:
            Label("Already added", systemImage: "checkmark").foregroundStyle(.secondary)
        case .added(_, let state):
            HStack {
                switch state {
                case .notChecked: Text("Not checked ·").foregroundStyle(.secondary); Button("Check") { Task { await model.check(cluster) } }.buttonStyle(.link)
                case .checking: ProgressView().controlSize(.small)
                case .result(.reachable(let ms, _)): Text("Reachable \(ms) ms").foregroundStyle(.green)
                case .result(.needsSignIn): Text("Needs sign-in").foregroundStyle(.orange); Button("Sign In…") { Task { await model.requestSignIn() } }.buttonStyle(.link)
                case .result(.pluginMissing(let name)): Text("Plugin missing: \(name)").foregroundStyle(.orange)
                case .result(.unreachable(let why)):
                    Text(cluster.access == .privateEndpoint ? "Unreachable: needs VPN or bastion" : "Unreachable").foregroundStyle(.red).help(why)
                case .result(.blocked(let why)): Text(why).foregroundStyle(.secondary)
                }
            }
        case .available:
            if cluster.addable { Button("Add") { model.requestAdd([cluster]) }.disabled(model.isWorking) } else { Text("Not supported").foregroundStyle(.secondary) }
        }
    }
}

/// The exact YAML to merge into `~/.kube/config` and the backup name, shown before anything is written (ARCHITECTURE-MAC §4.9).
struct LandfallMergeSheet: View {
    let model: LandfallModel
    let review: LandfallModel.MergeReview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Merge into \(review.plan.target.path)?").font(.headline)
            Text("Wheelhouse adds these entries itself. current-context is never changed. The file is checked afterwards and restored from the backup on any difference. Comments and formatting are normalised, as `kubectl config` does.")
                .font(.callout).foregroundStyle(.secondary)
            if let backup = review.plan.backup { Text("Backup: \(backup.lastPathComponent)").font(.system(.callout, design: .monospaced)) }
            ScrollView { Text(review.plan.yaml).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(minHeight: 200).padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Don’t Merge") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Merge") { Task { await model.confirmMerge(review); dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 640)
    }
}
