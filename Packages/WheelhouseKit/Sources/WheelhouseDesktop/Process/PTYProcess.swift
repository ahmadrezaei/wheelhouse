#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization

public enum PTYError: Error, Equatable, Sendable, LocalizedError {
    case openFailed(String)
    case spawnFailed(String)
    public var errorDescription: String? {
        switch self {
        case .openFailed(let why): "A pseudo-terminal could not be opened: \(why)"
        case .spawnFailed(let why): "The program could not be started: \(why)"
        }
    }
}

/// A child process on a pseudo-terminal (ARCHITECTURE-MAC §3.3, proven in spike S7). There is no `fork()` in the app: the child is
/// `Contents/Helpers/wh-pty-exec <program> <args>`, started with `POSIX_SPAWN_SETSID`, whose fd 0/1/2 are the PTY slave. The helper
/// runs `ioctl(TIOCSCTTY)` and then `execv`, which is what gives the program a controlling terminal.
///
/// With `stdoutPipe` (the Sign-in sheet for exec plugins) stdin and stderr stay on the terminal while stdout goes to a pipe, so the
/// ExecCredential JSON can be read apart from the prompts.
public final class PTYProcess: Sendable {
    /// Output of the master side, coalesced to at most 16 ms or 64 KB per chunk.
    public let output: AsyncStream<Data>
    /// stdout when `stdoutPipe` was requested; an empty, finished stream otherwise.
    public let stdout: AsyncStream<Data>
    public let pid: pid_t
    /// The terminal device (`st_rdev` of the slave): what `PeerResolver` lists processes by.
    public let ttyDevice: dev_t

    private let master: Int32
    private let writer = DispatchQueue(label: "app.wheelhouse.pty.writer", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "app.wheelhouse.pty.reader", qos: .userInitiated)
    private struct State {
        var exited: ProcessExit?
        var waiters: [CheckedContinuation<ProcessExit, Never>] = []
        var closed = false
        var pending = Data()
        var flushScheduled = false
        var masterSource: DispatchSourceRead?
        var stdoutSource: DispatchSourceRead?
        var exitSource: DispatchSourceProcess?
        var timeoutTask: Task<Void, Never>?
    }
    private let state = Mutex(State())
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let stdoutContinuation: AsyncStream<Data>.Continuation
    private let started = ContinuousClock.now

    /// The helper next to the app's executable: `Contents/Helpers/wh-pty-exec`.
    public static var bundledHelper: URL {
        Bundle.main.bundleURL.appending(path: "Contents/Helpers/wh-pty-exec")
    }

    public init(spec: ProcessSpec, size: (cols: Int, rows: Int), stdoutPipe: Bool = false, helper: URL = PTYProcess.bundledHelper) throws {
        guard access(helper.path, X_OK) == 0 else { throw PTYError.spawnFailed("the helper \(helper.path) is missing") }
        guard spec.executable.path.hasPrefix("/") else { throw PTYError.spawnFailed("the program path is not absolute") }

        var win = winsize(ws_row: UInt16(clamping: size.rows), ws_col: UInt16(clamping: size.cols), ws_xpixel: 0, ws_ypixel: 0)
        var masterFD: Int32 = -1, slaveFD: Int32 = -1
        guard openpty(&masterFD, &slaveFD, nil, nil, &win) == 0 else { throw PTYError.openFailed(String(cString: strerror(errno))) }
        _ = fcntl(masterFD, F_SETFL, fcntl(masterFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(masterFD, F_SETFD, FD_CLOEXEC)
        var slaveName = [CChar](repeating: 0, count: 128)
        guard ttyname_r(slaveFD, &slaveName, slaveName.count) == 0 else {
            close(masterFD); close(slaveFD)
            throw PTYError.openFailed("no slave name")
        }
        var slaveStat = stat()
        fstat(slaveFD, &slaveStat)
        let device = slaveStat.st_rdev
        var pipeFDs: [Int32] = [-1, -1]
        if stdoutPipe, pipe(&pipeFDs) != 0 { close(masterFD); close(slaveFD); throw PTYError.openFailed("pipe") }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        if stdoutPipe { posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], 1) } else { posix_spawn_file_actions_adddup2(&actions, 0, 1) }
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        if let dir = spec.currentDirectory { posix_spawn_file_actions_addchdir_np(&actions, dir.path) }

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var empty = sigset_t(); sigemptyset(&empty)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &empty)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([helper.path, spec.executable.path] + spec.arguments).map { strdup($0) } + [nil]
        let envp = spec.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var childPID: pid_t = 0
        let rc = posix_spawn(&childPID, helper.path, &actions, &attr, argv, envp)
        // The parent keeps the slave open until posix_spawn returned (it keeps the window size), then closes it.
        close(slaveFD)
        if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
        guard rc == 0 else {
            close(masterFD); if pipeFDs[0] >= 0 { close(pipeFDs[0]) }
            throw PTYError.spawnFailed(String(cString: strerror(rc)))
        }
        self.pid = childPID
        self.ttyDevice = device
        self.master = masterFD
        (output, outputContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        (stdout, stdoutContinuation) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)

        let masterSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: readQueue)
        masterSource.setEventHandler { [self] in drainMaster() }
        masterSource.setCancelHandler { [self] in finishOutput() }
        var stdoutSource: DispatchSourceRead?
        if pipeFDs[0] >= 0 {
            let fd = pipeFDs[0]
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
            src.setEventHandler { [self] in
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(fd, &buffer, buffer.count)
                    if n > 0 { stdoutContinuation.yield(Data(buffer[0..<n])); if n < buffer.count { return } }
                    else if n == 0 { src.cancel(); return }
                    else if errno == EINTR { continue }
                    else { if errno != EAGAIN { src.cancel() }; return }
                }
            }
            src.setCancelHandler { [self] in close(fd); stdoutContinuation.finish() }
            stdoutSource = src
        } else {
            stdoutContinuation.finish()
        }
        let exitSource = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: readQueue)
        exitSource.setEventHandler { [self] in reap() }
        state.withLock { s in
            s.masterSource = masterSource
            s.stdoutSource = stdoutSource
            s.exitSource = exitSource
        }
        masterSource.activate(); stdoutSource?.activate(); exitSource.activate()
        readQueue.async { [self] in reap() }
        // The spec's timeout applies to a PTY run too (the Sign-in sheet uses 5 minutes).
        if spec.timeout < .seconds(24 * 3600) {
            let timeout = spec.timeout
            let task = Task { [weak self] in
                try? await Task.sleep(for: timeout, clock: .continuous)
                guard !Task.isCancelled, let self, !self.hasExited else { return }
                await self.terminate()
            }
            state.withLock { $0.timeoutTask = task }
        }
    }

    // MARK: Output

    private func drainMaster() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(master, &buffer, buffer.count)
            if n > 0 {
                append(Data(buffer[0..<n]))
                if n < buffer.count { return }
            } else if n == 0 {
                closeMaster(); return
            } else if errno == EINTR {
                continue
            } else {
                // EAGAIN: nothing more for now. EIO: the slave side closed (the child and its descendants are gone).
                if errno != EAGAIN { closeMaster() }
                return
            }
        }
    }

    /// Leading edge first: output that arrives after a quiet moment goes out at once (a typed key echoes in well under 5 ms), and whatever
    /// follows within 16 ms is coalesced into one chunk (at most 64 KB). The 16 ms timer exists only while output is flowing.
    private func append(_ data: Data) {
        let (now, schedule) = state.withLock { s -> (Data?, Bool) in
            if !s.flushScheduled {
                s.flushScheduled = true
                return (data, true)
            }
            s.pending.append(data)
            if s.pending.count >= 64 * 1024 {
                defer { s.pending = Data() }
                return (s.pending, false)
            }
            return (nil, false)
        }
        if let now { outputContinuation.yield(now) }
        if schedule { scheduleFlush() }
    }

    private func scheduleFlush() {
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(16), clock: .continuous)
            self?.flush()
        }
    }

    private func flush() {
        let (data, again) = state.withLock { s -> (Data, Bool) in
            let out = s.pending
            s.pending = Data()
            // Data went out in this window: stay in coalescing mode for one more window. A quiet window ends it.
            s.flushScheduled = !out.isEmpty
            return (out, !out.isEmpty)
        }
        if !data.isEmpty { outputContinuation.yield(data) }
        if again { scheduleFlush() }
    }

    private func closeMaster() {
        let source = state.withLock { s -> DispatchSourceRead? in defer { s.masterSource = nil }; return s.masterSource }
        source?.cancel()
    }

    private func finishOutput() {
        flush()
        outputContinuation.finish()
        // Close on the writer queue, after queued writes, so a write never races with a closed (or reused) descriptor.
        let fd = master
        writer.async { [self] in
            state.withLock { s in
                s.closed = true
                close(fd)
            }
        }
    }

    // MARK: Input, size, lifetime

    /// Ordered: one serial writer.
    public func write(_ data: Data) {
        let fd = master
        writer.async { [self] in
            guard !state.withLock({ $0.closed }) else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n > 0 { offset += n; continue }
                    if n < 0, errno == EINTR { continue }
                    if n < 0, errno == EAGAIN {
                        var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&p, 1, 200)
                        continue
                    }
                    break
                }
            }
        }
    }

    /// `ioctl(master, TIOCSWINSZ)`: the kernel sends SIGWINCH to the foreground process group.
    public func resize(cols: Int, rows: Int) {
        var win = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &win)
    }

    /// SIGHUP to the process group, then SIGKILL after the grace period.
    public func terminate(gracePeriod: Duration = .seconds(2)) async {
        guard state.withLock({ $0.exited == nil }) else { return }
        kill(-pid, SIGHUP)
        let pid = pid
        // After the grace period the whole group is killed, whether or not the leader has exited by then.
        Task {
            try? await Task.sleep(for: gracePeriod, clock: .continuous)
            kill(-pid, SIGKILL)
        }
        _ = await waitForExit()
    }

    public func waitForExit() async -> ProcessExit {
        await withCheckedContinuation { (c: CheckedContinuation<ProcessExit, Never>) in
            let ready = state.withLock { s -> ProcessExit? in
                if let e = s.exited { return e }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    /// The foreground process group of the terminal (`tcgetpgrp(master)`), asked on demand and never polled; nil once the master is closed.
    public var foregroundProcessGroup: pid_t? {
        state.withLock { s in
            guard !s.closed else { return nil }
            let group = tcgetpgrp(master)
            return group > 0 ? group : nil
        }
    }

    public var hasExited: Bool { state.withLock { $0.exited != nil } }

    private func reap() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        let sig: Int32? = (status & 0x7f) == 0 ? nil : status & 0x7f
        let exit = ProcessExit(code: code, signal: sig, timedOut: false, duration: started.duration(to: .now))
        let waiters = state.withLock { s -> [CheckedContinuation<ProcessExit, Never>] in
            guard s.exited == nil else { return [] }
            s.exited = exit
            s.exitSource?.cancel(); s.exitSource = nil
            s.timeoutTask?.cancel()
            defer { s.waiters = [] }
            return s.waiters
        }
        waiters.forEach { $0.resume(returning: exit) }
        // Output the program wrote just before exiting is still in the kernel buffer: read it, then close.
        readQueue.async { [self] in drainMaster(); closeMaster() }
    }

    deinit {
        state.withLock { s in
            s.masterSource?.cancel(); s.stdoutSource?.cancel(); s.exitSource?.cancel()
        }
    }
}
#endif
