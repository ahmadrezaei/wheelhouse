import Foundation

/// A single Kubernetes channel-protocol frame: one channel byte followed by the payload.
///
/// Used by `v4.channel.k8s.io` / `v5.channel.k8s.io` (exec, attach) and `v4.channel.k8s.io` (port-forward).
public struct ChannelFrame: Hashable, Sendable {
    public var channel: UInt8
    public var payload: Data

    public init(channel: UInt8, payload: Data = Data()) {
        self.channel = channel
        self.payload = payload
    }

    /// Wire representation: `[channel] + payload`.
    public func encoded() -> Data {
        var out = Data(capacity: payload.count + 1)
        out.append(channel)
        out.append(payload)
        return out
    }

    /// Parses a binary WebSocket message. Returns nil for an empty message.
    public static func decode(_ data: Data) -> ChannelFrame? {
        guard let first = data.first else { return nil }
        return ChannelFrame(channel: first, payload: data.dropFirst().withUnsafeBytes { Data($0) })
    }
}

/// Well-known channels of the exec / attach protocol.
public enum ExecChannel {
    public static let stdin: UInt8 = 0
    public static let stdout: UInt8 = 1
    public static let stderr: UInt8 = 2
    public static let status: UInt8 = 3
    public static let resize: UInt8 = 4
    /// v5 only: the sender closes the write side of the numbered channel (payload = one byte, the channel).
    public static let close: UInt8 = 255
}

public extension ChannelFrame {
    static func stdin(_ data: Data) -> ChannelFrame { ChannelFrame(channel: ExecChannel.stdin, payload: data) }

    /// Terminal resize message, `{"Width":w,"Height":h}` on channel 4.
    static func resize(cols: Int, rows: Int) -> ChannelFrame {
        let json = "{\"Width\":\(max(1, cols)),\"Height\":\(max(1, rows))}"
        return ChannelFrame(channel: ExecChannel.resize, payload: Data(json.utf8))
    }

    /// v5 only: close the stdin stream of the remote process (sends EOF).
    static var closeStdin: ChannelFrame { ChannelFrame(channel: ExecChannel.close, payload: Data([ExecChannel.stdin])) }
}

// MARK: - Exec status (channel 3)

/// Result reported by the API server on the status channel when the remote command ends.
public struct ExecStatus: Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case success
        case exited(code: Int)
        case failure(reason: String?)
    }
    public var outcome: Outcome
    public var message: String?

    public var exitCode: Int? {
        switch outcome {
        case .success: 0
        case .exited(let code): code
        case .failure: nil
        }
    }

    /// Parses a `metav1.Status` JSON document. A `Failure` with `reason: NonZeroExitCode` carries the code in `details.causes`.
    public static func parse(_ data: Data) -> ExecStatus? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let message = obj["message"] as? String
        let status = obj["status"] as? String
        if status == "Success" { return ExecStatus(outcome: .success, message: message) }
        let reason = obj["reason"] as? String
        if reason == "NonZeroExitCode",
           let details = obj["details"] as? [String: Any],
           let causes = details["causes"] as? [[String: Any]],
           let cause = causes.first(where: { ($0["reason"] as? String) == "ExitCode" }),
           let text = cause["message"] as? String, let code = Int(text) {
            return ExecStatus(outcome: .exited(code: code), message: message)
        }
        return ExecStatus(outcome: .failure(reason: reason), message: message)
    }
}

// MARK: - Port-forward demultiplexing

/// Decodes the `v4.channel.k8s.io` port-forward stream for a single forwarded port.
///
/// The server uses two channels per port: `2n` carries data, `2n+1` carries errors. The very first frame the
/// server sends on *each* channel starts with the port number as two little-endian bytes, which must be stripped.
public struct PortForwardDemux: Sendable {
    public enum Event: Equatable, Sendable {
        case data(Data)
        case error(String)
        /// A frame on a channel that does not belong to this port, or a port-prefix-only frame.
        case none
    }

    public let port: Int
    public let dataChannel: UInt8
    public let errorChannel: UInt8
    private var dataPrefixSeen = false
    private var errorPrefixSeen = false

    /// - Parameter index: zero-based position of the port in the `ports=` list.
    public init(port: Int, index: Int = 0) {
        self.port = port
        self.dataChannel = UInt8(truncatingIfNeeded: index * 2)
        self.errorChannel = UInt8(truncatingIfNeeded: index * 2 + 1)
    }

    /// Frame to send to the remote port for local bytes.
    public func outgoing(_ bytes: Data) -> Data { ChannelFrame(channel: dataChannel, payload: bytes).encoded() }

    /// Two-byte little-endian encoding of a port, as the server sends it.
    public static func portPrefix(_ port: Int) -> Data { Data([UInt8(port & 0xFF), UInt8((port >> 8) & 0xFF)]) }

    public mutating func process(_ message: Data) -> Event {
        guard let frame = ChannelFrame.decode(message) else { return .none }
        var payload = frame.payload
        if frame.channel == dataChannel {
            if !dataPrefixSeen {
                dataPrefixSeen = true
                payload = Data(payload.dropFirst(min(2, payload.count)))
            }
            return payload.isEmpty ? .none : .data(payload)
        }
        if frame.channel == errorChannel {
            if !errorPrefixSeen {
                errorPrefixSeen = true
                payload = Data(payload.dropFirst(min(2, payload.count)))
            }
            return payload.isEmpty ? .none : .error(String(decoding: payload, as: UTF8.self))
        }
        return .none
    }
}
