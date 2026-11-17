import Testing
import Foundation
import Security
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Mac App Store edition in its own test host: sandboxed, gate on, its own Debug identity, never the shared keychain group.
@Suite("Mac App Store edition safety")
struct MASSafetyTests {
    @Test func theGateIsActive() {
        #expect(DevSafety.isActive)
    }

    @Test func infoPlistCarriesTheMASDebugIdentity() throws {
        let info = try #require(Bundle.main.infoDictionary)
        #expect(info["WHDevSafety"] as? String == "YES")
        #expect(Bundle.main.bundleIdentifier == "com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(info["WHKeychainGroupSuffix"] as? String == "com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(info["WHKeychainPrivateGroupSuffix"] as? String == "com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(info["WHAppGroup"] as? String == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(info["SUFeedURL"] == nil)
        #expect(info["ITSAppUsesNonExemptEncryption"] as? Bool == false)
    }

    @Test func theMASIsolationValuesAreItsOwn() {
        #expect(IsolationValues.appStoreDebug.appGroup == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(IsolationValues.appStoreDebug.sharedKeychainSuffix == "com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(IsolationValues.appStoreDebug != IsolationValues.debug)
    }

    @Test func theUpdatesPaneIsHidden() {
        #expect(!SettingsPane.visible.contains(.updates))
    }

    @Test func theHostIsSandboxedWithoutTheSharedKeychainGroup() throws {
        let task = try #require(SecTaskCreateFromSelf(nil))
        let sandbox = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, nil)
        #expect(sandbox as? Bool == true)
        let groups = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] ?? []
        #expect(!groups.contains { $0.hasSuffix(".shared") })
    }

    @MainActor @Test func theGateForcesTheMASDebugGroups() {
        _ = MacAppEnvironment.live()
        #expect(IsolationOverride.current == .appStoreDebug)
        #expect(AppGroup.identifier == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mas.debug")
        #expect(KeychainGroup.shared.suffix().hasSuffix(".mas.debug"))
        #expect(KeychainGroup.macPrivate.suffix().hasSuffix(".mas.debug"))
        #expect(!IsolationOverride.install(.debug))
    }
}
