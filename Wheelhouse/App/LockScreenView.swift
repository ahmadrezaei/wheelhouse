import LocalAuthentication
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S26: the lock screen shown in the overlay window. Also handles a device that can no longer authenticate
/// (passcode removed): it explains, offers Open Settings, and offers to reset the lock after a warning.
struct LockScreenView: View {
    @Environment(AppLockController.self) private var lock
    @Environment(AppPreferences.self) private var preferences
    @Environment(ClusterRegistry.self) private var registry
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var biometry = LockBiometry.current
    @State private var attempting = false
    @State private var confirmReset = false

    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()
            Image("wheelhouse.helm")
                .resizable().scaledToFit().padding(18).frame(width: 88, height: 88).foregroundStyle(Palette.seafoam)
                .background(Palette.navy, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .accessibilityHidden(true)
            Text("Wheelhouse is Locked").font(.title2.bold())
            if let reason = lock.unavailableReason {
                unavailable(reason)
            } else {
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let error = lock.lastError {
                    Label(error, systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(Palette.criticalText)
                }
                Spacer()
                VStack(spacing: Spacing.m) {
                    Button { Task { await attempt() } } label: {
                        Label("Unlock with \(biometry.name)", systemImage: biometry.symbol).frame(maxWidth: 300, minHeight: 36)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(attempting)
                    if biometry != .none {
                        Button("Enter Passcode") { Task { await attempt() } }.frame(minHeight: Spacing.minHit)
                    }
                }
                .padding(.bottom, Spacing.xxxl)
            }
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.groupedBackground.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .task(id: scenePhase) { if scenePhase == .active { await attempt() } }
        .alert("Turn Off App Lock?", isPresented: $confirmReset) {
            Button("Turn Off App Lock", role: .destructive) { lock.resetLock(preferences: preferences) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone who can use this device will be able to open Wheelhouse and see your clusters. Your cluster credentials stay in the Keychain. You can turn App Lock back on in Settings once the device has a passcode.")
        }
    }

    @ViewBuilder private func unavailable(_ reason: String) -> some View {
        Text(reason).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        Spacer()
        VStack(spacing: Spacing.m) {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            } label: { Label("Open Settings", systemImage: "gearshape").frame(maxWidth: 300, minHeight: 36) }
                .buttonStyle(.glassProminent)
            Button("Try Again") { Task { await attempt() } }.frame(minHeight: Spacing.minHit)
            Button("Reset App Lock…", role: .destructive) { confirmReset = true }.frame(minHeight: Spacing.minHit)
        }
        .padding(.bottom, Spacing.xxxl)
    }

    private var subtitle: String {
        let n = registry.clusters.count
        return n > 0 ? "Unlock to view \(n) cluster\(n == 1 ? "" : "s") and their credentials." : "Unlock to continue."
    }

    private func attempt() async {
        guard !attempting else { return }
        attempting = true; defer { attempting = false }
        await lock.unlock()
    }
}

/// Biometry available on this device, for labels such as "Unlock with Face ID".
enum LockBiometry {
    case faceID, touchID, opticID, none

    static var current: LockBiometry {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else { return .none }
        return switch ctx.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        case .opticID: .opticID
        default: .none
        }
    }
    var name: String { switch self { case .faceID: "Face ID"; case .touchID: "Touch ID"; case .opticID: "Optic ID"; case .none: "Passcode" } }
    var symbol: String { switch self { case .faceID: "faceid"; case .touchID: "touchid"; case .opticID: "opticid"; case .none: "lock.fill" } }
}
