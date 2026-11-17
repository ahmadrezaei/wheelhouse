#if os(macOS)
import Foundation
import Security

/// Which edition of the Mac app is running: the open GitHub edition (not sandboxed, may start programs) or the Mac App Store edition
/// (sandboxed, never starts a third-party program). Decided at run time because compilation conditions do not reach the package.
///
/// The rule (MAS-EDITION §2 point 3, §9):
/// - The `com.apple.security.app-sandbox` entitlement of the running process is final whenever it can be read: `true` means sandboxed;
///   absent or `false` means NOT sandboxed, whatever the environment says. An unsigned test run and the Developer ID app are therefore
///   never blocked.
/// - Only when the read itself fails (no `SecTask`, or an error from `SecTaskCopyValueForEntitlement`) does the sandbox's own
///   `APP_SANDBOX_CONTAINER_ID` environment variable decide. Inside a sandbox that is "unsure, so deny"; outside one the variable is
///   absent and the answer is "not sandboxed".
/// - The OS error of a refused spawn is never used to detect the sandbox (it reports a denied binary as "file doesn't exist").
public struct Edition: Sendable, Equatable {
    public var isSandboxed: Bool

    public init(isSandboxed: Bool) { self.isSandboxed = isSandboxed }

    /// The outcome of reading the sandbox entitlement.
    public enum EntitlementRead: Sendable, Equatable {
        case value(Bool)
        case absent
        case error
    }

    /// The pure decision (the truth table of `EditionTests`).
    public static func decide(entitlement: EntitlementRead, containerID: String?) -> Bool {
        switch entitlement {
        case .value(let v): v
        case .absent: false
        case .error: !(containerID ?? "").isEmpty
        }
    }

    /// Reads the entitlement of the running process.
    static func readEntitlement() -> EntitlementRead {
        guard let task = SecTaskCreateFromSelf(nil) else { return .error }
        var error: Unmanaged<CFError>?
        guard let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.app-sandbox" as CFString, &error) else {
            guard let error else { return .absent }
            error.release()
            return .error
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return .value(false) }
        return .value(CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self)))
    }

    /// The running process, decided once.
    private static let process = Edition(isSandboxed: decide(
        entitlement: readEntitlement(), containerID: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]))

    /// Test-only override, scoped to a task (see ``withEdition(_:operation:)``).
    @TaskLocal static var override: Edition?

    /// The edition in effect. Cheap: a task-local read and a constant.
    public static var current: Edition { override ?? process }

    /// The running process's own edition, ignoring any override (tests).
    static var ofProcess: Edition { process }

    /// Runs `operation` as if the process were `edition` (tests). Synchronous and asynchronous spawn paths inherit it.
    static func withEdition<T>(_ edition: Edition, operation: () throws -> T) rethrows -> T {
        try $override.withValue(edition, operation: operation)
    }

    static func withEdition<T: Sendable>(_ edition: Edition, operation: nonisolated(nonsending) () async throws -> T) async rethrows -> T {
        try await $override.withValue(edition, operation: operation)
    }
}

/// A program was about to be started in the sandboxed App Store edition.
public enum ProcessPolicyError: Error, Equatable, Sendable, LocalizedError {
    case unavailableInAppStoreEdition(tool: String)

    public var errorDescription: String? {
        switch self {
        case .unavailableInAppStoreEdition(let tool): "`\(tool)` can't be run: the App Store edition doesn't start other programs."
        }
    }
}

enum ProcessPolicy {
    /// Throws before anything is spawned (before any descriptor is opened) when the edition is sandboxed. `tool` is the program's name.
    static func requireSpawnAllowed(tool: String) throws {
        guard !Edition.current.isSandboxed else { throw ProcessPolicyError.unavailableInAppStoreEdition(tool: tool) }
    }
}
#endif
