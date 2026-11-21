import AVFoundation
import Foundation

/// Low-latency 48kHz stereo 16-bit PCM player for scrcpy `audio_codec=raw`.
final class RawAudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private let lock = NSLock()
    private var isStarted = false
    private var muted = false

    init() {
        // scrcpy raw audio is 48000 Hz, 2 channels, signed 16-bit little-endian interleaved PCM.
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        )!
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        do {
            try engine.start()
            playerNode.play()
            isStarted = true
        } catch {
            // Audio is best-effort; don't fail video streaming if audio device is unavailable.
        }
    }

    func setMuted(_ mute: Bool) {
        lock.lock()
        muted = mute
        playerNode.volume = mute ? 0.0 : 1.0
        lock.unlock()
    }

    func enqueuePCM16(_ data: Data) {
        let frameCount = data.count / 4 // 2 channels * 2 bytes (Int16)
        guard frameCount > 0 else { return }
        lock.lock()
        let active = isStarted
        let isMuted = muted
        lock.unlock()
        guard active, !isMuted else { return }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let left = buffer.floatChannelData?[0],
              let right = buffer.floatChannelData?[1] else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)

        data.withUnsafeBytes { raw in
            guard let samples = raw.bindMemory(to: Int16.self).baseAddress else { return }
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frameCount {
                left[i] = Float(Int16(littleEndian: samples[i * 2])) * scale
                right[i] = Float(Int16(littleEndian: samples[i * 2 + 1])) * scale
            }
        }

        playerNode.scheduleBuffer(buffer)
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isStarted else { return }
        playerNode.stop()
        engine.stop()
        isStarted = false
    }
}
