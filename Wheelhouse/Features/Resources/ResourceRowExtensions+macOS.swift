import WheelhouseKit

/// A seam for the Mac app to add entries to a resource row's context menu (Rigging pack commands). Nil on a fresh launch, so the list is
/// unchanged until the Mac app sets it. The closure gets the row's reference and its raw object.
@MainActor
enum ResourceRowExtensions {
    static var provider: ((ResourceRef, JSONValue) -> [KubeRowAction])?

    static func actions(for ref: ResourceRef, raw: JSONValue) -> [KubeRowAction] { provider?(ref, raw) ?? [] }
}
