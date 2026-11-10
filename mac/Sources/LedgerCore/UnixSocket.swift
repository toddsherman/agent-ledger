import Foundation
import Darwin

private func makeAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    return addr
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buf -> Bool in
        guard let base = buf.baseAddress else { return true }
        var offset = 0
        while offset < buf.count {
            let n = Darwin.write(fd, base.advanced(by: offset), buf.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN {
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&p, 1, 1000)
                    continue
                }
                return false
            }
            offset += n
        }
        return true
    }
}

/// Client side for `ledger-host` and `ledger-hook`.
public final class SocketClient {
    public private(set) var fd: Int32 = -1
    private var readBuffer = Data()

    public init() {}

    /// Connects with a timeout. Returns false if the app is not listening.
    public func connect(path: String = LedgerPaths.socketPath, timeoutMs: Int32 = 300) -> Bool {
        guard var addr = makeAddress(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(s, F_GETFL)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            if errno == EINPROGRESS || errno == EAGAIN {
                var p = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
                if poll(&p, 1, timeoutMs) <= 0 { Darwin.close(s); return false }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
                if err != 0 { Darwin.close(s); return false }
            } else {
                Darwin.close(s); return false
            }
        }
        fd = s
        return true
    }

    public func send(_ data: Data) -> Bool {
        guard fd >= 0 else { return false }
        return writeAll(fd, data)
    }

    /// Blocks until at least one complete line is available or the connection closes.
    /// Returns nil on EOF/error.
    public func readLines() -> [Data]? {
        guard fd >= 0 else { return nil }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            if let idx = readBuffer.firstIndex(of: 0x0A) {
                var lines: [Data] = []
                var rest = readBuffer
                var cursor = idx
                while true {
                    lines.append(Data(rest[rest.startIndex..<cursor]))
                    rest = Data(rest[(cursor + 1)...])
                    guard let next = rest.firstIndex(of: 0x0A) else { break }
                    cursor = next
                }
                readBuffer = rest
                return lines.filter { !$0.isEmpty }
            }
            let n = Darwin.read(fd, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return nil }
            readBuffer.append(buf, count: n)
        }
    }

    public func close() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
    }

    deinit { close() }
}

/// The app's ingest server: accepts same-user connections and reads newline-delimited JSON.
public final class IngestServer: @unchecked Sendable {
    public struct Peer: Sendable {
        public let id: Int
        public let pid: pid_t
        public var role: String?
        /// The connecting program, read when the connection was accepted.
        public var path: String?
    }

    public var onLine: ((Peer, Data) -> Void)?
    public var onConnect: ((Peer) -> Void)?
    public var onDisconnect: ((Peer) -> Void)?

    private let path: String
    private let queue = DispatchQueue(label: "agentledger.ingest")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int: (fd: Int32, source: DispatchSourceRead, buffer: Data, peer: Peer)] = [:]
    private var nextID = 1

    public init(path: String = LedgerPaths.socketPath) { self.path = path }

    public func start() throws {
        unlink(path)
        guard var addr = makeAddress(path) else { throw SQLiteError(code: -1, message: "socket path too long") }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw SQLiteError(code: errno, message: "socket() failed") }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { close(s); throw SQLiteError(code: errno, message: "bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(s, 32) == 0 else { close(s); throw SQLiteError(code: errno, message: "listen() failed") }
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL) | O_NONBLOCK)
        listenFD = s
        let src = DispatchSource.makeReadSource(fileDescriptor: s, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptPending() }
        src.resume()
        acceptSource = src
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            for (_, c) in clients { c.source.cancel() }
            clients.removeAll()
            if listenFD >= 0 { close(listenFD); listenFD = -1 }
            unlink(path)
        }
    }

    private func acceptPending() {
        while true {
            let c = accept(listenFD, nil, nil)
            if c < 0 { return }
            // Only accept connections from the same user.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }
            var pid: pid_t = 0
            var len = socklen_t(MemoryLayout<pid_t>.size)
            getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
            let id = nextID; nextID += 1
            let peer = Peer(id: id, pid: pid, role: nil, path: pid > 0 ? Processes.path(of: pid) : nil)
            let src = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
            src.setEventHandler { [weak self] in self?.readClient(id) }
            src.setCancelHandler { close(c) }
            clients[id] = (c, src, Data(), peer)
            src.resume()
            onConnect?(peer)
        }
    }

    private func readClient(_ id: Int) {
        guard var client = clients[id] else { return }
        var buf = [UInt8](repeating: 0, count: 65536)
        var closed = false
        while true {
            let n = read(client.fd, &buf, buf.count)
            if n > 0 { client.buffer.append(buf, count: n); continue }
            if n == 0 { closed = true }
            else if errno != EAGAIN && errno != EINTR { closed = true }
            break
        }
        while let idx = client.buffer.firstIndex(of: 0x0A) {
            let line = Data(client.buffer[client.buffer.startIndex..<idx])
            client.buffer = Data(client.buffer[(idx + 1)...])
            if line.isEmpty { continue }
            if client.peer.role == nil, let msg = try? JSONDecoder().decode(WireMessage.self, from: line),
               msg.type == "hello" {
                client.peer.role = msg.role
            }
            clients[id] = client
            onLine?(client.peer, line)
        }
        if closed {
            client.source.cancel()
            clients[id] = nil
            onDisconnect?(client.peer)
        } else {
            clients[id] = client
        }
    }

    /// Sends a line to every connected peer with the given role. Returns how many received it.
    @discardableResult
    public func broadcast(role: String, _ line: Data) -> Int {
        queue.sync {
            var n = 0
            for (_, c) in clients where c.peer.role == role {
                if writeAll(c.fd, line) { n += 1 }
            }
            return n
        }
    }

    /// Sends a line to one peer. Returns false if it is gone.
    @discardableResult
    public func send(to peerId: Int, _ line: Data) -> Bool {
        queue.sync {
            guard let c = clients[peerId] else { return false }
            return writeAll(c.fd, line)
        }
    }

    public func connectedRoles() -> [String] {
        queue.sync { clients.values.compactMap { $0.peer.role } }
    }

    public func connectedPeers() -> [Peer] {
        queue.sync { clients.values.map { $0.peer } }
    }
}
