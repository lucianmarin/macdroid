import CNIOBoringSSL
import Foundation

/// Manages the persisted RSA-2048 keypair (shared with client.crt/client.key)
/// and encodes the public key in Android's 524-byte RSAPublicKey format for ADB pairing & AUTH.
public final class ADBRSAKey: @unchecked Sendable {
    private let keyPath: String
    public let adbPublicKeyString: String

    public init() throws {
        let (_, keyPath) = try ADBClientIdentity.ensurePEMFiles()
        self.keyPath = keyPath
        let rsa = try Self.loadRSA(from: keyPath)
        defer { RSA_free(rsa) }
        let pubBytes = try Self.encodeAndroidRSAPublicKey(rsa)
        self.adbPublicKeyString = pubBytes.base64EncodedString() + " macdroid@macos\0"
    }

    public func sign(token: Data) throws -> Data {
        let rsa = try Self.loadRSA(from: keyPath)
        defer { RSA_free(rsa) }
        var sig = [UInt8](repeating: 0, count: Int(RSA_size(rsa)))
        var sigLen: UInt32 = 0
        let ok = token.withUnsafeBytes { ptr -> Int32 in
            RSA_sign(
                NID_sha1,
                ptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                token.count,
                &sig,
                &sigLen,
                rsa
            )
        }
        guard ok == 1 else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -3, userInfo: [
                NSLocalizedDescriptionKey: "RSA_sign failed"
            ])
        }
        return Data(sig.prefix(Int(sigLen)))
    }

    private static func loadRSA(from path: String) throws -> OpaquePointer {
        let pem = try Data(contentsOf: URL(fileURLWithPath: path))
        let bio = pem.withUnsafeBytes { ptr in
            BIO_new_mem_buf(ptr.baseAddress, pem.count)
        }
        guard let bio else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -1)
        }
        defer { BIO_free(bio) }
        guard let pkey = PEM_read_bio_PrivateKey(bio, nil, nil, nil) else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -2)
        }
        defer { EVP_PKEY_free(pkey) }
        guard let rsa = EVP_PKEY_get1_RSA(pkey) else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -4)
        }
        return rsa
    }

    /// Encodes a 2048-bit RSA public key in AOSP's 524-byte `RSAPublicKey` binary struct.
    private static func encodeAndroidRSAPublicKey(_ rsa: OpaquePointer) throws -> Data {
        let modulusBytes = 256
        let modulusWords: UInt32 = UInt32(modulusBytes / 4) // 64

        var nPtr: UnsafePointer<BIGNUM>?
        var ePtr: UnsafePointer<BIGNUM>?
        RSA_get0_key(rsa, &nPtr, &ePtr, nil)
        guard let n = nPtr, let e = ePtr else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -5)
        }

        guard let ctx = BN_CTX_new(),
              let r32 = BN_new(),
              let n0invBN = BN_new(),
              let r = BN_new(),
              let rr = BN_new(),
              let rem = BN_new() else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -6)
        }
        defer {
            BN_CTX_free(ctx)
            BN_free(r32)
            BN_free(n0invBN)
            BN_free(r)
            BN_free(rr)
            BN_free(rem)
        }

        // r32 = 2^32; n0inv = -N^(-1) mod 2^32
        BN_set_bit(r32, 32)
        BN_div(nil, rem, n, r32, ctx)
        BN_mod_inverse(n0invBN, rem, r32, ctx)
        BN_sub(n0invBN, r32, n0invBN)
        let n0inv = UInt32(BN_get_word(n0invBN) & 0xFFFFFFFF)

        // rr = (2^2048)^2 mod N
        BN_set_bit(r, Int32(modulusBytes * 8))
        BN_mod_sqr(rr, r, n, ctx)

        var modulusBuf = [UInt8](repeating: 0, count: modulusBytes)
        var rrBuf = [UInt8](repeating: 0, count: modulusBytes)
        guard BN_bn2le_padded(&modulusBuf, modulusBytes, n) == 1,
              BN_bn2le_padded(&rrBuf, modulusBytes, rr) == 1 else {
            throw NSError(domain: "MacDroid.ADBRSAKey", code: -7)
        }

        let exponent = UInt32(BN_get_word(e) & 0xFFFFFFFF)

        var out = Data(capacity: 524)
        out.appendLittleEndian(modulusWords)
        out.appendLittleEndian(n0inv)
        out.append(contentsOf: modulusBuf)
        out.append(contentsOf: rrBuf)
        out.appendLittleEndian(exponent)
        return out
    }
}
