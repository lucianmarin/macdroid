import Foundation

public enum ScrcpyControlMessageType: UInt8 {
    case injectKeycode = 0
    case injectText = 1
    case injectTouchEvent = 2
    case injectScrollEvent = 3
    case backOrScreenOn = 4
    case setClipboard = 9
    case setDisplayPowerMode = 10
}

public enum AndroidMotionAction: UInt8 {
    case down = 0
    case up = 1
    case move = 2
}

public enum AndroidKeyAction: UInt8 {
    case down = 0
    case up = 1
}

public enum AndroidKeyCode: UInt32 {
    case home = 3
    case back = 4
    case dpadUp = 19
    case dpadDown = 20
    case dpadLeft = 21
    case dpadRight = 22
    case power = 26
    case tab = 61
    case enter = 66
    case del = 67
    case pageUp = 92
    case pageDown = 93
    case escape = 111
    case forwardDel = 112
    case moveHome = 122
    case moveEnd = 123
    case appSwitch = 187
}

public struct AndroidMetaState: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let altOn = AndroidMetaState(rawValue: 0x02)
    public static let altLeftOn = AndroidMetaState(rawValue: 0x10)
    public static let shiftOn = AndroidMetaState(rawValue: 0x01)
    public static let shiftLeftOn = AndroidMetaState(rawValue: 0x40)
    public static let ctrlOn = AndroidMetaState(rawValue: 0x1000)
    public static let ctrlLeftOn = AndroidMetaState(rawValue: 0x2000)
    public static let metaOn = AndroidMetaState(rawValue: 0x10000)
    public static let metaLeftOn = AndroidMetaState(rawValue: 0x20000)
}

public struct ScrcpyVideoCodecMeta: Equatable, Sendable {
    public let codecID: UInt32
    public let width: UInt32
    public let height: UInt32

    public static func parse(from data: Data) -> ScrcpyVideoCodecMeta? {
        guard data.count >= 12 else { return nil }
        return ScrcpyVideoCodecMeta(
            codecID: data.readBigEndianUInt32(at: 0),
            width: data.readBigEndianUInt32(at: 4),
            height: data.readBigEndianUInt32(at: 8)
        )
    }
}

public struct ScrcpyFrameHeader: Equatable, Sendable {
    public let isConfig: Bool
    public let isKeyFrame: Bool
    public let pts: UInt64
    public let packetSize: UInt32

    public static func parse(from data: Data) -> ScrcpyFrameHeader? {
        guard data.count >= 12 else { return nil }
        let ptsAndFlags = data.readBigEndianUInt64(at: 0)
        let isConfig = (ptsAndFlags & (1 << 63)) != 0
        let isKeyFrame = (ptsAndFlags & (1 << 62)) != 0
        let pts = ptsAndFlags & ~(UInt64(0b11) << 62)
        let size = data.readBigEndianUInt32(at: 8)
        return ScrcpyFrameHeader(isConfig: isConfig, isKeyFrame: isKeyFrame, pts: pts, packetSize: size)
    }
}

public enum ScrcpyControlEncoder {
    public static func encodeTouch(
        action: AndroidMotionAction,
        pointerID: UInt64 = 0xFFFF_FFFF_FFFF_FFFE,
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        pressure: UInt16 = 0xFFFF,
        actionButton: UInt32 = 1,
        buttons: UInt32 = 1
    ) -> Data {
        var data = Data(capacity: 32)
        data.append(ScrcpyControlMessageType.injectTouchEvent.rawValue)
        data.append(action.rawValue)
        data.appendBigEndian(pointerID)
        data.appendBigEndian(UInt32(bitPattern: x))
        data.appendBigEndian(UInt32(bitPattern: y))
        data.appendBigEndian(screenWidth)
        data.appendBigEndian(screenHeight)
        data.appendBigEndian(action == .up ? UInt16(0) : pressure)
        data.appendBigEndian(actionButton)
        data.appendBigEndian(action == .up ? UInt32(0) : buttons)
        return data
    }

    public static func encodeKeycode(
        action: AndroidKeyAction,
        keycode: UInt32,
        repeatCount: UInt32 = 0,
        metaState: UInt32 = 0
    ) -> Data {
        var data = Data(capacity: 14)
        data.append(ScrcpyControlMessageType.injectKeycode.rawValue)
        data.append(action.rawValue)
        data.appendBigEndian(keycode)
        data.appendBigEndian(repeatCount)
        data.appendBigEndian(metaState)
        return data
    }

    public static func encodeText(_ text: String) -> Data {
        let utf8 = Data(text.utf8)
        var data = Data(capacity: 5 + utf8.count)
        data.append(ScrcpyControlMessageType.injectText.rawValue)
        data.appendBigEndian(UInt32(utf8.count))
        data.append(utf8)
        return data
    }

    public static func encodeScroll(
        x: Int32,
        y: Int32,
        screenWidth: UInt16,
        screenHeight: UInt16,
        hScroll: Int16,
        vScroll: Int16,
        buttons: UInt32 = 0
    ) -> Data {
        var data = Data(capacity: 21)
        data.append(ScrcpyControlMessageType.injectScrollEvent.rawValue)
        data.appendBigEndian(UInt32(bitPattern: x))
        data.appendBigEndian(UInt32(bitPattern: y))
        data.appendBigEndian(screenWidth)
        data.appendBigEndian(screenHeight)
        data.appendBigEndian(UInt16(bitPattern: hScroll))
        data.appendBigEndian(UInt16(bitPattern: vScroll))
        data.appendBigEndian(buttons)
        return data
    }

    /// scrcpy v3.1 SET_CLIPBOARD: [type=9][sequence:8][paste:1][length:4][utf8]
    public static func encodeSetClipboard(sequence: UInt64 = 0, text: String, paste: Bool) -> Data {
        let utf8 = Data(text.utf8)
        var data = Data(capacity: 14 + utf8.count)
        data.append(ScrcpyControlMessageType.setClipboard.rawValue)
        data.appendBigEndian(sequence)
        data.append(paste ? 1 : 0)
        data.appendBigEndian(UInt32(utf8.count))
        data.append(utf8)
        return data
    }

    /// scrcpy v3.1 SET_DISPLAY_POWER: [type=10][on:1]
    public static func encodeSetDisplayPower(on: Bool) -> Data {
        var data = Data(capacity: 2)
        data.append(ScrcpyControlMessageType.setDisplayPowerMode.rawValue)
        data.append(on ? 1 : 0)
        return data
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }

    func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let slice = self[startIndex + offset ..< startIndex + offset + 4]
        return slice.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    func readBigEndianUInt64(at offset: Int) -> UInt64 {
        let slice = self[startIndex + offset ..< startIndex + offset + 8]
        return slice.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
