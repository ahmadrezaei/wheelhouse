import LocalAuthentication
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Safety & Security: App Lock (Touch ID or the password) with the timeout, the wake and screen-lock triggers, and how secrets are
/// revealed (the iOS "Security" section plus the Mac triggers, DESIGN-MAC section 12). Turning the lock off or weakening it asks for
/// the owner first, as on iOS.
struct SafetySecurityPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppPreferences.self) private var preferences
    @State private var lockError: String?
    private let biometry = BiometryKind.current

    var body: some View {
        @Bindable var preferences = preferences
        @Bindable var mac = env.macPreferences
        Form {
            Section {
                Toggle(isOn: Binding(get: { preferences.appLockEnabled }, set: { setLock($0) })) {
                    Label("App Lock (\(biometry.name))", systemImage: biometry.symbol)
                }
                if preferences.appLockEnabled {
                    Picker("Require unlock", selection: Binding(get: { preferences.lockTimeout }, set: { setTimeout($0) })) {
                        Text("When Wheelhouse is deactivated").tag(LockTimeout.immediately)
                        Text("After 1 minute").tag(LockTimeout.oneMinute)
                        Text("After 5 minutes").tag(LockTimeout.fiveMinutes)
                        Text("After 15 minutes").tag(LockTimeout.fifteenMinutes)
                    }
                    Toggle("Lock when the Mac goes to sleep", isOn: Binding(get: { mac.lockOnSleep }, set: { v in weaken(v) { mac.lockOnSleep = v } }))
                    Toggle("Lock when the screen locks", isOn: Binding(get: { mac.lockOnScreenLock }, set: { v in weaken(v) { mac.lockOnScreenLock = v } }))
                    Button("Lock Now") { env.lock.lockNow() }
                }
            } header: { Text("App Lock") } footer: {
                Text("Wheelhouse asks for Touch ID or your login password. Cluster credentials stay in the Keychain; the lock covers the windows.")
            }
            Section {
                Picker("Reveal secrets", selection: $preferences.revealSecretsOncePerSession) {
                    Text("Authenticate each time").tag(false)
                    Text("Once per session").tag(true)
                }
            } header: { Text("Secrets") } footer: {
                Text("Secret values stay masked until you authenticate. Copied values are cleared from the clipboard after 60 seconds, and when you quit.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Safety & Security")
        .alert("Couldn’t enable App Lock", isPresented: Binding(get: { lockError != nil }, set: { if !$0 { lockError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(lockError ?? "") }
    }

    /// Weakening or changing the lock needs the owner: authenticate first (skipped only when the device has no authentication at all).
    private func authenticateOwner(reason: String) async -> Bool {
        var error: NSError?
        guard LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return await AppLockController.authenticate(reason: reason)
    }

    private func setLock(_ on: Bool) {
        Task {
            if !on {
                if await authenticateOwner(reason: "Turn off App Lock") { preferences.appLockEnabled = false }
                return
            }
            if await AppLockController.authenticate(reason: "Turn on App Lock") { preferences.appLockEnabled = true }
            else { lockError = "Set a login password (and Touch ID if you like) in System Settings, then try again." }
        }
    }

    private func setTimeout(_ timeout: LockTimeout) {
        guard timeout != preferences.lockTimeout else { return }
        Task { if await authenticateOwner(reason: "Change the App Lock delay") { preferences.lockTimeout = timeout } }
    }

    /// Turning a trigger off weakens the lock: authenticate; turning it on does not need it.
    private func weaken(_ newValue: Bool, apply: @escaping @MainActor () -> Void) {
        if newValue { apply(); return }
        Task { if await authenticateOwner(reason: "Make App Lock less strict") { apply() } }
    }
}
