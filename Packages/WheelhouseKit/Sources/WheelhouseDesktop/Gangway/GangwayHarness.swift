#if os(macOS)
import Foundation
import WheelhouseKit

/// The headless harness: spawns `kubectl` with a Gangway session kubeconfig through `Subprocess` (ARCHITECTURE-MAC section 3.2). No
/// terminal UI. The environment is built from an empty start by `EnvironmentBuilder`, which sets `KUBECACHEDIR` under `AppPaths.root`
/// (kubectl would otherwise write its discovery cache to `~/.kube/cache`); this type adds `KUBECONFIG` and turns `kuberc` off.
public struct GangwayHarness: Sendable {
    public var paths: AppPaths
    public var snapshot: ShellSnapshot?
    /// Replaces `HOME` for the child (tests and matrix runs use a scratch folder, so nothing under the real home is read).
    public var homeOverride: URL?
    public var extraEnvironment: [String: String]

    public init(paths: AppPaths, snapshot: ShellSnapshot?, homeOverride: URL? = nil, extraEnvironment: [String: String] = [:]) {
        self.paths = paths
        self.snapshot = snapshot
        self.homeOverride = homeOverride
        self.extraEnvironment = extraEnvironment
    }

    /// The complete child environment for a session.
    public func environment(kubeconfig: URL) -> [String: String] {
        var additions = ["KUBECONFIG": kubeconfig.path, "KUBERC": "off"]
        if let homeOverride { additions["HOME"] = homeOverride.path }
        additions.merge(extraEnvironment) { _, new in new }
        return EnvironmentBuilder(snapshot: snapshot, paths: paths, home: homeOverride ?? paths.home).build(profile: .kubectl, additions: additions)
    }

    public func spec(kubectl: URL, arguments: [String], session: GangwaySessionHandle, stdin: Data? = nil, timeout: Duration = .seconds(60)) -> ProcessSpec {
        ProcessSpec(executable: kubectl, arguments: arguments, environment: environment(kubeconfig: session.kubeconfig), stdin: stdin, timeout: timeout)
    }

    public func run(kubectl: URL, arguments: [String], session: GangwaySessionHandle, stdin: Data? = nil, timeout: Duration = .seconds(60)) async throws -> ProcessResult {
        try await Subprocess.run(spec(kubectl: kubectl, arguments: arguments, session: session, stdin: stdin, timeout: timeout))
    }

    public func stream(kubectl: URL, arguments: [String], session: GangwaySessionHandle, timeout: Duration = .seconds(60)) -> AsyncThrowingStream<ProcessEvent, Error> {
        Subprocess.stream(spec(kubectl: kubectl, arguments: arguments, session: session, timeout: timeout))
    }
}
#endif
