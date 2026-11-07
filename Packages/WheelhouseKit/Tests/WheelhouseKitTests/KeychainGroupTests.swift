import Testing
import Foundation
import Security
@testable import WheelhouseKit

/// A bundle whose Info.plist holds the given keys (written to a temp directory).
private func bundle(_ info: [String: String]) throws -> Bundle {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wh-bundle-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir.appending(path: "Contents"), withIntermediateDirectories: true)
    var plist = info
    plist["CFBundleIdentifier"] = "test.bundle"
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: dir.appending(path: "Contents/Info.plist"))
    return try #require(Bundle(url: dir))
}

@Suite("KeychainGroup")
struct KeychainGroupTests {
    @Test func sharedDefaultsToTheShippedSuffix() throws {
        #expect(KeychainGroup.shared.suffix(in: try bundle([:])) == "com.ahmadrezaei.wheelhouse.shared")
        #expect(KeychainGroup.shared.accessGroup(teamPrefix: "JCZY58QP3L", bundle: try bundle([:])) == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.shared")
    }

    @Test func macPrivateDefaultsToTheMacBundleSuffix() throws {
        #expect(KeychainGroup.macPrivate.accessGroup(teamPrefix: "JCZY58QP3L", bundle: try bundle([:])) == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mac")
    }

    @Test func debugBuildsResolveBothGroupsToTheDebugGroup() throws {
        let b = try bundle(["WHKeychainGroupSuffix": "com.ahmadrezaei.wheelhouse.mac.debug", "WHKeychainPrivateGroupSuffix": "com.ahmadrezaei.wheelhouse.mac.debug"])
        #expect(KeychainGroup.shared.accessGroup(teamPrefix: "JCZY58QP3L", bundle: b) == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mac.debug")
        #expect(KeychainGroup.macPrivate.accessGroup(teamPrefix: "JCZY58QP3L", bundle: b) == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mac.debug")
    }

    @Test func emptyInfoValuesFallBackToTheDefaults() throws {
        let b = try bundle(["WHKeychainGroupSuffix": "  ", "WHKeychainPrivateGroupSuffix": ""])
        #expect(KeychainGroup.shared.suffix(in: b) == "com.ahmadrezaei.wheelhouse.shared")
        #expect(KeychainGroup.macPrivate.suffix(in: b) == "com.ahmadrezaei.wheelhouse.mac")
    }

    @Test func macPrivateQueriesAreNeverSynchronizableAndDeviceOnly() {
        let q = MacPrivateKeychain.baseQuery(service: MacPrivateService.anthropicKey.rawValue, account: "default", accessGroup: "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mac")
        #expect(q[kSecAttrAccessGroup] as? String == "JCZY58QP3L.com.ahmadrezaei.wheelhouse.mac")
        #expect(q[kSecAttrSynchronizable] as? Bool == false)
        #expect(q[kSecUseDataProtectionKeychain] as? Bool == true)
        let add = MacPrivateKeychain.addAttributes(data: Data([1]))
        #expect((add[kSecAttrAccessible] as! CFString) == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }

    @Test(arguments: MacPrivateService.allCases)
    func everyMacPrivateServiceUsesTheMacPrivateGroupAndNeverTheSharedOne(_ service: MacPrivateService) {
        let group = "TEAM.com.ahmadrezaei.wheelhouse.mac"
        let q = MacPrivateKeychain.baseQuery(service: service.rawValue, account: "a", accessGroup: group)
        #expect((q[kSecAttrAccessGroup] as? String)?.hasSuffix(".shared") == false)
        #expect(q[kSecAttrSynchronizable] as? Bool == false)
        #expect(service.rawValue.hasPrefix("app.wheelhouse.mac."))
        // Never collides with a synchronizable service name.
        #expect(!["app.wheelhouse.sync", "app.wheelhouse.credentials", "app.wheelhouse.prometheus"].contains(service.rawValue))
    }

    @Test func storeWritesOnlyTheDeviceOnlyVariant() throws {
        let mem = InMemoryKeychain()
        let store = MacPrivateSecretStore(.argoToken, backend: mem)
        try store.write("tok", account: "cluster-1")
        let v = mem.variants(service: MacPrivateService.argoToken.rawValue, account: "cluster-1")
        #expect(v.local != nil && v.synced == nil)
        #expect(try store.read(account: "cluster-1") == "tok")
        try store.delete(account: "cluster-1")
        #expect(try store.read(account: "cluster-1") == nil)
    }

    @Test func unsignedProcessResolvesNoGroupRatherThanGuessing() {
        // Under `swift test` the process is unsigned: the team prefix is not discoverable, so nothing is resolved.
        if KeychainAccess.teamPrefix == nil { #expect(KeychainGroup.macPrivate.resolved == nil && KeychainGroup.shared.resolved == nil) }
    }
}

@Suite("Isolation override")
struct IsolationOverrideTests {
    @Test func debugValuesNameOnlyDebugGroups() {
        let v = IsolationValues.debug
        #expect(v.appGroup.hasSuffix(".wheelhouse.debug"))
        #expect(v.sharedKeychainSuffix.hasSuffix(".mac.debug") && v.privateKeychainSuffix.hasSuffix(".mac.debug"))
        #expect(!v.sharedKeychainSuffix.hasSuffix(".shared"))
    }

    @Test func withoutAnOverrideNothingChanges() {
        // iOS (and every Kit test process) never installs one.
        #expect(IsolationOverride.current == nil)
        #expect(AppGroup.identifier == AppGroup.identifier(in: .main))
    }
}
