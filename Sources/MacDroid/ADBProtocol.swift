import Foundation

/// Native Swift implementation of the ADB wire protocol (24-byte header + payload).
public enum ADBCommand: UInt32, Sendable {
    case sync = 0x434E5953 // "SYNC"
    case cnxn = 0x4E584E43 // "CNXN"
    case auth = 0x48545541 // "AUTH"
    case open = 0x4E45504F // "OPEN"
    case okay = 0x59414B4F // "OKAY"
    case clse = 0x45534C43 // "CLSE"
    case wrte = 0x45545257 // "WRTE"
    case stls = 0x534C5453 // "STLS"
}

public enum ADBAuthType: UInt32, Sendable {
    case token = 1
    case signature = 2
    case rsaPublicKey = 3
}

public struct ADBPacket: Equatable, Sendable {
    public static let headerSize = 24
    public static let protocolVersion: UInt32 = 0x01000001
    public static let maxPayload: UInt32 = 1024 * 1024

    public let command: ADBCommand
    public let arg0: UInt32
    public let arg1: UInt32
    public let payload: Data

    public init(command: ADBCommand, arg0: UInt32, arg1: UInt32, payload: Data = Data()) {
        self.command = command
        self.arg0 = arg0
        self.arg1 = arg1
        self.payload = payload
    }

    public var magic: UInt32 {
        command.rawValue ^ 0xFFFFFFFF
    }

    public var checksum: UInt32 {
        payload.reduce(UInt32(0)) { $0 &+ UInt32($1) }
    }

    public func serialize() -> Data {
        var data = Data(capacity: Self.headerSize + payload.count)
        data.appendLittleEndian(command.rawValue)
        data.appendLittleEndian(arg0)
        data.appendLittleEndian(arg1)
        data.appendLittleEndian(UInt32(payload.count))
        data.appendLittleEndian(checksum)
        data.appendLittleEndian(magic)
        data.append(payload)
        return data
    }

    public static func parseHeader(_ header: Data) -> (command: ADBCommand, arg0: UInt32, arg1: UInt32, length: UInt32, checksum: UInt32)? {
        guard header.count == headerSize else { return nil }
        let rawCmd = header.readLittleEndianUInt32(at: 0)
        let arg0 = header.readLittleEndianUInt32(at: 4)
        let arg1 = header.readLittleEndianUInt32(at: 8)
        let length = header.readLittleEndianUInt32(at: 12)
        let checksum = header.readLittleEndianUInt32(at: 16)
        let magic = header.readLittleEndianUInt32(at: 20)

        guard (rawCmd ^ 0xFFFFFFFF) == magic, let cmd = ADBCommand(rawValue: rawCmd) else {
            return nil
        }
        return (cmd, arg0, arg1, length, checksum)
    }

    public static func connect(banner: String = "host::macdroid\0") -> ADBPacket {
        ADBPacket(
            command: .cnxn,
            arg0: protocolVersion,
            arg1: maxPayload,
            payload: Data(banner.utf8)
        )
    }

    public static func open(localID: UInt32, destination: String) -> ADBPacket {
        var payload = Data(destination.utf8)
        payload.append(0)
        return ADBPacket(command: .open, arg0: localID, arg1: 0, payload: payload)
    }
}

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }
}
