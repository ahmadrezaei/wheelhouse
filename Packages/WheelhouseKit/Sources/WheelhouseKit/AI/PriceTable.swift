import Foundation

/// Dollars per million tokens. The table ships with the app and is only an estimate.
public struct ModelPrice: Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Cache writes with the 5-minute lifetime cost 1.25 times the input price.
    public var cacheWrite: Double { input * 1.25 }

    public func cost(of usage: AIUsage) -> Double {
        (Double(usage.inputTokens) * input + Double(usage.outputTokens) * output
            + Double(usage.cacheCreationTokens) * cacheWrite + Double(usage.cacheReadTokens) * cacheRead) / 1_000_000
    }
}

/// The bundled prices (ARCHITECTURE-MAC section 9.1). A server-side fallback can answer with another model, so the fallbacks are
/// priced at their real rates too; a model the table does not know is priced at the highest rate it holds, never at zero.
public enum PriceTable {
    public static let prices: [String: ModelPrice] = [
        "claude-opus-5-5": ModelPrice(input: 4, output: 20, cacheRead: 0.20),
        "claude-sonnet-5-5": ModelPrice(input: 2, output: 10, cacheRead: 0.10),   // the API reference; ARCHITECTURE-MAC says 0.20
        "claude-opus-5": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-opus-4-8": ModelPrice(input: 5, output: 25, cacheRead: 0.50),
        "claude-sonnet-5": ModelPrice(input: 2, output: 10, cacheRead: 0.20),
    ]

    public static let unknown = ModelPrice(input: 5, output: 25, cacheRead: 0.50)

    public static func price(for model: String?) -> ModelPrice {
        guard let model else { return unknown }
        return prices[model] ?? unknown
    }

    /// The estimated cost of a response, one usage entry per attempt. An entry without a model uses `defaultModel`.
    public static func cost(of usage: [AIUsage], defaultModel: String) -> Double {
        usage.reduce(0) { $0 + price(for: $1.model ?? defaultModel).cost(of: $1) }
    }
}

/// The per-conversation and per-day spend limits (ARCHITECTURE-MAC section 9.4).
public struct CostCaps: Codable, Sendable, Equatable {
    public static let conversationRange = 0.25...50.0
    public static let defaultConversation = 2.0
    public static let defaultDaily = 10.0
    public static let continueStep = 2.0

    public var conversation: Double
    public var daily: Double

    public init(conversation: Double = defaultConversation, daily: Double = defaultDaily) {
        self.conversation = min(max(conversation, Self.conversationRange.lowerBound), Self.conversationRange.upperBound)
        self.daily = max(daily, 0)
    }
}

/// What may be sent next, given what was spent.
public enum CostGate: Sendable, Equatable {
    case open
    case conversationCapReached(spent: Double, cap: Double)
    case dailyCapReached(spent: Double, cap: Double)

    /// A reply can overshoot a cap by up to one response, so the check adds an estimate of the next request's input.
    public static func check(conversationSpent: Double, conversationCap: Double, dailySpent: Double, dailyCap: Double, nextInputEstimate: Double = 0) -> CostGate {
        if conversationSpent + nextInputEstimate >= conversationCap { return .conversationCapReached(spent: conversationSpent, cap: conversationCap) }
        if dailySpent + nextInputEstimate >= dailyCap { return .dailyCapReached(spent: dailySpent, cap: dailyCap) }
        return .open
    }
}

/// Today's spend across every conversation, kept in a small file next to the conversations (per local day).
public final class DailySpendStore: @unchecked Sendable {
    private struct File: Codable { var day: String; var dollars: Double }

    private let lock = NSLock()
    private let url: URL?
    private let now: @Sendable () -> Date
    private var file: File

    public init(url: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
        let today = Self.day(now())
        if let url, let data = try? Data(contentsOf: url), let stored = try? JSONDecoder().decode(File.self, from: data), stored.day == today {
            file = stored
        } else {
            file = File(day: today, dollars: 0)
        }
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public var today: Double {
        lock.lock(); defer { lock.unlock() }
        rollIfNeeded()
        return file.dollars
    }

    public func add(_ dollars: Double) {
        lock.lock(); defer { lock.unlock() }
        rollIfNeeded()
        file.dollars += dollars
        if let url, let data = try? JSONEncoder().encode(file) { try? data.write(to: url, options: .atomic) }
    }

    private func rollIfNeeded() {
        let today = Self.day(now())
        if file.day != today { file = File(day: today, dollars: 0) }
    }
}
