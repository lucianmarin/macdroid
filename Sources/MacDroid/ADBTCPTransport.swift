import CNIOBoringSSL
import Darwin
import Foundation

public enum ADBTransportError: LocalizedError {
    case invalidEndpoint(String)
    case connectionClosed
    case protocolError(String)
    case streamRejected(String)
    case syncFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint(let ep): return "Invalid Wi-Fi endpoint: \(ep)"
        case .connectionClosed: return "ADB TCP connection closed."
        case .protocolError(let msg): return "ADB protocol error: \(msg)"
        case .streamRejected(let dest): return "Device rejected ADB stream: \(dest)"
        case .syncFailed(let msg): return "ADB sync push failed: \(msg)"
        }
    }
}

/// A single multiplexed stream over an ADB TCP connection (e.g. `sync:`, `shell:...`, `localabstract:scrcpy`).
public actor ADBStream {
    public let localID: UInt32
    public let remoteID: UInt32
    private weak var transport: ADBTCPTransport?

    private var buffer = Data()
    private var isClosed = false
    private var waiters: [CheckedContinuation<Data, Error>] = []

    init(localID: UInt32, remoteID: UInt32, transport: ADBTCPTransport) {
        self.localID = localID
        self.remoteID = remoteID
        self.transport = transport
    }

    func enqueue(_ data: Data) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: data)
        } else {
            buffer.append(data)
        }
    }

    func markClosed() {
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for w in pending {
            w.resume(throwing: ADBTransportError.connectionClosed)
        }
    }

    public func readExact(_ count: Int) async throws -> Data {
        while buffer.count < count {
            if isClosed { throw ADBTransportError.connectionClosed }
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                waiters.append(cont)
            }
            buffer.append(chunk)
        }
        let result = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(result)
    }

    public func readToEnd(maxBytes: Int = 4096) async -> Data {
        while !isClosed && buffer.count < maxBytes {
            do {
                let chunk: Data = try await withCheckedThrowingContinuation { cont in
                    waiters.append(cont)
                }
                buffer.append(chunk)
            } catch {
                break
            }
        }
        let result = buffer.prefix(maxBytes)
        buffer.removeAll()
        return Data(result)
    }

    public func write(_ data: Data) async throws {
        guard let transport else { throw ADBTransportError.connectionClosed }
        try await transport.writeStream(localID: localID, remoteID: remoteID, data: data)
    }

    public func close() async {
        isClosed = true
        await transport?.closeStream(localID: localID, remoteID: remoteID)
    }
}

/// Thread-safe POSIX TCP socket with optional in-place BoringSSL TLS 1.3 (STLS) upgrade.
final class ADBSocketChannel: @unchecked Sendable {
    private var fd: Int32
    private var sslCtx: OpaquePointer?
    private var ssl: OpaquePointer?
    private let ioLock = NSLock()
    private var closed = false

    init(host: String, port: UInt16) throws {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var res: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, "\(port)", &hints, &res)
        guard status == 0, let firstAddr = res else {
            throw ADBTransportError.invalidEndpoint("\(host):\(port)")
        }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let current = ptr {
            let sock = Darwin.socket(current.pointee.ai_family, current.pointee.ai_socktype, current.pointee.ai_protocol)
            if sock >= 0 {
                var one: Int32 = 1
                setsockopt(sock, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                if Darwin.connect(sock, current.pointee.ai_addr, current.pointee.ai_addrlen) == 0 {
                    self.fd = sock
                    return
                }
                Darwin.close(sock)
            }
            ptr = current.pointee.ai_next
        }
        throw ADBTransportError.invalidEndpoint("\(host):\(port) (errno \(errno))")
    }

    deinit {
        close()
    }

    func upgradeToTLS() throws {
        let (certPath, keyPath) = try ADBClientIdentity.ensurePEMFiles()
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !closed else { throw ADBTransportError.connectionClosed }

        guard let ctx = SSL_CTX_new(TLS_client_method()) else {
            throw ADBTransportError.protocolError("SSL_CTX_new failed")
        }
        SSL_CTX_set_min_proto_version(ctx, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)

        guard SSL_CTX_use_certificate_file(ctx, certPath, SSL_FILETYPE_PEM) == 1,
              SSL_CTX_use_PrivateKey_file(ctx, keyPath, SSL_FILETYPE_PEM) == 1 else {
            SSL_CTX_free(ctx)
            throw ADBTransportError.protocolError("Failed to load client PEM certificate/key")
        }

        guard let s = SSL_new(ctx) else {
            SSL_CTX_free(ctx)
            throw ADBTransportError.protocolError("SSL_new failed")
        }
        SSL_set_fd(s, fd)
        guard SSL_connect(s) == 1 else {
            let errCode = SSL_get_error(s, -1)
            SSL_free(s)
            SSL_CTX_free(ctx)
            throw ADBTransportError.protocolError("STLS TLS 1.3 handshake failed (SSL error \(errCode))")
        }
        self.sslCtx = ctx
        self.ssl = s
    }

    func writeAll(_ data: Data) throws {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !closed else { throw ADBTransportError.connectionClosed }

        var offset = 0
        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while offset < data.count {
                let n: Int
                if let s = ssl {
                    n = Int(SSL_write(s, base.advanced(by: offset), Int32(data.count - offset)))
                } else {
                    n = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                }
                if n <= 0 {
                    throw ADBTransportError.connectionClosed
                }
                offset += n
            }
        }
    }

    func readExact(_ count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        while offset < count {
            // Wait for data without holding ioLock so concurrent writes never stall.
            if !hasPendingSSLBytes() {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pfd, 1, 50)
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ADBTransportError.connectionClosed
                }
                if ready == 0 {
                    if isClosed() { throw ADBTransportError.connectionClosed }
                    continue
                }
            }

            ioLock.lock()
            if closed {
                ioLock.unlock()
                throw ADBTransportError.connectionClosed
            }
            let n: Int = result.withUnsafeMutableBytes { rawBuf in
                guard let base = rawBuf.baseAddress else { return -1 }
                if let s = ssl {
                    return Int(SSL_read(s, base.advanced(by: offset), Int32(count - offset)))
                } else {
                    return Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
                }
            }
            ioLock.unlock()

            if n <= 0 {
                throw ADBTransportError.connectionClosed
            }
            offset += n
        }
        return result
    }

    private func hasPendingSSLBytes() -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard let s = ssl else { return false }
        return SSL_pending(s) > 0
    }

    private func isClosed() -> Bool {
        ioLock.lock()
        defer { ioLock.unlock() }
        return closed
    }

    func close() {
        ioLock.lock()
        defer { ioLock.unlock() }
        guard !closed else { return }
        closed = true
        if let s = ssl {
            SSL_free(s)
            ssl = nil
        }
        if let ctx = sslCtx {
            SSL_CTX_free(ctx)
            sslCtx = nil
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
    }
}

/// Native Swift ADB-over-Wi-Fi (TCP + STLS) transport: CNXN/STLS/AUTH handshake, stream multiplexing, and `sync:` file push.
public actor ADBTCPTransport {
    private let host: String
    private let port: UInt16
    private let useTLS: Bool
    private let rsaKey: ADBRSAKey

    private var channel: ADBSocketChannel?
    private var maxPayload: Int = Int(ADBPacket.maxPayload)
    private var nextLocalID: UInt32 = 1

    private var streams: [UInt32: ADBStream] = [:]
    private var pendingOpens: [UInt32: CheckedContinuation<ADBStream, Error>] = [:]
    private var readLoopTask: Task<Void, Never>?

    public private(set) var deviceBanner: String = ""

    public init(host: String, port: UInt16, useTLS: Bool = false, rsaKey: ADBRSAKey? = nil) throws {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.rsaKey = try rsaKey ?? ADBRSAKey()
    }

    public func connect() async throws {
        let host = self.host
        let port = self.port
        let ch = try await Task.detached(priority: .userInitiated) {
            try ADBSocketChannel(host: host, port: port)
        }.value
        self.channel = ch

        try await sendPacket(ADBPacket.connect())

        var sentPublicKey = false
        while true {
            let packet = try await readPacket(on: ch)
            switch packet.command {
            case .cnxn:
                maxPayload = max(4096, Int(packet.arg1))
                deviceBanner = String(data: packet.payload, encoding: .utf8) ?? host
                startReadLoop(on: ch)
                return

            case .stls:
                // Android 11+ Wireless Debugging upgrades plain TCP to TLS 1.3 via STLS.
                try await sendPacket(ADBPacket(command: .stls, arg0: 0x01000000, arg1: 0))
                try await Task.detached(priority: .userInitiated) {
                    try ch.upgradeToTLS()
                }.value

            case .auth:
                guard packet.arg0 == ADBAuthType.token.rawValue else {
                    throw ADBTransportError.protocolError("Unexpected AUTH type \(packet.arg0)")
                }
                if !sentPublicKey {
                    let sig = try rsaKey.sign(token: packet.payload)
                    try await sendPacket(ADBPacket(command: .auth, arg0: ADBAuthType.signature.rawValue, arg1: 0, payload: sig))
                    sentPublicKey = true
                } else {
                    let pub = Data(rsaKey.adbPublicKeyString.utf8)
                    try await sendPacket(ADBPacket(command: .auth, arg0: ADBAuthType.rsaPublicKey.rawValue, arg1: 0, payload: pub))
                }

            default:
                throw ADBTransportError.protocolError("Unexpected command during handshake: \(packet.command)")
            }
        }
    }

    public func disconnect() {
        readLoopTask?.cancel()
        readLoopTask = nil
        channel?.close()
        channel = nil
        for (_, cont) in pendingOpens {
            cont.resume(throwing: ADBTransportError.connectionClosed)
        }
        pendingOpens.removeAll()
        let activeStreams = streams.values
        streams.removeAll()
        for stream in activeStreams {
            Task { await stream.markClosed() }
        }
    }

    public func openStream(destination: String) async throws -> ADBStream {
        let localID = nextLocalID
        nextLocalID &+= 1
        return try await withCheckedThrowingContinuation { cont in
            pendingOpens[localID] = cont
            Task {
                do {
                    try await sendPacket(ADBPacket.open(localID: localID, destination: destination))
                } catch {
                    if let pending = pendingOpens.removeValue(forKey: localID) {
                        pending.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Pushes a local file to the Android device using the native ADB `sync:` protocol.
    public func pushFile(data: Data, remotePath: String, mode: UInt32 = 0o100644) async throws {
        let stream = try await openStream(destination: "sync:")
        defer { Task { await stream.close() } }

        let sendSpec = "\(remotePath),\(mode)"
        var sendHeader = Data("SEND".utf8)
        sendHeader.appendLittleEndian(UInt32(sendSpec.utf8.count))
        sendHeader.append(Data(sendSpec.utf8))
        try await stream.write(sendHeader)

        let chunkSize = 64 * 1024
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            var frame = Data("DATA".utf8)
            frame.appendLittleEndian(UInt32(chunk.count))
            frame.append(chunk)
            try await stream.write(frame)
            offset = end
        }

        var doneFrame = Data("DONE".utf8)
        doneFrame.appendLittleEndian(UInt32(Date().timeIntervalSince1970))
        try await stream.write(doneFrame)

        let status = try await stream.readExact(8)
        let tag = String(data: status.prefix(4), encoding: .utf8) ?? ""
        if tag != "OKAY" {
            let errLen = Int(status.readLittleEndianUInt32(at: 4))
            let errData = errLen > 0 ? (try? await stream.readExact(errLen)) : nil
            let errMsg = errData.flatMap { String(data: $0, encoding: .utf8) } ?? tag
            throw ADBTransportError.syncFailed(errMsg)
        }
    }

    func writeStream(localID: UInt32, remoteID: UInt32, data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let end = min(offset + maxPayload, data.count)
            let slice = Data(data[offset..<end])
            try await sendPacket(ADBPacket(command: .wrte, arg0: localID, arg1: remoteID, payload: slice))
            offset = end
        }
    }

    func closeStream(localID: UInt32, remoteID: UInt32) async {
        streams.removeValue(forKey: localID)
        try? await sendPacket(ADBPacket(command: .clse, arg0: localID, arg1: remoteID))
    }

    private func startReadLoop(on ch: ADBSocketChannel) {
        readLoopTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                do {
                    let headerData = try ch.readExact(ADBPacket.headerSize)
                    guard let parsed = ADBPacket.parseHeader(headerData) else {
                        throw ADBTransportError.protocolError("Invalid ADB packet header")
                    }
                    let payload = parsed.length > 0 ? try ch.readExact(Int(parsed.length)) : Data()
                    let packet = ADBPacket(command: parsed.command, arg0: parsed.arg0, arg1: parsed.arg1, payload: payload)
                    guard let self else { break }
                    await self.handlePacket(packet)
                } catch {
                    await self?.disconnect()
                    break
                }
            }
        }
    }

    private func handlePacket(_ packet: ADBPacket) async {
        switch packet.command {
        case .okay:
            let remoteID = packet.arg0
            let localID = packet.arg1
            if let cont = pendingOpens.removeValue(forKey: localID) {
                let stream = ADBStream(localID: localID, remoteID: remoteID, transport: self)
                streams[localID] = stream
                cont.resume(returning: stream)
            }

        case .wrte:
            let remoteID = packet.arg0
            let localID = packet.arg1
            if let stream = streams[localID] {
                await stream.enqueue(packet.payload)
                try? await sendPacket(ADBPacket(command: .okay, arg0: localID, arg1: remoteID))
            }

        case .clse:
            let localID = packet.arg1
            if let cont = pendingOpens.removeValue(forKey: localID) {
                cont.resume(throwing: ADBTransportError.streamRejected("localID=\(localID)"))
            } else if let stream = streams.removeValue(forKey: localID) {
                await stream.markClosed()
            }

        default:
            break
        }
    }

    private func sendPacket(_ packet: ADBPacket) async throws {
        guard let ch = channel else { throw ADBTransportError.connectionClosed }
        let raw = packet.serialize()
        try await Task.detached(priority: .userInitiated) {
            try ch.writeAll(raw)
        }.value
    }

    private func readPacket(on ch: ADBSocketChannel) async throws -> ADBPacket {
        try await Task.detached(priority: .userInitiated) {
            let headerData = try ch.readExact(ADBPacket.headerSize)
            guard let parsed = ADBPacket.parseHeader(headerData) else {
                throw ADBTransportError.protocolError("Invalid ADB packet header")
            }
            let payload = parsed.length > 0 ? try ch.readExact(Int(parsed.length)) : Data()
            return ADBPacket(command: parsed.command, arg0: parsed.arg0, arg1: parsed.arg1, payload: payload)
        }.value
    }
}
