import AppKit
import AVFoundation
import Foundation
import Network

@MainActor
public final class ScrcpySession: ObservableObject {
    public static let scrcpyVersion = "3.1"
    public static let remoteServerPath = "/data/local/tmp/scrcpy-server.jar"

    public enum State: Equatable {
        case idle
        case connecting(String)
        case streaming(deviceName: String, width: Int, height: Int)
        case error(String)
    }

    public enum AudioOutputMode: Equatable {
        case desktop
        case phone
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var videoSize: CGSize = CGSize(width: 720, height: 1600)
    @Published public private(set) var deviceLogicalSize: CGSize?
    @Published public private(set) var desktopMode: Bool = false
    @Published public private(set) var audioMode: AudioOutputMode = .desktop
    @Published public private(set) var isScreenOff: Bool = false
    @Published public private(set) var transferStatus: String?
    public var viewportSize: CGSize = .zero

    public var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let sampleBuilder = H264SampleBufferBuilder()
    private let audioPlayer = RawAudioPlayer()
    private var transport: ADBTCPTransport?
    private var shellStream: ADBStream?
    private var videoStream: ADBStream?
    private var audioStream: ADBStream?
    private var controlStream: ADBStream?
    private var streamTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var controlReadTask: Task<Void, Never>?
    private var lastEndpoint: (host: String, port: UInt16, useTLS: Bool)?
    private var clipboardSequence: UInt64 = 1

    public static let lastServiceKey = "MacDroid.lastConnectedServiceName"

    public init() {}

    public func toggleAudioMode() async {
        await setAudioMode(audioMode == .desktop ? .phone : .desktop)
    }

    public func setAudioMode(_ mode: AudioOutputMode) async {
        guard audioMode != mode else { return }
        audioMode = mode
        audioPlayer.setMuted(mode != .desktop)

        if let endpoint = lastEndpoint, case .streaming = state {
            await connectWiFi(host: endpoint.host, port: endpoint.port, useTLS: endpoint.useTLS)
        }
    }

    public func toggleScreenOff() {
        isScreenOff.toggle()
        sendControl(ScrcpyControlEncoder.encodeSetDisplayPower(on: !isScreenOff))
    }

    public func setDesktopMode(_ enabled: Bool) async {
        guard desktopMode != enabled else { return }
        desktopMode = enabled
        if let endpoint = lastEndpoint, state != .idle {
            await connectWiFi(host: endpoint.host, port: endpoint.port, useTLS: endpoint.useTLS)
        }
    }

    public func connectWiFi(host: String, port: UInt16, useTLS: Bool = false) async {
        lastEndpoint = (host, port, useTLS)
        await disconnect()
        state = .connecting(desktopMode ? "Starting Desktop Mode on \(host):\(port)…" : "Connecting to \(host):\(port)…")

        do {
            guard let serverURL = Bundle.module.url(forResource: "scrcpy-server", withExtension: nil, subdirectory: "Resources") else {
                throw ADBTransportError.protocolError("scrcpy-server not found in bundle. Run `make deps` first.")
            }
            let serverData = try Data(contentsOf: serverURL)

            let adbTransport = try ADBTCPTransport(host: host, port: port, useTLS: useTLS)
            self.transport = adbTransport
            try await adbTransport.connect()

            state = .connecting("Pushing scrcpy-server…")
            try await adbTransport.pushFile(data: serverData, remotePath: Self.remoteServerPath)

            state = .connecting(desktopMode ? "Starting Desktop Mode…" : "Starting scrcpy-server…")
            let captureAudio = (audioMode == .desktop)
            var args = [
                "CLASSPATH=\(Self.remoteServerPath)",
                "app_process", "/", "com.genymobile.scrcpy.Server", Self.scrcpyVersion,
                "tunnel_forward=true",
                "audio=\(captureAudio ? "true" : "false")",
                "control=true",
                "video_codec=h264",
                "max_fps=60",
                "send_device_meta=true",
                "send_frame_meta=true",
                "send_codec_meta=true",
                "cleanup=true"
            ]
            if captureAudio {
                args.append("audio_codec=raw")
            }
            if desktopMode {
                args.append("new_display=\(desktopDisplaySpec())")
                args.append("display_ime_policy=local")
                args.append("video_bit_rate=16000000")
            } else {
                args.append("max_size=1280")
                args.append("video_bit_rate=8000000")
            }
            let shellCmd = args.joined(separator: " ")
            shellStream = try await adbTransport.openStream(destination: "shell:\(shellCmd)")

            try await Task.sleep(nanoseconds: 500_000_000)

            // scrcpy v3.1 socket order: video -> [audio] -> control
            let video = try await adbTransport.openStream(destination: "localabstract:scrcpy")
            let audio: ADBStream? = captureAudio
                ? try await adbTransport.openStream(destination: "localabstract:scrcpy")
                : nil
            let control = try await adbTransport.openStream(destination: "localabstract:scrcpy")
            self.videoStream = video
            self.audioStream = audio
            self.controlStream = control

            _ = try await video.readExact(1)
            let nameData = try await video.readExact(64)
            let deviceName = String(data: nameData.prefix(while: { $0 != 0 }), encoding: .utf8) ?? "\(host):\(port)"

            let codecMetaData = try await video.readExact(12)
            guard let codecMeta = ScrcpyVideoCodecMeta.parse(from: codecMetaData) else {
                throw ADBTransportError.protocolError("Invalid codec metadata")
            }

            let width = Int(codecMeta.width)
            let height = Int(codecMeta.height)
            videoSize = CGSize(width: width, height: height)
            if desktopMode {
                // Desktop mode uses 240 dpi (1.5x density), so 1 Android dp = 1 macOS point.
                deviceLogicalSize = CGSize(width: CGFloat(width) / 1.5, height: CGFloat(height) / 1.5)
            } else {
                deviceLogicalSize = await queryPhoneLogicalSize(transport: adbTransport, streamSize: CGSize(width: width, height: height))
            }
            isScreenOff = false
            sampleBuilder.reset()
            if captureAudio {
                audioPlayer.start()
                audioPlayer.setMuted(false)
            } else {
                audioPlayer.stop()
            }
            state = .streaming(deviceName: deviceName, width: width, height: height)

            streamTask = Task { [weak self] in
                await self?.readVideoLoop(stream: video)
            }
            if let audio {
                audioTask = Task { [weak self] in
                    await self?.readAudioLoop(stream: audio)
                }
            }
            controlReadTask = Task { [weak self] in
                await self?.readControlLoop(stream: control)
            }
        } catch {
            state = .error(error.localizedDescription)
            await cleanupResources()
        }
    }

    private func desktopDisplaySpec() -> String {
        let size: CGSize
        if viewportSize.width >= 320, viewportSize.height >= 240 {
            size = viewportSize
        } else if let screen = NSScreen.main {
            size = screen.frame.size
        } else {
            return "1920x1200/240"
        }
        // 1.5x logical window points (e.g. 1280 -> 1920) matching 240 DPI (1.5x mdpi).
        var w = size.width * 1.5
        var h = size.height * 1.5
        if w < 1024 {
            let scale = 1024.0 / max(1.0, w)
            w = 1024.0
            h *= scale
        }
        let width = (Int(w.rounded()) / 8) * 8
        let height = max(640, (Int(h.rounded()) / 8) * 8)
        return "\(width)x\(height)/240"
    }

    public func disconnect() async {
        streamTask?.cancel()
        streamTask = nil
        audioTask?.cancel()
        audioTask = nil
        controlReadTask?.cancel()
        controlReadTask = nil
        audioPlayer.stop()
        await cleanupResources()
        state = .idle
    }

    public func sendTouch(action: AndroidMotionAction, x: Int32, y: Int32) {
        let payload = ScrcpyControlEncoder.encodeTouch(
            action: action,
            x: x,
            y: y,
            screenWidth: UInt16(max(1, Int(videoSize.width))),
            screenHeight: UInt16(max(1, Int(videoSize.height)))
        )
        sendControl(payload)
    }

    public func sendScroll(x: Int32, y: Int32, hScroll: Int16, vScroll: Int16) {
        let payload = ScrcpyControlEncoder.encodeScroll(
            x: x,
            y: y,
            screenWidth: UInt16(max(1, Int(videoSize.width))),
            screenHeight: UInt16(max(1, Int(videoSize.height))),
            hScroll: hScroll,
            vScroll: vScroll
        )
        sendControl(payload)
    }

    public func sendKeyEvent(action: AndroidKeyAction, keycode: UInt32, metaState: AndroidMetaState = []) {
        sendControl(ScrcpyControlEncoder.encodeKeycode(action: action, keycode: keycode, metaState: metaState.rawValue))
    }

    public func sendKeyTap(_ keycode: AndroidKeyCode, metaState: AndroidMetaState = []) {
        if desktopMode && keycode == .appSwitch && metaState.isEmpty {
            let metaLeft: UInt32 = 117 // KEYCODE_META_LEFT
            let tabKey: UInt32 = 61    // KEYCODE_TAB
            let meta: UInt32 = AndroidMetaState([.metaOn, .metaLeftOn]).rawValue
            sendControl(ScrcpyControlEncoder.encodeKeycode(action: .down, keycode: metaLeft, metaState: meta))
            sendControl(ScrcpyControlEncoder.encodeKeycode(action: .down, keycode: tabKey, metaState: meta))
            sendControl(ScrcpyControlEncoder.encodeKeycode(action: .up, keycode: tabKey, metaState: meta))
            sendControl(ScrcpyControlEncoder.encodeKeycode(action: .up, keycode: metaLeft, metaState: 0))
            return
        }
        sendControl(ScrcpyControlEncoder.encodeKeycode(action: .down, keycode: keycode.rawValue, metaState: metaState.rawValue))
        sendControl(ScrcpyControlEncoder.encodeKeycode(action: .up, keycode: keycode.rawValue, metaState: metaState.rawValue))
    }

    public func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        sendControl(ScrcpyControlEncoder.encodeText(text))
    }

    public func pasteFromMacClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        clipboardSequence &+= 1
        sendControl(ScrcpyControlEncoder.encodeSetClipboard(sequence: clipboardSequence, text: text, paste: true))
    }

    public func pushDroppedFiles(_ urls: [URL]) {
        guard let transport else { return }
        Task {
            for url in urls {
                let filename = url.lastPathComponent
                let isAPK = url.pathExtension.lowercased() == "apk"
                let remotePath = isAPK ? "/data/local/tmp/\(filename)" : "/sdcard/Download/\(filename)"
                transferStatus = isAPK ? "Installing \(filename)…" : "Sending \(filename)…"
                do {
                    let data = try Data(contentsOf: url)
                    try await transport.pushFile(data: data, remotePath: remotePath)
                    if isAPK {
                        let stream = try await transport.openStream(destination: "shell:pm install -r \"\(remotePath)\" && rm -f \"\(remotePath)\"")
                        _ = try? await stream.readExact(4)
                        await stream.close()
                        transferStatus = "Installed \(filename)"
                    } else {
                        transferStatus = "Saved to Downloads: \(filename)"
                    }
                } catch {
                    transferStatus = "Transfer failed: \(error.localizedDescription)"
                }
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            transferStatus = nil
        }
    }

    private func sendControl(_ data: Data) {
        guard let controlStream else { return }
        Task { try? await controlStream.write(data) }
    }

    private func queryPhoneLogicalSize(transport: ADBTCPTransport, streamSize: CGSize) async -> CGSize? {
        guard let stream = try? await transport.openStream(destination: "shell:wm size; wm density") else {
            return nil
        }
        let output = await stream.readToEnd(maxBytes: 4096)
        await stream.close()
        guard let text = String(data: output, encoding: .utf8) else { return nil }

        // Prefer Override values over Physical values when present.
        var physSize: (Double, Double)?
        var overSize: (Double, Double)?
        var physDensity: Double?
        var overDensity: Double?

        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Physical size:") || s.hasPrefix("Override size:") {
                let parts = s.split(separator: ":").last?.trimmingCharacters(in: .whitespaces).split(separator: "x") ?? []
                if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 {
                    if s.hasPrefix("Override") { overSize = (w, h) } else { physSize = (w, h) }
                }
            } else if s.hasPrefix("Physical density:") || s.hasPrefix("Override density:") {
                if let valStr = s.split(separator: ":").last?.trimmingCharacters(in: .whitespaces),
                   let d = Double(valStr), d > 0 {
                    if s.hasPrefix("Override") { overDensity = d } else { physDensity = d }
                }
            }
        }

        guard let (rawW, rawH) = overSize ?? physSize,
              let density = overDensity ?? physDensity else {
            return nil
        }
        let pixelRatio = density / 160.0
        var dpW = rawW / pixelRatio
        var dpH = rawH / pixelRatio
        // Match the current stream orientation (portrait vs landscape).
        let streamLandscape = streamSize.width > streamSize.height
        let dpLandscape = dpW > dpH
        if streamLandscape != dpLandscape {
            swap(&dpW, &dpH)
        }
        return CGSize(width: dpW, height: dpH)
    }

    private func readAudioLoop(stream: ADBStream) async {
        do {
            // Audio stream starts with 4-byte codec ID (0 = disabled by device).
            let codecData = try await stream.readExact(4)
            let codecID = codecData.readBigEndianUInt32(at: 0)
            guard codecID != 0 && codecID != 1 else { return }

            while !Task.isCancelled {
                let headerData = try await stream.readExact(12)
                guard let header = ScrcpyFrameHeader.parse(from: headerData) else { break }
                let packet = try await stream.readExact(Int(header.packetSize))
                if !header.isConfig {
                    audioPlayer.enqueuePCM16(packet)
                }
            }
        } catch {
            // Audio stream ending is non-fatal for video.
        }
    }

    private func readControlLoop(stream: ADBStream) async {
        do {
            while !Task.isCancelled {
                let typeByte = try await stream.readExact(1)[0]
                switch typeByte {
                case 0: // DEVICE_MSG_TYPE_CLIPBOARD: [length:4][utf8]
                    let lenData = try await stream.readExact(4)
                    let length = Int(lenData.readBigEndianUInt32(at: 0))
                    guard length >= 0 && length < 1_000_000 else { break }
                    let textData = length > 0 ? try await stream.readExact(length) : Data()
                    if let text = String(data: textData, encoding: .utf8) {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(text, forType: .string)
                    }
                case 1: // DEVICE_MSG_TYPE_ACK_CLIPBOARD: [sequence:8]
                    _ = try await stream.readExact(8)
                case 2: // DEVICE_MSG_TYPE_UHID_OUTPUT: [id:2][size:2][data]
                    let hdr = try await stream.readExact(4)
                    let size = (Int(hdr[2]) << 8) | Int(hdr[3])
                    if size > 0 { _ = try await stream.readExact(size) }
                default:
                    break
                }
            }
        } catch {
            // Control read loop ends on disconnect.
        }
    }

    private func readVideoLoop(stream: ADBStream) async {
        do {
            while !Task.isCancelled {
                let headerData = try await stream.readExact(12)
                guard let header = ScrcpyFrameHeader.parse(from: headerData) else { break }
                let packet = try await stream.readExact(Int(header.packetSize))
                if let sampleBuffer = sampleBuilder.buildSampleBuffer(
                    from: packet,
                    ptsMicroseconds: header.pts,
                    isConfig: header.isConfig
                ) {
                    onSampleBuffer?(sampleBuffer)
                }
            }
        } catch {
            if !Task.isCancelled {
                state = .error("Stream ended: \(error.localizedDescription)")
            }
        }
    }

    private func cleanupResources() async {
        if let s = videoStream { await s.close() }
        videoStream = nil
        if let s = audioStream { await s.close() }
        audioStream = nil
        if let s = controlStream { await s.close() }
        controlStream = nil
        if let s = shellStream { await s.close() }
        shellStream = nil
        if let t = transport { await t.disconnect() }
        transport = nil
    }
}
