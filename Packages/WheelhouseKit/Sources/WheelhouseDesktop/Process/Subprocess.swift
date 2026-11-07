#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization

/// What to run (ARCHITECTURE-MAC §3.2). Nothing is ever passed to a shell.
public struct ProcessSpec: Sendable {
    /// Absolute path, verified by ``ExecutableLocator``; never a bare name.
    public var executable: URL
    /// `argv[1...]`: never joined, never passed to a shell.
    public var arguments: [String]
    /// The COMPLETE environment (built by ``EnvironmentBuilder``); it is not merged with the app's own.
    public var environment: [String: String]
    public var currentDirectory: URL?
    /// nil = `/dev/null`.
    public var stdin: Data?
    public var timeout: Duration
    /// Bytes of stdout kept; over the limit the process is terminated and the run fails with `.outputTooLarge`.
    public var stdoutLimit: Int
    /// Ring buffer: the tail is kept.
    public var stderrLimit: Int
    public var qos: QualityOfService

    public init(executable: URL, arguments: [String] = [], environment: [String: String], currentDirectory: URL? = nil, stdin: Data? = nil,
                timeout: Duration = .seconds(60), stdoutLimit: Int = 64 << 20, stderrLimit: Int = 1 << 20, qos: QualityOfService = .userInitiated) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.stdin = stdin
        self.timeout = timeout
        self.stdoutLimit = stdoutLimit
        self.stderrLimit = stderrLimit
        self.qos = qos
    }
}

public struct ProcessExit: Sendable, Equatable {
    /// The exit status, or nil when a signal ended the process.
    public var code: Int32?
    public var signal: Int32?
    public var timedOut: Bool
    public var duration: Duration
    public var succeeded: Bool { code == 0 && !timedOut }
}

public struct ProcessResult: Sendable {
    public var exit: ProcessExit
    public var stdout: Data
    /// The last `stderrLimit` bytes.
    public var stderrTail: Data
    public var exitCode: Int32? { exit.code }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderrTail, as: UTF8.self) }
}

public enum ProcessEvent: Sendable {
    case stdout(Data)
    case stderr(Data)
    case exit(ProcessExit)
}

public enum SubprocessError: Error, Equatable, Sendable, LocalizedError {
    case launchFailed(String)
    case timedOut(Duration)
    case outputTooLarge(Int)
    public var errorDescription: String? {
        switch self {
        case .launchFailed(let why): "The program could not be started: \(why)"
        case .timedOut(let d): "The program did not finish within \(d.components.seconds) s."
        case .outputTooLarge(let n): "The program produced more than \(n) bytes of output."
        }
    }
}

/// Runs a program through `posix_spawn`: absolute path, argument array, no shell, its own process group, no inherited descriptors,
/// an explicit environment, a timeout and output caps.
public enum Subprocess {
    public static func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        let collector = Collector(spec: spec)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                collector.begin(continuation)
            }
        } onCancel: {
            collector.cancel()
        }
    }

    public static func stream(_ spec: ProcessSpec) -> AsyncThrowingStream<ProcessEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                let process = try SpawnedProcess(spec: spec) { event in
                    continuation.yield(event)
                    if case .exit(let exit) = event {
                        if exit.timedOut { continuation.finish(throwing: SubprocessError.timedOut(spec.timeout)) } else { continuation.finish() }
                    }
                }
                continuation.onTermination = { _ in process.terminate() }
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}

/// Gathers a run's output and resumes the caller exactly once.
private final class Collector: Sendable {
    private struct State {
        var continuation: CheckedContinuation<ProcessResult, Error>?
        var process: SpawnedProcess?
        var stdout = Data()
        var stderr = Data()
        var tooLarge = false
        var cancelled = false
        var finished = false
    }
    private let spec: ProcessSpec
    private let state = Mutex(State())

    init(spec: ProcessSpec) { self.spec = spec }

    func begin(_ continuation: CheckedContinuation<ProcessResult, Error>) {
        state.withLock { $0.continuation = continuation }
        do {
            let process = try SpawnedProcess(spec: spec) { [self] event in handle(event) }
            let cancelledEarly = state.withLock { s -> Bool in s.process = process; return s.cancelled }
            if cancelledEarly { process.terminate() }
        } catch {
            finish(.failure(error))
        }
    }

    func cancel() {
        let process = state.withLock { s -> SpawnedProcess? in s.cancelled = true; return s.process }
        process?.terminate()
    }

    private func handle(_ event: ProcessEvent) {
        switch event {
        case .stdout(let data):
            let overflow = state.withLock { s -> (SpawnedProcess?, Bool) in
                if s.tooLarge { return (nil, false) }
                s.stdout.append(data)
                if s.stdout.count > spec.stdoutLimit, !s.tooLarge { s.tooLarge = true; return (s.process, true) }
                return (nil, false)
            }
            if overflow.1 { overflow.0?.terminate() }
        case .stderr(let data):
            state.withLock { s in
                s.stderr.append(data)
                if s.stderr.count > spec.stderrLimit { s.stderr = s.stderr.suffix(spec.stderrLimit) }
            }
        case .exit(let exit):
            let (out, err, tooLarge, cancelled) = state.withLock { ($0.stdout, $0.stderr, $0.tooLarge, $0.cancelled) }
            if cancelled { finish(.failure(CancellationError())) }
            else if tooLarge { finish(.failure(SubprocessError.outputTooLarge(spec.stdoutLimit))) }
            else if exit.timedOut { finish(.failure(SubprocessError.timedOut(spec.timeout))) }
            else { finish(.success(ProcessResult(exit: exit, stdout: out, stderrTail: err))) }
        }
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        let continuation = state.withLock { s -> CheckedContinuation<ProcessResult, Error>? in
            guard !s.finished else { return nil }
            s.finished = true
            defer { s.continuation = nil; s.process = nil }
            return s.continuation
        }
        continuation?.resume(with: result)
    }
}

/// One spawned child with its pipes. Events arrive on a private serial queue: output chunks, then exactly one `.exit` after both
/// pipes closed (or a short drain period after the child exited, for grandchildren that keep a pipe open).
final class SpawnedProcess: Sendable {
    let pid: pid_t
    private let queue = DispatchQueue(label: "app.wheelhouse.subprocess", qos: .utility)
    private struct State {
        var openReaders = 0
        var exited: (code: Int32?, signal: Int32?)?
        var delivered = false
        var timedOut = false
        var killTask: Task<Void, Never>?
        var timeoutTask: Task<Void, Never>?
        var drainTask: Task<Void, Never>?
        var readers: [DispatchSourceRead] = []
        var exitSource: DispatchSourceProcess?
    }
    private let state = Mutex(State())
    private let handler: @Sendable (ProcessEvent) -> Void
    private let started = ContinuousClock.now
    private static let drainGrace: Duration = .milliseconds(300)

    init(spec: ProcessSpec, handler: @escaping @Sendable (ProcessEvent) -> Void) throws {
        self.handler = handler
        guard spec.executable.path.hasPrefix("/") else { throw SubprocessError.launchFailed("the executable path is not absolute") }
        guard access(spec.executable.path, X_OK) == 0 else { throw SubprocessError.launchFailed("\(spec.executable.path) is not executable") }

        var outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw SubprocessError.launchFailed("pipe: \(String(cString: strerror(errno)))") }
        guard pipe(&errPipe) == 0 else { close(outPipe[0]); close(outPipe[1]); throw SubprocessError.launchFailed("pipe: \(String(cString: strerror(errno)))") }
        var inPipe: [Int32] = [-1, -1]
        if spec.stdin != nil, pipe(&inPipe) != 0 {
            [outPipe[0], outPipe[1], errPipe[0], errPipe[1]].forEach { close($0) }
            throw SubprocessError.launchFailed("pipe: \(String(cString: strerror(errno)))")
        }
        let devNull = spec.stdin == nil ? open("/dev/null", O_RDONLY) : -1

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, spec.stdin != nil ? inPipe[0] : devNull, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let dir = spec.currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, dir.path) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var empty = sigset_t(); sigemptyset(&empty)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_set_qos_class_np(&attr, Self.qosClass(spec.qos))

        let argv = ([spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }

        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, spec.executable.path, &actions, &attr, argv, envp)
        // The child has its own copies now.
        close(outPipe[1]); close(errPipe[1])
        if inPipe[0] >= 0 { close(inPipe[0]) }
        if devNull >= 0 { close(devNull) }
        guard rc == 0 else {
            close(outPipe[0]); close(errPipe[0]); if inPipe[1] >= 0 { close(inPipe[1]) }
            throw SubprocessError.launchFailed(String(cString: strerror(rc)))
        }
        self.pid = childPID

        if let input = spec.stdin, inPipe[1] >= 0 { Self.writeAll(input, to: inPipe[1], on: queue) }
        let out = Self.makeReader(fd: outPipe[0], queue: queue) { [self] data in handler(.stdout(data)) } onEOF: { [self] in readerClosed() }
        let err = Self.makeReader(fd: errPipe[0], queue: queue) { [self] data in handler(.stderr(data)) } onEOF: { [self] in readerClosed() }
        let exitSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        exitSource.setEventHandler { [self] in reap() }
        state.withLock { s in
            s.openReaders = 2
            s.readers = [out, err]
            s.exitSource = exitSource
        }
        out.activate(); err.activate(); exitSource.activate()
        // The child may already have exited before the exit source was armed.
        queue.async { [self] in reap() }

        if spec.timeout < .seconds(24 * 3600) {
            let timeout = spec.timeout
            let task = Task { [weak self] in
                try? await Task.sleep(for: timeout, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.timeoutFired()
            }
            state.withLock { $0.timeoutTask = task }
        }
    }

    // MARK: Lifecycle

    /// SIGTERM to the process group, a 3 s grace period, then SIGKILL to the group.
    func terminate(grace: Duration = .seconds(3)) {
        let first = state.withLock { s -> Bool in
            guard s.killTask == nil, !s.delivered else { return false }
            s.killTask = Task { [pid] in
                try? await Task.sleep(for: grace, clock: .continuous)
                guard !Task.isCancelled else { return }
                kill(-pid, SIGKILL)   // ESRCH when nobody is left in the group
            }
            return true
        }
        if first { kill(-pid, SIGTERM) }
    }

    private func timeoutFired() {
        state.withLock { $0.timedOut = true }
        terminate()
    }

    private func reap() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid else { return }
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        let sig: Int32? = (status & 0x7f) == 0 ? nil : status & 0x7f
        let drain = state.withLock { s -> Bool in
            guard s.exited == nil else { return false }
            s.exited = (code, sig)
            // The kill task is NOT cancelled: after the grace period the whole group is killed even if the leader exited.
            s.timeoutTask?.cancel()
            s.exitSource?.cancel(); s.exitSource = nil
            return s.openReaders > 0
        }
        // A grandchild that keeps a pipe open must not delay the result for long: readers are closed after a short grace.
        if drain {
            let task = Task { [weak self] in
                try? await Task.sleep(for: Self.drainGrace, clock: .continuous)
                guard !Task.isCancelled else { return }
                self?.queue.async { self?.closeReaders() }
            }
            state.withLock { $0.drainTask = task }
        } else {
            deliverIfDone()
        }
    }

    private func readerClosed() {
        state.withLock { $0.openReaders -= 1 }
        deliverIfDone()
    }

    private func closeReaders() {
        let readers = state.withLock { s -> [DispatchSourceRead] in defer { s.readers = [] }; return s.readers }
        readers.forEach { $0.cancel() }
    }

    private func deliverIfDone() {
        let event: ProcessEvent? = state.withLock { s in
            guard !s.delivered, let exited = s.exited, s.openReaders <= 0 else { return nil }
            s.delivered = true
            s.drainTask?.cancel()
            return .exit(ProcessExit(code: exited.code, signal: exited.signal, timedOut: s.timedOut, duration: started.duration(to: .now)))
        }
        if let event { handler(event) }
    }

    // MARK: Pipes

    private static func makeReader(fd: Int32, queue: DispatchQueue, onData: @escaping @Sendable (Data) -> Void,
                                   onEOF: @escaping @Sendable () -> Void) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 { onData(Data(buffer[0..<n])); if n < buffer.count { return } }
                else if n == 0 { source.cancel(); return }
                else if errno == EAGAIN || errno == EWOULDBLOCK { return }
                else if errno == EINTR { continue }
                else { source.cancel(); return }
            }
        }
        source.setCancelHandler { close(fd); onEOF() }
        return source
    }

    private static func writeAll(_ data: Data, to fd: Int32, on queue: DispatchQueue) {
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)   // a child that closes stdin early must not raise SIGPIPE in the app
        DispatchQueue.global(qos: .utility).async {
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { break }
                }
            }
            close(fd)
        }
    }

    private static func qosClass(_ q: QualityOfService) -> qos_class_t {
        switch q {
        case .userInteractive: QOS_CLASS_USER_INTERACTIVE
        case .userInitiated: QOS_CLASS_USER_INITIATED
        case .utility: QOS_CLASS_UTILITY
        case .background: QOS_CLASS_BACKGROUND
        default: QOS_CLASS_DEFAULT
        }
    }
}
#endif
