import Darwin
import Foundation
import Security

// wheelhouse-mcp: the stdio side of Beacon (ARCHITECTURE-MAC section 10.1).
//
// An MCP client (Claude Code, Claude Desktop, MCP Inspector) launches this tool. It connects to the Wheelhouse app's Unix socket,
// checks that the process listening on it IS the Wheelhouse app (before it sends anything, so the client secret cannot be handed to
// an impostor), sends one hello frame, and then moves newline-delimited JSON-RPC between stdin/stdout and length-prefixed frames on
// the socket. It never touches the Keychain or a cluster.

let helperVersion = "1.0.0"
let protocolVersion = 1

func warn(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

// MARK: Which app

func infoString(_ key: String) -> String? {
    (Bundle.main.object(forInfoDictionaryKey: key) as? String).flatMap { $0.isEmpty || $0.hasPrefix("$(") ? nil : $0 }
}

guard let appBundleID = infoString("WHAppBundleID"), let appGroup = infoString("WHAppGroup") else {
    warn("wheelhouse-mcp: this build does not know which Wheelhouse app it belongs to.")
    exit(78)
}

func socketPath() -> String? {
#if DEBUG
    // Development builds only: lets the test client point the helper at a temporary socket.
    if let override = ProcessInfo.processInfo.environment["WH_BEACON_SOCKET_OVERRIDE"], !override.isEmpty { return override }
#endif
    guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else { return nil }
    return container.appending(path: "b/s").path
}

// MARK: Framing

func readExactly(_ fd: Int32, _ count: Int, timeout: TimeInterval? = nil) -> Data? {
    var out = Data(count: count)
    var got = 0
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    while got < count {
        if let deadline {
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(min(remaining * 1000, 60_000)))
            if r < 0 { if errno == EINTR { continue }; return nil }
            if r == 0 { continue }
        }
        let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
        if n > 0 { got += n } else if n < 0 && errno == EINTR { continue } else { return nil }
    }
    return out
}

func readFrame(_ fd: Int32, timeout: TimeInterval? = nil) -> Data? {
    guard let header = readExactly(fd, 4, timeout: timeout) else { return nil }
    let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
    guard length <= 4 * 1024 * 1024 else { return nil }
    return length == 0 ? Data() : readExactly(fd, length, timeout: timeout)
}

let writeLock = NSLock()

func writeFrame(_ fd: Int32, _ payload: Data) -> Bool {
    var length = UInt32(payload.count).bigEndian
    let frame = Data(bytes: &length, count: 4) + payload
    return writeLock.withLock {
        var sent = 0
        return frame.withUnsafeBytes { buffer in
            while sent < frame.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, frame.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}

// MARK: Connect

func connectOnce(_ path: String) -> Int32? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (i, byte) in path.utf8.enumerated() { buffer[i] = byte }
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if ok != 0 { close(fd); return nil }
    return fd
}

/// The Wheelhouse app, as the helper requires it: the same requirement the app applies to the helper, mirrored.
func appRequirement() -> String {
    let team = appGroup.split(separator: ".").first.map(String.init) ?? ""
    let base = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(appBundleID)\""
    if appBundleID.hasSuffix(".debug") { return base }
    return base + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
}

func serverIsWheelhouse(_ fd: Int32) -> Bool {
    var token = audit_token_t()
    var length = socklen_t(MemoryLayout<audit_token_t>.size)
    guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else { return false }
    let data = Data(bytes: &token, count: MemoryLayout<audit_token_t>.size)
    var code: SecCode?
    guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: data] as CFDictionary, [], &code) == errSecSuccess, let code else { return false }
    var requirement: SecRequirement?
    guard SecRequirementCreateWithString(appRequirement() as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
    return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
}

func launchApp() {
    // Started before connecting, never after a connect that failed to be verified. Beacon itself stays off: the person turns it on.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-g", "-b", appBundleID, "--args", "-WHBeaconLaunch"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
}

enum Failure: String {
    case notRunning = "Wheelhouse is not running or Beacon is off."
    case notVerified = "The program listening for Beacon is not Wheelhouse, so nothing was sent."
    case rejected = "Wheelhouse did not accept this connection. Check Settings, Beacon."
}

func connectAndHello() -> (Int32?, Failure) {
    guard let path = socketPath() else { return (nil, .notRunning) }
    var fd = connectOnce(path)
    if fd == nil {
#if DEBUG
        let overridden = ProcessInfo.processInfo.environment["WH_BEACON_SOCKET_OVERRIDE"] != nil   // tests: never start an app
#else
        let overridden = false
#endif
        if !overridden { launchApp() }
        let deadline = Date().addingTimeInterval(10)
        while fd == nil, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
            fd = connectOnce(path)
        }
    }
    guard let fd else { return (nil, .notRunning) }
    guard serverIsWheelhouse(fd) else { close(fd); return (nil, .notVerified) }
    var hello: [String: Any] = ["protocol": protocolVersion, "helper": helperVersion, "pid": Int(getpid())]
    if let secret = ProcessInfo.processInfo.environment["WHEELHOUSE_BEACON_SECRET"], !secret.isEmpty { hello["secret"] = secret }
    // The secret has been read; it does not stay in this process's environment.
    unsetenv("WHEELHOUSE_BEACON_SECRET")
    guard let body = try? JSONSerialization.data(withJSONObject: hello), writeFrame(fd, body),
          let ack = readFrame(fd, timeout: 10), String(decoding: ack, as: UTF8.self).contains("\"ok\":true") else {
        close(fd)
        return (nil, .rejected)
    }
    return (fd, .rejected)
}

// MARK: Pumps

func emit(_ data: Data) {
    var line = data
    line.append(0x0A)
    FileHandle.standardOutput.write(line)
}

/// No server: answers each request with an error so the client says why, and ends when stdin does.
func runOffline(_ failure: Failure) -> Never {
    while let line = readLine(strippingNewline: true) {
        guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"], object["method"] != nil else { continue }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": failure.rawValue]]
        if let out = try? JSONSerialization.data(withJSONObject: reply) { emit(out) }
    }
    exit(1)
}

let (connection, failure) = connectAndHello()
guard let fd = connection else { runOffline(failure) }

// stdin -> socket, on its own thread.
let reader = Thread {
    while let line = readLine(strippingNewline: true) {
        guard !line.isEmpty else { continue }
        if !writeFrame(fd, Data(line.utf8)) { break }
    }
    shutdown(fd, SHUT_RDWR)   // the client closed stdin: end the session
}
reader.start()

// socket -> stdout.
while let frame = readFrame(fd) { emit(frame) }
exit(0)
