import XCTest
@testable import MacDroid

final class MacDroidTests: XCTestCase {
    func testPairingHeaderRoundTrip() {
        let header = ADBPairingHeader(type: .peerInfo, payloadLength: 8208)
        let bytes = header.serialize()
        XCTAssertEqual(bytes.count, ADBPairingHeader.size)
        XCTAssertEqual(ADBPairingHeader.parse(bytes), header)
    }

    func testParseFrameHeaderFlags() {
        // Bit 63 (config) = 1, Bit 62 (keyframe) = 1, PTS = 1234, packetSize = 512
        var data = Data()
        let ptsAndFlags: UInt64 = (1 << 63) | (1 << 62) | 1234
        data.appendBigEndian(ptsAndFlags)
        data.appendBigEndian(UInt32(512))

        let header = ScrcpyFrameHeader.parse(from: data)
        XCTAssertEqual(header?.isConfig, true)
        XCTAssertEqual(header?.isKeyFrame, true)
        XCTAssertEqual(header?.pts, 1234)
        XCTAssertEqual(header?.packetSize, 512)
    }

    func testEncodeTouchMessageLengthAndHeader() {
        let payload = ScrcpyControlEncoder.encodeTouch(
            action: .down,
            x: 100,
            y: 200,
            screenWidth: 1080,
            screenHeight: 2400
        )
        XCTAssertEqual(payload.count, 32)
        XCTAssertEqual(payload[0], ScrcpyControlMessageType.injectTouchEvent.rawValue)
        XCTAssertEqual(payload[1], AndroidMotionAction.down.rawValue)
    }

    func testSplitAnnexBNALUnits() {
        let annexB = Data([0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x00, 0x01, 0x68, 0xCE])
        let nals = H264SampleBufferBuilder.splitAnnexBNALUnits(annexB)
        XCTAssertEqual(nals.count, 2)
        XCTAssertEqual(nals[0], Data([0x67, 0x42]))
        XCTAssertEqual(nals[1], Data([0x68, 0xCE]))
    }

    func testParseHostPort() {
        let ipv4 = HostPortParser.parse("192.168.1.42:5555")
        XCTAssertEqual(ipv4?.host, "192.168.1.42")
        XCTAssertEqual(ipv4?.port, 5555)

        let ipv6 = HostPortParser.parse("[fe80::1]:37123")
        XCTAssertEqual(ipv6?.host, "fe80::1")
        XCTAssertEqual(ipv6?.port, 37123)

        XCTAssertNil(HostPortParser.parse("192.168.1.42"))
        XCTAssertNil(HostPortParser.parse("192.168.1.42:99999"))
        XCTAssertNil(HostPortParser.parse(":5555"))
    }

    func testADBPacketRoundTrip() {
        let packet = ADBPacket.open(localID: 7, destination: "localabstract:scrcpy")
        let bytes = packet.serialize()
        XCTAssertEqual(bytes.count, ADBPacket.headerSize + "localabstract:scrcpy".utf8.count + 1)

        let header = ADBPacket.parseHeader(bytes.prefix(ADBPacket.headerSize))
        XCTAssertEqual(header?.command, .open)
        XCTAssertEqual(header?.arg0, 7)
        XCTAssertEqual(header?.arg1, 0)
        XCTAssertEqual(header?.length, UInt32(packet.payload.count))
        XCTAssertEqual(header?.checksum, packet.checksum)
    }

    func testADBRSAKeySign() throws {
        let key = try ADBRSAKey()
        let token = Data(repeating: 0xAB, count: 20)
        let sig = try key.sign(token: token)
        XCTAssertEqual(sig.count, 256) // 2048-bit RSA signature
        XCTAssertTrue(key.adbPublicKeyString.hasSuffix(" macdroid@macos\0"))
    }
}
