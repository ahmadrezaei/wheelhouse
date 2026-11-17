#if os(macOS)
import Foundation

/// Links and wording that explain what the App Store edition leaves out (one place, used by the Chart Room, Survey and Tides notes,
/// the Moorings rows and the import sheet).
public enum EditionNotice {
    /// The page that explains what the App Store edition leaves out and where the open-source edition is.
    public static let learnMore = URL(string: "https://ahmadrezaei.github.io/wheelhouse/mac/editions.html")!
    /// The same page, at the section on clusters that sign in through an exec credential plugin.
    public static let learnMoreURL = URL(string: "https://ahmadrezaei.github.io/wheelhouse/mac/editions.html#exec-plugins")!

    /// The exec-plugin badge text.
    public static func execPlugin(command: String) -> String {
        ExecCredentialError.unavailableInEdition(command: (command as NSString).lastPathComponent).localizedDescription
    }
}

// What the edition lets a kept feature do (MAS-EDITION §2 point 4). Each flag is derived from ``Edition`` and can be built with any
// value, so views and models take it as an input and tests exercise both settings without a sandbox.

/// Chart Room: reading releases through the Kubernetes API stays; anything that starts helm (install, upgrade, roll back, uninstall,
/// repositories) needs the open-source edition.
public struct ChartRoomCapabilities: Sendable, Equatable {
    public var writes: Bool

    public init(writes: Bool) { self.writes = writes }

    public static var current: ChartRoomCapabilities { ChartRoomCapabilities(writes: !Edition.current.isSandboxed) }

    public static let notice = "Helm changes need the open-source edition."
}

/// Survey: Trivy Operator reports and the built-in access and workload rules stay; scanning images on this Mac with trivy needs the
/// open-source edition.
public struct SurveyCapabilities: Sendable, Equatable {
    public var localScans: Bool

    public init(localScans: Bool) { self.localScans = localScans }

    public static var current: SurveyCapabilities { SurveyCapabilities(localScans: !Edition.current.isSandboxed) }

    public static let notice = "Scanning images on this Mac needs the open-source edition."
}

/// Tides: everything that goes through the Kubernetes API stays; the Flux diff runs the `flux` program and needs the open-source edition.
public struct TidesCapabilities: Sendable, Equatable {
    public var fluxDiff: Bool

    public init(fluxDiff: Bool) { self.fluxDiff = fluxDiff }

    public static var current: TidesCapabilities { TidesCapabilities(fluxDiff: !Edition.current.isSandboxed) }

    public static let notice = "The Flux diff needs the open-source edition."
}
#endif
