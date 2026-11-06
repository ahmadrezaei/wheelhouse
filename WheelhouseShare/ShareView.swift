import SwiftUI
import WheelhouseKit
import WheelhouseUI

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Wheelhouse")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if case .saved = model.phase {} else {
                        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.abort() } }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: Spacing.l) {
                header
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.criticalText).multilineTextAlignment(.center)
                Button("Close") { model.abort() }.buttonStyle(.borderedProminent).controlSize(.large)
                Spacer()
            }
            .padding()
        case .ready(let config):
            List {
                Section { header.listRowBackground(Color.clear) }
                Section("Contexts") {
                    ForEach(config.contexts) { ctx in row(ctx, isCurrent: ctx.name == config.currentContext) }
                }
                if let err = model.saveError { Section { Text(err).foregroundStyle(Palette.criticalText) } }
                Section {
                    Button { model.importInWheelhouse() } label: { Text("Import in Wheelhouse").frame(maxWidth: .infinity, minHeight: 32) }
                        .buttonStyle(.borderedProminent)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                } footer: {
                    Text("The kubeconfig is stored encrypted in the Keychain on this device until you open Wheelhouse (expires after 1 hour). Open Wheelhouse to choose which contexts to add.")
                }
            }
        case .saved(let notified):
            VStack(spacing: Spacing.l) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 52)).foregroundStyle(Palette.healthy)
                Text("Saved — open Wheelhouse to finish importing").font(.headline).multilineTextAlignment(.center)
                if notified { Text("Tap the notification, or open the app.").font(.subheadline).foregroundStyle(.secondary) }
                Button("Done") { model.close() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: Spacing.m) {
            Image("AppLogo").resizable().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Wheelhouse").font(.headline)
                Text(model.fileName ?? "kubeconfig").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func row(_ ctx: KubeconfigContext, isCurrent: Bool) -> some View {
        let supported = ctx.isImportable || ctx.status == .local
        return HStack(alignment: .top, spacing: Spacing.m) {
            Image(systemName: supported ? "checkmark.circle" : "minus.circle").foregroundStyle(supported ? Palette.tint : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(ctx.name).font(.whCode.weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if isCurrent { FlagBadge("CURRENT", tone: .info) }
                }
                if let host = ctx.server?.host() { Text(host).font(.caption).foregroundStyle(.tertiary) }
                if let reason = ctx.unsupportedReason { Text(reason).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            pill(ctx)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func pill(_ ctx: KubeconfigContext) -> some View {
        switch ctx.status {
        case .ready: StatusPill(tone: .healthy, text: "Supported")
        case .local: StatusPill(tone: .warning, text: "Local")
        case .exec: StatusPill(tone: .unknown, text: "Exec plugin")
        case .authProvider: StatusPill(tone: .unknown, text: "Auth provider")
        case .missingFile: StatusPill(tone: .unknown, text: "Missing file")
        case .basicAuth: StatusPill(tone: .unknown, text: "Basic auth")
        case .invalid: StatusPill(tone: .critical, text: "Invalid")
        }
    }
}
