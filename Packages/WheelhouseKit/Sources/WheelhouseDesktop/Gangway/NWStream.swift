#if os(macOS)
import Foundation
import Network
import Synchronization

enum StreamError: Error, Equatable {
    case closed
    case failed(String)
}

/// An `NWConnection` as async receive and send. One reader and one writer at a time (each connection direction has one task).
final class NWStream: Sendable {
    let connection: NWConnection
    private let eof = Mutex(false)
    private let queue: DispatchQueue

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Starts the connection and waits until it is ready (the TLS handshake included).
    func start() async throws {
        let box = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                box.set(continuation)
                connection.stateUpdateHandler = { [box] state in
                    switch state {
                    case .ready: box.resume(.success(()))
                    case .failed(let error): box.resume(.failure(StreamError.failed(error.localizedDescription)))
                    case .waiting(let error): box.resume(.failure(StreamError.failed(error.localizedDescription)))
                    case .cancelled: box.resume(.failure(StreamError.closed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: { [connection] in connection.cancel() }
        connection.stateUpdateHandler = nil
    }

    /// nil at the end of the stream.
    func receive(max: Int = 64 * 1024) async throws -> Data? {
        if eof.withLock({ $0 }) { return nil }
        // A cancelled reader closes the connection: a pending `receive` has no other way to be interrupted.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: max) { [self] data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        if isComplete { eof.withLock { $0 = true } }
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: StreamError.failed(error.localizedDescription))
                    } else {
                        eof.withLock { $0 = true }
                        continuation.resume(returning: nil)
                    }
                }
            }
        } onCancel: { [connection] in connection.cancel() }
    }

    func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: StreamError.failed(error.localizedDescription)) } else { continuation.resume() }
            })
        }
    }

    /// Half-close: a FIN after what was already sent.
    func finish() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func cancel() { connection.cancel() }

    /// The remote port of an accepted connection.
    var remotePort: UInt16? {
        if case .hostPort(_, let port)? = connection.currentPath?.remoteEndpoint { return port.rawValue }
        if case .hostPort(_, let port) = connection.endpoint { return port.rawValue }
        return nil
    }
}

/// Resumes a continuation at most once, from any thread.
final class ResumeOnce: Sendable {
    private let continuation = Mutex<CheckedContinuation<Void, Error>?>(nil)
    func set(_ c: CheckedContinuation<Void, Error>) { continuation.withLock { $0 = c } }
    func resume(_ result: Result<Void, Error>) {
        let c = continuation.withLock { c -> CheckedContinuation<Void, Error>? in
            defer { c = nil }
            return c
        }
        c?.resume(with: result)
    }
}
#endif
