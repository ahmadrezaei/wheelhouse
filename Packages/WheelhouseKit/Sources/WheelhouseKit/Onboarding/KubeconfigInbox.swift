import Foundation
import Observation

/// Hands a kubeconfig that arrived from outside (share sheet / "Open in") to the import screen.
@MainActor @Observable
public final class KubeconfigInbox {
    public static let shared = KubeconfigInbox()
    public var pendingText: String?
    public var pendingName: String?
    /// Bumped on every offer so a view that is already on screen reloads even when the same text is shared twice.
    public private(set) var revision = 0
    public init() {}
    public func offer(text: String, name: String?) {
        pendingText = text
        pendingName = name
        revision += 1
    }
    public func offer(url: URL) -> Bool {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        offer(text: text, name: url.lastPathComponent)
        return true
    }
    public func take() -> (text: String, name: String?)? {
        guard let t = pendingText else { return nil }
        defer { pendingText = nil; pendingName = nil }
        return (t, pendingName)
    }
}
