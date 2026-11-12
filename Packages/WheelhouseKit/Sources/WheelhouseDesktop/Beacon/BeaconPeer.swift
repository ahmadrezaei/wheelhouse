#if os(macOS)
import Darwin
import Foundation
import Security

/// What is known about the program that launched the helper (derived by the app, never taken from what the helper claims).
public struct BeaconLauncher: Sendable, Equatable {
    public var pid: pid_t
    public var path: String
    /// The signing identifier and team of the RUNNING process (dynamic validity), nil when it is unsigned.
    public var signingID: String?
    public var team: String?
    /// The parent chain above the launcher, nearest first (paths only, for the approval sheet).
    public var ancestors: [String]

    public init(pid: pid_t, path: String, signingID: String? = nil, team: String? = nil, ancestors: [String] = []) {
        self.pid = pid
        self.path = path
        self.signingID = signingID
        self.team = team
        self.ancestors = ancestors
    }

    /// What an approval is bound to. A signed launcher binds on team and signing identifier, so an update of the program (a new
    /// versioned path) keeps its approval; an unsigned one binds on its path.
    public var identityKey: String {
        if let team, let signingID { return "signed:\(team):\(signingID)" }
        return "path:\(path)"
    }

    public var description: String {
        if let team, let signingID { return "\(signingID) (team \(team))" }
        return "\(path.isEmpty ? "unknown program" : path) (unsigned)"
    }
}

/// A verified connection peer: the helper, as the kernel and the code signature say it is.
public struct BeaconPeer: Sendable, Equatable {
    public var pid: pid_t
    public var uid: uid_t
    public var launcher: BeaconLauncher
    public init(pid: pid_t, uid: uid_t, launcher: BeaconLauncher) {
        self.pid = pid
        self.uid = uid
        self.launcher = launcher
    }
}

public enum BeaconRejection: String, Error, Sendable, Equatable {
    case wrongUser = "the peer runs as another user"
    case noCredentials = "the peer's credentials could not be read"
    case badSignature = "the peer is not the Wheelhouse helper (code signature)"
    case changedWhileChecking = "the peer changed while it was being checked"
    case tooManyConnections = "too many connections waiting to be checked"
    case badHello = "the first frame was missing or malformed"
}

/// Decides whether the other end of an accepted socket is our helper. Runs before a single byte is read from the peer.
public protocol BeaconPeerVerifying: Sendable {
    func verify(fd: Int32) -> Result<BeaconPeer, BeaconRejection>
}

/// The code requirements (ARCHITECTURE-MAC section 10.1).
public enum BeaconRequirements {
    private static let developerIDMarkers = "certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"

    /// The helper, as the app checks it. Release helpers must be Developer ID signed (an Apple Development certificate, which any
    /// local build can have, does not satisfy it); development helpers need only the team.
    public static func helper(team: String = DevSafety.teamID, identifier: String) -> String {
        let base = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
        return identifier.hasSuffix(".debug") ? base : base + " and " + developerIDMarkers
    }

    /// The app, as the helper checks it before it sends its hello (so a process that took the socket path cannot harvest the secret).
    public static func app(team: String, bundleID: String) -> String {
        let base = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(bundleID)\""
        return bundleID.hasSuffix(".debug") ? base : base + " and " + developerIDMarkers
    }
}

/// The real verifier: `LOCAL_PEERCRED` for the user, `LOCAL_PEERTOKEN` (the audit token) for the code signature, then the launcher.
public struct SecurityPeerVerifier: BeaconPeerVerifying {
    public let requirement: String
    public init(requirement: String) { self.requirement = requirement }

    public func verify(fd: Int32) -> Result<BeaconPeer, BeaconRejection> {
        var cred = xucred()
        var credLength = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &credLength) == 0 else { return .failure(.noCredentials) }
        guard cred.cr_uid == geteuid() else { return .failure(.wrongUser) }
        guard let token = Self.peerToken(fd) else { return .failure(.noCredentials) }
        let pid = pid_t(token.val.5)
        guard Self.satisfies(token: token, requirement: requirement) else { return .failure(.badSignature) }
        let launcher = Self.launcher(of: pid)
        // The audit token names this exact process (pid and pid version): it no longer satisfies the requirement once that process
        // is gone, so a pid that was reused meanwhile cannot pass. The parent must also be unchanged.
        guard Self.satisfies(token: token, requirement: requirement), Self.parent(of: pid) == launcher?.pid else { return .failure(.changedWhileChecking) }
        return .success(BeaconPeer(pid: pid, uid: cred.cr_uid, launcher: launcher ?? BeaconLauncher(pid: 0, path: "")))
    }

    static func peerToken(_ fd: Int32) -> audit_token_t? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 ? token : nil
    }

    static func satisfies(token: audit_token_t, requirement text: String) -> Bool {
        var token = token
        let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
        return pid_t(info.pbi_ppid)
    }

    static func path(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return n > 0 ? String(cString: buffer) : ""
    }

    /// The program that launched `pid`, with its running signature and the chain above it.
    static func launcher(of pid: pid_t) -> BeaconLauncher? {
        guard let parentPID = parent(of: pid) else { return nil }
        var ancestors: [String] = []
        var next = parent(of: parentPID)
        while let n = next, n > 1, ancestors.count < 5 {
            ancestors.append(path(of: n))
            next = parent(of: n)
        }
        var launcher = BeaconLauncher(pid: parentPID, path: path(of: parentPID), ancestors: ancestors)
        // The running process, not the file at its path (a file on disk can differ from what is running).
        var code: SecCode?
        if SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: parentPID] as CFDictionary, [], &code) == errSecSuccess, let code,
           SecCodeCheckValidity(code, [], nil) == errSecSuccess {
            var staticCode: SecStaticCode?
            var info: CFDictionary?
            if SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
               SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
               let dictionary = info as? [String: Any] {
                launcher.team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String
                launcher.signingID = dictionary[kSecCodeInfoIdentifier as String] as? String
                // An ad hoc or platform binary without a team has no team to bind to: it is treated as unsigned.
                if launcher.team == nil { launcher.signingID = nil }
            }
        }
        return launcher
    }
}
#endif
