import Foundation
import LocalAuthentication
import Observation
import WheelhouseKit

/// Outcome of a device-owner authentication attempt.
enum AuthResult: Equatable {
    case success
    case failed(String)
    /// The device cannot authenticate at all (no passcode / biometrics set up). Retrying cannot help.
    case unavailable(String)
}

/// Owns the app-lock state (DESIGN.md §11, S26). The lock UI lives in a dedicated overlay window (`LockWindowManager`)
/// so it covers sheets and every scene.
@MainActor @Observable
final class AppLockController {
    private(set) var isLocked: Bool {
        // "Reveal once per session" must not survive a lock.
        didSet { if isLocked { SecretRevealGate.shared.reset() } }
    }
    private(set) var lastError: String?
    /// Set when the device can't authenticate (e.g. the passcode was removed). The lock screen then explains and offers a way out.
    private(set) var unavailableReason: String?
    private var backgroundedAt: Date?

    /// Cold launch with App Lock enabled must start locked so no content is ever shown first.
    init(locked: Bool = false) { isLocked = locked }

    /// `backgroundedAt` is recorded once per background period; timeout 0 locks immediately so the switcher snapshot and return are covered.
    func appDidEnterBackground(preferences: AppPreferences) {
        if backgroundedAt == nil { backgroundedAt = Date() }
        if preferences.appLockEnabled, preferences.lockTimeout == .immediately { isLocked = true }
    }

    /// Locks if the lock is enabled and the grace period elapsed. Must run BEFORE any privacy cover is removed.
    func appDidBecomeActive(preferences: AppPreferences) {
        guard preferences.appLockEnabled else { isLocked = false; backgroundedAt = nil; return }
        if let backgroundedAt, Self.graceElapsed(since: backgroundedAt, timeout: preferences.lockTimeout) { isLocked = true }
        if !isLocked { backgroundedAt = nil }
    }

    nonisolated static func graceElapsed(since: Date, timeout: LockTimeout, now: Date = Date()) -> Bool {
        now.timeIntervalSince(since) >= TimeInterval(timeout.rawValue)
    }

    /// Locks right away (e.g. App Lock was just enabled and the user chooses "Lock Now").
    func lockNow() { isLocked = true }

    func lockIfNeeded(preferences: AppPreferences) { if preferences.appLockEnabled { isLocked = true } }

    /// Turns the lock off after the user acknowledged the warning on the "authentication unavailable" screen.
    func resetLock(preferences: AppPreferences) {
        preferences.appLockEnabled = false
        isLocked = false
        lastError = nil
        unavailableReason = nil
        backgroundedAt = nil
    }

    @discardableResult
    func unlock() async -> Bool {
        switch await Self.authenticateDetailed(reason: "Unlock Wheelhouse") {
        case .success:
            isLocked = false; lastError = nil; unavailableReason = nil; backgroundedAt = nil
            return true
        case .failed(let message):
            lastError = message; return false
        case .unavailable(let message):
            unavailableReason = message; lastError = nil; return false
        }
    }

    /// Fresh `LAContext` per call (secret reveal uses this too). Falls back to the device passcode.
    static func authenticate(reason: String) async -> Bool {
        await authenticateDetailed(reason: reason) == .success
    }

    static func authenticateDetailed(reason: String) async -> AuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(unavailableMessage(for: error))
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed("Authentication failed")
        } catch let e as LAError {
            switch e.code {
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled:
                return .unavailable(unavailableMessage(for: e as NSError))
            case .userCancel, .appCancel, .systemCancel: return .failed("Authentication was cancelled")
            default: return .failed("Authentication failed")
            }
        } catch {
            return .failed("Authentication failed")
        }
    }

    nonisolated static func unavailableMessage(for error: NSError?) -> String {
        if error?.code == LAError.passcodeNotSet.rawValue {
            return "This device has no passcode. Wheelhouse needs a device passcode (or Face ID / Touch ID) to verify it's you."
        }
        return "This device can't verify your identity right now. Set up a passcode in Settings, then try again."
    }
}
