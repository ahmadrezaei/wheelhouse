import Foundation

/// Recent search strings, newest first, capped.
public struct RecentSearches: Sendable {
    static let key = "recentSearches"
    public static func load(defaults: UserDefaults = AppGroup.defaults) -> [String] { defaults.stringArray(forKey: key) ?? [] }
    public static func add(_ query: String, defaults: UserDefaults = AppGroup.defaults, limit: Int = 8) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        var all = load(defaults: defaults).filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        all.insert(q, at: 0)
        defaults.set(Array(all.prefix(limit)), forKey: key)
    }
    public static func clear(defaults: UserDefaults = AppGroup.defaults) { defaults.removeObject(forKey: key) }
}
