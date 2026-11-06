import Foundation

/// Implements the "Reveal secrets: authenticate each time / once per session" preference.
/// One shared instance; the reveal UI asks it before showing a Secret value.
@MainActor
public final class SecretRevealGate {
    public static let shared = SecretRevealGate()
    private var authenticatedThisSession = false
    public init() {}

    /// - Parameters:
    ///   - oncePerSession: `AppPreferences.revealSecretsOncePerSession`.
    ///   - authenticate: runs the biometric / passcode prompt (`AppLockController.authenticate`).
    public func authorize(oncePerSession: Bool, authenticate: () async -> Bool) async -> Bool {
        if oncePerSession && authenticatedThisSession { return true }
        let ok = await authenticate()
        if ok && oncePerSession { authenticatedThisSession = true }
        return ok
    }

    /// Forget the session authentication (app locked, or the preference was switched back to "each time").
    public func reset() { authenticatedThisSession = false }
}
