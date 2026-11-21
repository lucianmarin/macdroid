import CNIOBoringSSL
import CryptoKit
import Darwin
import Foundation
import Network
@preconcurrency import Security

public enum ADBPairingError: LocalizedError {
    case invalidAddress(String)
    case invalidHeader
    case handshakeFailed(String)
    case tlsError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let addr): return "Invalid address: \(addr)"
        case .invalidHeader: return "Invalid ADB pairing packet header."
        case .handshakeFailed(let msg): return "Pairing failed: \(msg)"
        case .tlsError(let msg): return "TLS error: \(msg)"
        }
    }
}

/// 6-byte header used by Android 11+ Wireless Debugging pairing protocol.
public struct ADBPairingHeader: Equatable, Sendable {
    public enum PacketType: UInt8, Sendable {
        case spake2Msg = 0
        case peerInfo = 1
    }

    public static let size = 6
    public static let currentVersion: UInt8 = 1

    public let version: UInt8
    public let type: PacketType
    public let payloadLength: UInt32

    public init(version: UInt8 = currentVersion, type: PacketType, payloadLength: UInt32) {
        self.version = version
        self.type = type
        self.payloadLength = payloadLength
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.size)
        data.append(version)
        data.append(type.rawValue)
        data.appendBigEndian(payloadLength)
        return data
    }

    public static func parse(_ data: Data) -> ADBPairingHeader? {
        guard data.count >= size, let type = PacketType(rawValue: data[data.startIndex + 1]) else {
            return nil
        }
        let length = data.readBigEndianUInt32(at: 2)
        return ADBPairingHeader(version: data[data.startIndex], type: type, payloadLength: length)
    }
}

public enum HostPortParser {
    public static func parse(_ input: String) -> (host: String, port: UInt16)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("[") {
            guard let closeIdx = trimmed.firstIndex(of: "]") else { return nil }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeIdx])
            let remainder = trimmed[trimmed.index(after: closeIdx)...]
            guard remainder.hasPrefix(":"), let port = UInt16(remainder.dropFirst()), !host.isEmpty else {
                return nil
            }
            return (host, port)
        }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let port = UInt16(parts[1]) else {
            return nil
        }
        return (String(parts[0]), port)
    }
}

/// Native Swift TLS 1.3 + BoringSSL SPAKE2 pairing client for Android 11+ Wireless Debugging.
public actor ADBPairingClient {
    private let rsaKey: ADBRSAKey

    public init(rsaKey: ADBRSAKey? = nil) throws {
        self.rsaKey = try rsaKey ?? ADBRSAKey()
    }

    public func pair(host: String, port: UInt16, code: String) async throws -> String {
        let keyString = rsaKey.adbPublicKeyString
        return try await Task.detached(priority: .userInitiated) {
            try Self.performBoringSSLPairing(host: host, port: port, code: code, adbPublicKey: keyString)
        }.value
    }

    private static func performBoringSSLPairing(
        host: String,
        port: UInt16,
        code: String,
        adbPublicKey: String
    ) throws -> String {
        let (certPath, keyPath) = try ADBClientIdentity.ensurePEMFiles()

        let fd = try connectTCP(host: host, port: port)
        defer { Darwin.close(fd) }

        guard let ctx = SSL_CTX_new(TLS_client_method()) else {
            throw ADBPairingError.tlsError("SSL_CTX_new failed")
        }
        defer { SSL_CTX_free(ctx) }

        SSL_CTX_set_min_proto_version(ctx, UInt16(TLS1_3_VERSION))
        SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, nil)

        guard SSL_CTX_use_certificate_file(ctx, certPath, SSL_FILETYPE_PEM) == 1,
              SSL_CTX_use_PrivateKey_file(ctx, keyPath, SSL_FILETYPE_PEM) == 1 else {
            throw ADBPairingError.tlsError("Failed to load client PEM certificate/key")
        }

        guard let ssl = SSL_new(ctx) else {
            throw ADBPairingError.tlsError("SSL_new failed")
        }
        defer { SSL_free(ssl) }

        SSL_set_fd(ssl, fd)
        guard SSL_connect(ssl) == 1 else {
            let errCode = SSL_get_error(ssl, -1)
            throw ADBPairingError.tlsError("TLS 1.3 handshake failed (SSL error \(errCode))")
        }

        // Export 64-byte TLS keying material using AOSP's kExportedKeyLabel ("adb-label\0", 10 bytes).
        var ekm = [UInt8](repeating: 0, count: 64)
        let label = Array("adb-label\0".utf8)
        let exportOK = label.withUnsafeBytes { labelPtr -> Int32 in
            SSL_export_keying_material(
                ssl,
                &ekm,
                ekm.count,
                labelPtr.baseAddress?.assumingMemoryBound(to: CChar.self),
                label.count,
                nil,
                0,
                0
            )
        }
        guard exportOK == 1 else {
            throw ADBPairingError.handshakeFailed("SSL_export_keying_material failed")
        }

        // SPAKE2-Ed25519 (exact AOSP kClientName/kServerName including NUL terminators, 16 bytes each).
        let clientName = Array("adb pair client\0".utf8)
        let serverName = Array("adb pair server\0".utf8)
        guard let spakeCtx = SPAKE2_CTX_new(
            spake2_role_alice,
            clientName,
            clientName.count,
            serverName,
            serverName.count
        ) else {
            throw ADBPairingError.handshakeFailed("SPAKE2_CTX_new failed")
        }
        defer { SPAKE2_CTX_free(spakeCtx) }

        var password = Array(code.utf8)
        password.append(contentsOf: ekm)

        var myMsg = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_MSG_SIZE))
        var myMsgLen = 0
        guard SPAKE2_generate_msg(
            spakeCtx,
            &myMsg,
            &myMsgLen,
            myMsg.count,
            password,
            password.count
        ) == 1 else {
            throw ADBPairingError.handshakeFailed("SPAKE2_generate_msg failed")
        }

        let myMsgData = Data(myMsg.prefix(myMsgLen))
        let spakeHeader = ADBPairingHeader(type: .spake2Msg, payloadLength: UInt32(myMsgData.count))
        try sslWriteAll(spakeHeader.serialize() + myMsgData, ssl: ssl)

        let peerSpakeHeaderData = try sslReadExact(ADBPairingHeader.size, ssl: ssl)
        guard let peerSpakeHeader = ADBPairingHeader.parse(peerSpakeHeaderData),
              peerSpakeHeader.type == .spake2Msg else {
            throw ADBPairingError.invalidHeader
        }
        let peerSpakeData = try sslReadExact(Int(peerSpakeHeader.payloadLength), ssl: ssl)

        var keyMaterial = [UInt8](repeating: 0, count: Int(SPAKE2_MAX_KEY_SIZE))
        var keyMaterialLen = 0
        let processOK = peerSpakeData.withUnsafeBytes { peerPtr -> Int32 in
            SPAKE2_process_msg(
                spakeCtx,
                &keyMaterial,
                &keyMaterialLen,
                keyMaterial.count,
                peerPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                peerSpakeData.count
            )
        }
        guard processOK == 1 else {
            throw ADBPairingError.handshakeFailed("SPAKE2_process_msg failed (check pairing code)")
        }

        // Derive AES-128-GCM key via HKDF-SHA256 (32 bytes, no NUL).
        let symmetricKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(keyMaterial.prefix(keyMaterialLen))),
            info: Data("adb pairing_auth aes-128-gcm key".utf8),
            outputByteCount: 16
        )

        var peerInfo = Data(count: 8192)
        peerInfo[0] = 0 // ADB_RSA_PUB_KEY
        let pubBytes = Data(adbPublicKey.utf8)
        peerInfo.replaceSubrange(1 ..< min(1 + pubBytes.count, 8192), with: pubBytes.prefix(8191))

        let nonce = try AES.GCM.Nonce(data: Data(count: 12))
        let sealed = try AES.GCM.seal(peerInfo, using: symmetricKey, nonce: nonce)
        let encryptedPayload = sealed.ciphertext + sealed.tag

        let infoHeader = ADBPairingHeader(type: .peerInfo, payloadLength: UInt32(encryptedPayload.count))
        try sslWriteAll(infoHeader.serialize() + encryptedPayload, ssl: ssl)

        let respHeaderData = try sslReadExact(ADBPairingHeader.size, ssl: ssl)
        guard let respHeader = ADBPairingHeader.parse(respHeaderData),
              respHeader.type == .peerInfo else {
            throw ADBPairingError.handshakeFailed("Device rejected pairing")
        }
        let respEncrypted = try sslReadExact(Int(respHeader.payloadLength), ssl: ssl)
        guard respEncrypted.count >= 16 else {
            throw ADBPairingError.handshakeFailed("Invalid encrypted PeerInfo response")
        }
        let respBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: respEncrypted.dropLast(16),
            tag: respEncrypted.suffix(16)
        )
        _ = try AES.GCM.open(respBox, using: symmetricKey)

        return "Paired with \(host):\(port)"
    }

    private static func connectTCP(host: String, port: UInt16) throws -> Int32 {
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
            throw ADBPairingError.invalidAddress("\(host):\(port)")
        }
        defer { freeaddrinfo(res) }

        var ptr: UnsafeMutablePointer<addrinfo>? = firstAddr
        while let ai = ptr {
            let fd = Darwin.socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
            if fd >= 0 {
                if Darwin.connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen) == 0 {
                    return fd
                }
                Darwin.close(fd)
            }
            ptr = ai.pointee.ai_next
        }
        throw ADBPairingError.tlsError("TCP connect failed to \(host):\(port) (errno \(errno))")
    }

    private static func sslWriteAll(_ data: Data, ssl: OpaquePointer) throws {
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = SSL_write(ssl, base.advanced(by: offset), Int32(data.count - offset))
                guard written > 0 else {
                    throw ADBPairingError.tlsError("SSL_write failed")
                }
                offset += Int(written)
            }
        }
    }

    private static func sslReadExact(_ count: Int, ssl: OpaquePointer) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return -1 }
                return SSL_read(ssl, base.advanced(by: offset), Int32(count - offset))
            }
            guard n > 0 else {
                throw ADBPairingError.handshakeFailed("Connection closed during pairing (read \(offset)/\(count))")
            }
            offset += Int(n)
        }
        return Data(buffer)
    }

    public static func makeTLSOptions() throws -> NWProtocolTLS.Options {
        let options = NWProtocolTLS.Options()
        let secOptions = options.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(secOptions, .TLSv13)
        let identity = try ADBClientIdentity.loadOrCreate()
        sec_protocol_options_set_local_identity(secOptions, identity)
        sec_protocol_options_set_verify_block(secOptions, { _, _, completion in
            // Android Wireless Debugging uses self-signed device certificates.
            completion(true)
        }, .global(qos: .userInteractive))
        return options
    }
}

/// Persists and loads a self-signed X.509 client identity for Android Wireless Debugging mTLS.
public enum ADBClientIdentity {
    private static let p12Password = "macdroid"

    public static func ensurePEMFiles() throws -> (certPath: String, keyPath: String) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacDroid", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let keyURL = dir.appendingPathComponent("client.key")
        let certURL = dir.appendingPathComponent("client.crt")
        let p12URL = dir.appendingPathComponent("client.p12")
        if !FileManager.default.fileExists(atPath: keyURL.path) || !FileManager.default.fileExists(atPath: certURL.path) {
            try generateKeysAndPKCS12(keyURL: keyURL, certURL: certURL, p12URL: p12URL)
        }
        return (certURL.path, keyURL.path)
    }

    public static func loadOrCreate() throws -> sec_identity_t {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MacDroid", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let keyURL = dir.appendingPathComponent("client.key")
        let certURL = dir.appendingPathComponent("client.crt")
        let p12URL = dir.appendingPathComponent("client.p12")
        if !FileManager.default.fileExists(atPath: p12URL.path) {
            try generateKeysAndPKCS12(keyURL: keyURL, certURL: certURL, p12URL: p12URL)
        }

        let p12Data = try Data(contentsOf: p12URL)
        let options: [String: Any] = [kSecImportExportPassphrase as String: p12Password]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12Data as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let secIdentity = items.first?[kSecImportItemIdentity as String] else {
            throw ADBPairingError.tlsError("Failed to import client identity (OSStatus \(status))")
        }
        let identity = secIdentity as! SecIdentity
        guard let nwIdentity = sec_identity_create(identity) else {
            throw ADBPairingError.tlsError("Failed to wrap SecIdentity for Network.framework")
        }
        return nwIdentity
    }

    private static func generateKeysAndPKCS12(keyURL: URL, certURL: URL, p12URL: URL) throws {
        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", certURL.path,
            "-days", "3650",
            "-subj", "/CN=MacDroid"
        ])
        try runOpenSSL([
            "pkcs12", "-export",
            "-inkey", keyURL.path,
            "-in", certURL.path,
            "-out", p12URL.path,
            "-passout", "pass:\(p12Password)"
        ])
    }

    private static func runOpenSSL(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw ADBPairingError.tlsError("openssl exited with status \(proc.terminationStatus)")
        }
    }
}
