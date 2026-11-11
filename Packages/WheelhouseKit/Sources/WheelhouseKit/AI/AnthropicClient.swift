import Foundation

/// Why a call to the Messages API failed, in the words the UI shows.
public enum AIError: Error, Equatable, Sendable, LocalizedError {
    case noKey
    /// 401: the key is wrong or revoked. Not retried.
    case unauthorized
    /// 403: the key may not use this model or endpoint. Not retried.
    case forbidden(String)
    /// 400 and the other client errors. Not retried.
    case badRequest(String)
    /// 429 after the retries; `retryAfter` is the API's hint in seconds.
    case rateLimited(retryAfter: Double?)
    /// 529 after the retries.
    case overloaded
    case server(Int)
    /// No connection to the API.
    case offline
    /// An `error` event inside a stream that had begun.
    case stream(type: String, message: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noKey: "Add your Anthropic API key in Settings to use First Mate."
        case .unauthorized: "The API key was rejected. It may be wrong or revoked."
        case .forbidden(let m): m.isEmpty ? "The API key may not use this model." : m
        case .badRequest(let m): m
        case .rateLimited(let after): after.map { "Rate limited. Try again in \(Int($0.rounded(.up))) s." } ?? "Rate limited. Try again shortly."
        case .overloaded: "The API is overloaded. Try again shortly."
        case .server(let code): "The API returned an error (\(code))."
        case .offline: "Wheelhouse can't reach api.anthropic.com. Check your connection."
        case .stream(_, let m): m
        case .cancelled: "Stopped."
        }
    }
}

/// The network under the client. The real one is ``URLSessionAITransport``; tests replay server-sent-event fixtures.
public protocol AITransport: Sendable {
    /// Sends the request and returns the status, the headers and the response body as lines. Throws only when no response came.
    func open(_ request: URLRequest) async throws -> AITransportResponse
}

public struct AITransportResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var lines: AsyncThrowingStream<String, Error>

    public init(status: Int, headers: [String: String] = [:], lines: AsyncThrowingStream<String, Error>) {
        self.status = status
        self.headers = headers
        self.lines = lines
    }
}

/// `URLSession` (ephemeral, system trust, no custom delegate) over `bytes(for:)`.
public struct URLSessionAITransport: AITransport {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        session = URLSession(configuration: configuration)
    }

    public func open(_ request: URLRequest) async throws -> AITransportResponse {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key).lowercased()] = String(describing: value) }
        // `lines` drops blank lines, which carry nothing here.
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines { continuation.yield(line) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return AITransportResponse(status: http.statusCode, headers: headers, lines: lines)
    }
}

/// What the session needs from a client; `AnthropicClient` is the real one.
public protocol AIMessaging: Sendable {
    func send(_ request: AIRequest, onUpdate: @escaping @Sendable (AIStreamUpdate) -> Void) async throws -> AIResponse
}

public struct AIModelInfo: Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
}

/// The Messages API over server-sent events (ARCHITECTURE-MAC section 9.1).
///
/// The key is the person's own Anthropic API key. It is asked for (`keyProvider`) only when a request is sent, goes only into the
/// `x-api-key` header and is never logged. 429, 529, 5xx and connection errors are retried with `retry-after` or an exponential
/// backoff (1, 2, 4 s; at most 2 retries), and only before any byte of a stream arrived. 400, 401 and 403 are not retried.
public actor AnthropicClient: AIMessaging {
    public typealias KeyProvider = @Sendable () throws -> String?
    public typealias Sleeper = @Sendable (Duration) async throws -> Void

    public static let maxRetries = 2
    public static let backoff: [Double] = [1, 2, 4]

    private let transport: any AITransport
    private let keyProvider: KeyProvider
    private let sleeper: Sleeper
    private let baseURL: URL

    public init(transport: any AITransport = URLSessionAITransport(), baseURL: URL = AnthropicRequestBuilder.baseURL,
                keyProvider: @escaping KeyProvider, sleeper: @escaping Sleeper = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.baseURL = baseURL
        self.keyProvider = keyProvider
        self.sleeper = sleeper
    }

    // MARK: Messages

    public func send(_ request: AIRequest, onUpdate: @escaping @Sendable (AIStreamUpdate) -> Void) async throws -> AIResponse {
        let urlRequest = try makeRequest(path: "v1/messages", method: "POST", body: request.data, beta: request.betaHeader)
        var attempt = 0
        while true {
            do {
                try Task.checkCancellation()
                let response = try await open(urlRequest)
                var accumulator = StreamAccumulator()
                do {
                    for try await line in response.lines {
                        guard let event = SSEParser.event(fromLine: line) else { continue }
                        for update in try accumulator.consume(event) { onUpdate(update) }
                        if accumulator.isFinished { break }
                    }
                } catch let error as AIError { throw error }
                catch is CancellationError { throw AIError.cancelled }
                catch { throw AIError.stream(type: "connection", message: "The connection dropped during the answer.") }
                if Task.isCancelled { throw AIError.cancelled }
                guard accumulator.isFinished else { throw AIError.stream(type: "connection", message: "The answer ended early.") }
                return accumulator.response()
            } catch let error as RetryableFailure {
                guard attempt < Self.maxRetries else { throw error.final }
                let wait = error.retryAfter ?? Self.backoff[min(attempt, Self.backoff.count - 1)]
                attempt += 1
                try await sleeper(.milliseconds(Int(wait * 1000)))
            }
        }
    }

    // MARK: Models (validates the key and fills the model menu)

    public func models() async throws -> [AIModelInfo] {
        let urlRequest = try makeRequest(path: "v1/models?limit=100", method: "GET", body: nil, beta: nil)
        var attempt = 0
        while true {
            do {
                let response = try await open(urlRequest)
                var text = ""
                for try await line in response.lines { text += line }
                guard let data = text.data(using: .utf8), let json = try? JSONValue.parse(data) else { throw AIError.server(response.status) }
                return (json["data"]?.arrayValue ?? []).compactMap { entry in
                    guard let id = entry["id"]?.stringValue else { return nil }
                    return AIModelInfo(id: id, displayName: entry["display_name"]?.stringValue ?? id)
                }
            } catch let error as RetryableFailure {
                guard attempt < Self.maxRetries else { throw error.final }
                attempt += 1
                try await sleeper(.milliseconds(Int((error.retryAfter ?? Self.backoff[min(attempt - 1, 2)]) * 1000)))
            }
        }
    }

    // MARK: Plumbing

    private struct RetryableFailure: Error {
        var final: AIError
        var retryAfter: Double?
    }

    private func makeRequest(path: String, method: String, body: Data?, beta: String?) throws -> URLRequest {
        guard let key = try keyProvider(), !key.isEmpty else { throw AIError.noKey }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw AIError.badRequest("Bad URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(AnthropicRequestBuilder.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if let beta { request.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        request.httpBody = body
        return request
    }

    /// Opens the stream; a retryable failure before any byte of the body is thrown as ``RetryableFailure``.
    private func open(_ request: URLRequest) async throws -> AITransportResponse {
        let response: AITransportResponse
        do {
            response = try await transport.open(request)
        } catch is CancellationError {
            throw AIError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw AIError.cancelled
        } catch {
            throw RetryableFailure(final: .offline, retryAfter: nil)
        }
        guard !(200..<300).contains(response.status) else { return response }
        var body = ""
        do { for try await line in response.lines { body += line } } catch {}
        let message = (body.data(using: .utf8).flatMap { try? JSONValue.parse($0) })?.value(at: "error.message")?.stringValue ?? ""
        let retryAfter = response.headers["retry-after"].flatMap(Double.init)
        switch response.status {
        case 401: throw AIError.unauthorized
        case 403: throw AIError.forbidden(message)
        case 429: throw RetryableFailure(final: .rateLimited(retryAfter: retryAfter), retryAfter: retryAfter)
        case 529: throw RetryableFailure(final: .overloaded, retryAfter: retryAfter)
        case 500...599: throw RetryableFailure(final: .server(response.status), retryAfter: retryAfter)
        default: throw AIError.badRequest(message.isEmpty ? "The API refused the request (\(response.status))." : message)
        }
    }
}
