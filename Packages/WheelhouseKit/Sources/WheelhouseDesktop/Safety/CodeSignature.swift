#if os(macOS)
import Foundation
import Security

/// What is known about the signature of the running app. Only "valid Developer ID Application for team X" (GitHub edition) and "valid
/// Mac App Store signature for team X" (App Store edition) matter to the safety gate; everything else (Apple Development, ad hoc,
/// unsigned, any error) is neither.
public struct CodeSignature: Sendable, Equatable {
    /// Teams for which the running code satisfied the Developer ID Application requirement.
    public var developerIDTeams: Set<String>

    /// Teams for which the running code satisfied the Mac App Store requirement (and carries that team identifier).
    public var macAppStoreTeams: Set<String>

    public init(developerIDTeams: Set<String> = [], macAppStoreTeams: Set<String> = []) {
        self.developerIDTeams = developerIDTeams
        self.macAppStoreTeams = macAppStoreTeams
    }

    public func isValidMacAppStore(team: String) -> Bool { macAppStoreTeams.contains(team) }

    public func isValidDeveloperID(team: String) -> Bool { developerIDTeams.contains(team) }

    // Fixtures for tests.
    public static let unsigned = CodeSignature()
    public static let adHoc = CodeSignature()
    public static let appleDevelopment = CodeSignature()
    public static func developerID(team: String) -> CodeSignature { CodeSignature(developerIDTeams: [team]) }
    public static func macAppStore(team: String) -> CodeSignature { CodeSignature(macAppStoreTeams: [team]) }

    /// The Mac App Store requirement: Apple-anchored with the Mac App Store leaf marker (OID 1.2.840.113635.100.6.1.9), for the
    /// store bundle ID. The team is not in the requirement (the store re-signs with Apple's own leaf); it is read from the code's signing
    /// information once the requirement has held. A TestFlight build may be signed with a different leaf marker; if so it does not satisfy
    /// this and the gate stays on, which is the safe outcome (owner check on the first TestFlight install: `codesign -d -r-`).
    public static let macAppStoreRequirement = "identifier \"\(DevSafety.macAppStoreBundleID)\" and anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.9] exists"

    /// The Developer ID Application requirement for a team: Apple-anchored, with the Developer ID Application leaf marker
    /// (OID 1.2.840.113635.100.6.1.13), the Developer ID CA intermediate (…6.2.6) and the team in the leaf's OU.
    public static func developerIDRequirement(team: String) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    }

    /// Checks the running app (dynamically and, strictly, on disk) against the Developer ID requirement for `team`. Any error counts as "not Developer ID".
    public static func ofRunningApp(team: String = DevSafety.teamID) -> CodeSignature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(developerIDRequirement(team: team) as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .unsigned }
        // Dynamic check of the running code ...
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .unsigned }
        // ... and a strict static check of the bundle on disk (all architectures, resources sealed), so an edited Info.plist
        // (for example WHDevSafety) breaks the seal and fails closed. Any error counts as "not Developer ID".
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { return .unsigned }
        return .developerID(team: team)
    }

    /// Checks the running app against the Mac App Store requirement, dynamically and strictly on disk (as ``ofRunningApp(team:)``), then
    /// requires the code's team identifier to be `team`. Any error counts as "not Mac App Store".
    public static func ofRunningAppMacAppStore(team: String = DevSafety.teamID) -> CodeSignature {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return .unsigned }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(macAppStoreRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return .unsigned }
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return .unsigned }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), requirement) == errSecSuccess else { return .unsigned }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              (dictionary[kSecCodeInfoTeamIdentifier as String] as? String) == team else { return .unsigned }
        return .macAppStore(team: team)
    }
}
#endif
