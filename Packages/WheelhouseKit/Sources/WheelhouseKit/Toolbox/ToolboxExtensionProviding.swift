import Foundation

/// The tool families whose implementation belongs to a later milestone.
public enum ToolFamily: String, Sendable, CaseIterable {
    case helm, gitops, survey, schema

    /// Where the tools of the family come from.
    public var milestone: String {
        switch self {
        case .helm: "Chart Room (M6a)"
        case .gitops: "Tides (M9)"
        case .survey: "Survey (M8a)"
        case .schema: "the Manifest Editor (M7)"
        }
    }
}

public extension ReadTool {
    /// The family of a tool that a ``ToolboxExtensionProviding`` supplies; nil for the tools the toolbox implements itself.
    var family: ToolFamily? {
        switch self {
        case .helmRelease, .helmListReleases, .helmGetRelease: .helm
        case .gitopsStatus: .gitops
        case .surveyFindings: .survey
        case .explainField: .schema
        default: nil
        }
    }
}

/// Plug-in point for the tool families that arrive after M11a. A milestone adds one new file with a conforming type and the app
/// passes it to ``ClusterToolbox/init(source:policy:redactor:extensions:)``; no existing file changes.
///
/// The provider is called only after the permission gate, so a hidden or ask-pending cluster never reaches it. It gets
/// read-only access and the redactor; whatever it returns still passes through the redactor and the 48 KB limiter.
public protocol ToolboxExtensionProviding: Sendable {
    /// The tools this provider answers.
    var tools: Set<ReadTool> { get }
    func call(_ tool: ReadTool, cluster: ClusterConfig, access: ReadOnlyKubeAccess, input: JSONValue, redactor: Redactor) async throws -> JSONValue
}
