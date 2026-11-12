#if os(macOS)
import Foundation
import WheelhouseKit

public enum BeaconConfigError: Error, Equatable, LocalizedError {
    case unavailableInDevelopmentBuild
    case unreadableExisting(String)
    case claudeNotFound
    case commandFailed(Int32, String)
    case noRepositoryForLocalScope

    public var errorDescription: String? {
        switch self {
        case .unavailableInDevelopmentBuild: "This is unavailable in development builds: Claude Desktop's configuration is global."
        case .unreadableExisting(let why): "The existing configuration could not be read (\(why)), so nothing was written."
        case .claudeNotFound: "The claude command was not found."
        case .commandFailed(let code, let output): "claude exited with status \(code). \(output)"
        case .noRepositoryForLocalScope: "This build does not know which repository to register for, so only the command is shown."
        }
    }
}

/// The text Settings shows and the actions behind "Add to Claude Code" and "Add to Claude Desktop" (ARCHITECTURE-MAC section 10.3).
/// Nothing here runs on its own: both writers act only when the person clicks, and take their target path as an argument.
public struct BeaconClientConfig: Sendable, Equatable {
    public static let secretVariable = "WHEELHOUSE_BEACON_SECRET"
    /// The stable symlink `AppPaths.root/bin/wheelhouse-mcp`.
    public var helperPath: String
    /// `wheelhouse`, or `wheelhouse-debug` for development builds.
    public var serverName: String
    /// Development builds register for one repository only (`local`); a shipped build registers for the user.
    public var developmentBuild: Bool

    public init(helperPath: String, developmentBuild: Bool) {
        self.helperPath = helperPath
        self.developmentBuild = developmentBuild
        self.serverName = developmentBuild ? "wheelhouse-debug" : "wheelhouse"
    }

    public var scope: String { developmentBuild ? "local" : "user" }

    /// The arguments of `claude mcp add` (the secret travels in `--env`, never in the server's own arguments).
    public func claudeCodeArguments(secret: String) -> [String] {
        ["mcp", "add", "--transport", "stdio", "--scope", scope, "--env", "\(Self.secretVariable)=\(secret)", serverName, "--", helperPath]
    }

    /// The same command for a person to read and copy, with the home folder written as `$HOME`.
    public func claudeCodeCommand(secret: String, home: String = NSHomeDirectory()) -> String {
        let shown = helperPath.hasPrefix(home) ? "$HOME" + helperPath.dropFirst(home.count) : helperPath
        return "claude mcp add --transport stdio --scope \(scope) --env \(Self.secretVariable)=\(secret) \(serverName) -- \"\(shown)\""
    }

    /// A project `.mcp.json` snippet. It contains a secret.
    public func projectMCPJSON(secret: String) -> String {
        let entry: JSONValue = ["mcpServers": [serverName: ["command": .string(helperPath), "args": [], "env": [Self.secretVariable: .string(secret)]]]]
        return entry.jsonString(pretty: true)
    }

    public static let projectFileWarning = "Contains a secret: don't commit this file."

    public static func claudeDesktopConfigURL(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> URL {
        home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json")
    }

    // MARK: Claude Desktop

    /// Merges `mcpServers.wheelhouse` into the config at `configURL`, keeping every other key. Writes a backup first and the file
    /// atomically, and refuses when the existing JSON does not parse. Unavailable in development builds.
    public func mergeIntoClaudeDesktop(configURL link: URL, secret: String, gate: DevSafetyPolicy = .current) throws {
        guard !gate.isActive, !developmentBuild else { throw BeaconConfigError.unavailableInDevelopmentBuild }
        // A symlinked config (a dotfiles setup) is followed: the file it points at is changed and the link stays a link.
        let configURL = link.resolvingSymlinksInPath()
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if fm.fileExists(atPath: configURL.path) {
            let data: Data
            do { data = try Data(contentsOf: configURL) } catch { throw BeaconConfigError.unreadableExisting(error.localizedDescription) }
            if !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
                guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw BeaconConfigError.unreadableExisting("it is not a JSON object") }
                root = object
            }
            let backup = configURL.deletingLastPathComponent().appending(path: configURL.lastPathComponent + ".wheelhouse-backup")
            // The first backup is the user's original file: later merges keep it.
            if !fm.fileExists(atPath: backup.path) {
                try data.write(to: backup, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            }
        } else {
            try fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var servers = root["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": helperPath, "env": [Self.secretVariable: secret]] as [String: Any]
        root["mcpServers"] = servers
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: configURL, options: .atomic)
        // The file now holds a secret: owner-only.
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
}

/// Runs a program and returns its exit status and output. The real implementation uses `Process`; tests inject a recorder, so
/// no automated test ever starts `claude`.
public protocol BeaconCommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> (status: Int32, output: String)
}

public struct ProcessCommandRunner: BeaconCommandRunning {
    public init() {}
    public func run(_ executable: URL, arguments: [String], currentDirectory: URL?) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = currentDirectory
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    continuation.resume(returning: (process.terminationStatus, String(decoding: data.prefix(4_000), as: UTF8.self)))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public extension BeaconClientConfig {
    /// "Add to Claude Code": runs `claude mcp add` (the command is found by `locator`, never by a bare name). Development builds
    /// need the repository folder for `--scope local`.
    func addToClaudeCode(secret: String, locator: ExecutableLocator, runner: any BeaconCommandRunning, repository: URL? = nil) async throws {
        guard let claude = locator.find("claude") else { throw BeaconConfigError.claudeNotFound }
        if developmentBuild && repository == nil { throw BeaconConfigError.noRepositoryForLocalScope }
        let result = try await runner.run(claude, arguments: claudeCodeArguments(secret: secret), currentDirectory: developmentBuild ? repository : nil)
        guard result.status == 0 else { throw BeaconConfigError.commandFailed(result.status, result.output) }
    }
}
#endif
