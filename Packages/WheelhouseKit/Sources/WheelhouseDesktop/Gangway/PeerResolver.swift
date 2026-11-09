#if os(macOS)
import Darwin
import Foundation

/// The process on the other end of a loopback connection.
public struct PeerProcess: Sendable, Equatable {
    public var pid: pid_t
    public var session: pid_t
    public var group: pid_t
    public init(pid: pid_t, session: pid_t, group: pid_t) {
        self.pid = pid
        self.session = session
        self.group = group
    }
}

/// Which processes to look at when searching for a connection's client.
public enum PeerSearchScope: Sendable, Equatable {
    case tty(dev_t)
    case processGroup(pid_t)
}

public protocol PeerResolving: Sendable {
    /// Finds the process that holds the client end of a connection: a TCP socket whose local port is `clientPort` and whose remote port
    /// is `listenerPort`, loopback to loopback, among the processes of `scope`.
    func resolve(clientPort: UInt16, listenerPort: UInt16, scope: PeerSearchScope) -> PeerProcess?
    /// The peer's current session and process group (a job can be backgrounded between requests). nil when it is gone.
    func refresh(_ peer: PeerProcess) -> PeerProcess?
}

public extension PeerResolving {
    func refresh(_ peer: PeerProcess) -> PeerProcess? { peer }
}

/// The real resolver, on libproc: `proc_listpids` with `PROC_TTY_ONLY` or `PROC_PGRP_ONLY`, then `proc_pidinfo(PROC_PIDLISTFDS)` and
/// `proc_pidfdinfo(PROC_PIDFDSOCKETINFO)`. Processes of other users can't be inspected (EPERM), so they are never found.
public struct PeerResolver: PeerResolving {
    public init() {}

    public func resolve(clientPort: UInt16, listenerPort: UInt16, scope: PeerSearchScope) -> PeerProcess? {
        let own = getpid()
        for pid in Self.pids(scope) where pid != own && pid > 0 {
            if Self.holdsConnection(pid: pid, clientPort: clientPort, listenerPort: listenerPort) { return refresh(PeerProcess(pid: pid, session: 0, group: 0)) }
        }
        return nil
    }

    public func refresh(_ peer: PeerProcess) -> PeerProcess? {
        let sid = getsid(peer.pid), pgid = getpgid(peer.pid)
        guard sid >= 0, pgid >= 0 else { return nil }
        return PeerProcess(pid: peer.pid, session: sid, group: pgid)
    }

    static func pids(_ scope: PeerSearchScope) -> [pid_t] {
        let (type, info): (UInt32, UInt32)
        switch scope {
        case .tty(let dev): (type, info) = (UInt32(PROC_TTY_ONLY), UInt32(bitPattern: dev))
        case .processGroup(let group): (type, info) = (UInt32(PROC_PGRP_ONLY), UInt32(bitPattern: group))
        }
        let needed = proc_listpids(type, info, nil, 0)
        guard needed > 0 else { return [] }
        var buffer = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 16)
        let written = buffer.withUnsafeMutableBytes { proc_listpids(type, info, $0.baseAddress, Int32($0.count)) }
        guard written > 0 else { return [] }
        return Array(buffer.prefix(Int(written) / MemoryLayout<pid_t>.size))
    }

    static func holdsConnection(pid: pid_t, clientPort: UInt16, listenerPort: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard n == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            let local = UInt16(truncatingIfNeeded: Int(tcp.insi_lport)).bigEndian, remote = UInt16(truncatingIfNeeded: Int(tcp.insi_fport)).bigEndian
            // The ports are in network byte order. Both ends are loopback; the address check is the loopback address of either family.
            if local == clientPort, remote == listenerPort, isLoopback(tcp) { return true }
        }
        return false
    }

    private static func isLoopback(_ ini: in_sockinfo) -> Bool {
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            return UInt32(bigEndian: ini.insi_laddr.ina_46.i46a_addr4.s_addr) >> 24 == 127
        }
        let words = ini.insi_laddr.ina_6.__u6_addr.__u6_addr32
        return words.0 == 0 && words.1 == 0 && words.2 == 0 && UInt32(bigEndian: words.3) == 1
    }
}
#endif
