#if os(macOS)
import Foundation
import Security

/// What is known about the signature of the running app. Only "valid Developer ID Application for team X" matters to the
/// safety gate; everything else (Apple Development, ad hoc, unsigned, any error) is "not Developer ID".
public struct CodeSignature: Sendable, Equatable {
    /// Teams for which the running code satisfied the Developer ID Application requirement.
    public var developerIDTeams: Set<String>

    public init(developerIDTeams: Set<String> = []) { self.developerIDTeams = developerIDTeams }

    public func isValidDeveloperID(team: String) -> Bool { developerIDTeams.contains(team) }

    // Fixtures for tests.
    public static let unsigned = CodeSignature()
    public static let adHoc = CodeSignature()
    public static let appleDevelopment = CodeSignature()
    public static func developerID(team: String) -> CodeSignature { CodeSignature(developerIDTeams: [team]) }

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
}
#endif
