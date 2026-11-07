import Foundation
import Synchronization

/// Identifiers a development-safe Mac build forces, whatever its Info.plist says (ARCHITECTURE-MAC section 13.2).
///
/// A local Release build has the production bundle ID, app group and keychain groups in its Info.plist but runs with the safety gate
/// ON. The Mac app installs these overrides at launch, before any store exists, so such a build can never open the production app
/// group or name the shared iCloud keychain group (and, because the Debug groups are not in its entitlements, the keychain refuses
/// the access: it fails closed). iOS never installs an override, so its behaviour is unchanged.
public struct IsolationValues: Sendable, Equatable {
    public var appGroup: String
    public var sharedKeychainSuffix: String
    public var privateKeychainSuffix: String

    public init(appGroup: String, sharedKeychainSuffix: String, privateKeychainSuffix: String) {
        self.appGroup = appGroup
        self.sharedKeychainSuffix = sharedKeychainSuffix
        self.privateKeychainSuffix = privateKeychainSuffix
    }

    /// The Debug and Profile identities.
    public static let debug = IsolationValues(appGroup: "JCZY58QP3L.com.ahmadrezaei.wheelhouse.debug",
                                              sharedKeychainSuffix: "com.ahmadrezaei.wheelhouse.mac.debug",
                                              privateKeychainSuffix: "com.ahmadrezaei.wheelhouse.mac.debug")
}

public enum IsolationOverride {
    private static let state = Mutex<IsolationValues?>(nil)

    /// The installed override, or nil (always nil on iOS).
    public static var current: IsolationValues? { state.withLock { $0 } }

    /// Installs the override. Only the first call takes effect (returns true). Call it before the first use of `AppGroup` or
    /// any keychain store.
    @discardableResult
    public static func install(_ values: IsolationValues) -> Bool {
        state.withLock { current in
            guard current == nil else { return false }
            current = values
            return true
        }
    }
}
