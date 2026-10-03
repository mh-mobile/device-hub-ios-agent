import AVFoundation
import Foundation
import OSLog

/// Plays the device's screen-sharing audio on the controller.
///
/// Each payload is one raw AAC-ELD access unit; the AudioSpecificConfig below
/// (AAC-ELD, 44.1 kHz, stereo, 480-sample frames) is what the device sends for
/// the CoreDeviceScreenSharing audio offer.
final class DeviceHubAudioPlayer: @unchecked Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "DeviceHub",
        category: "audio"
    )
    private static let audioSpecificConfig = Data([0xF8, 0xE8, 0x50, 0x00])
    /// Frames queued but not yet played, in 480-sample (~11 ms) buffers. Audio
    /// shares the TCP tunnel with video, so it stalls and then arrives in bursts
    /// of up to ~1 s; past this cap (~400 ms) the newest audio is dropped so
    /// latency cannot build up. A balance between delay and dropouts.
    private static let maximumQueuedBuffers = 36
    /// After running dry, wait for this many buffers (~150 ms) before resuming, so
    /// a stall becomes one short gap instead of constant stutter.
    private static let resumeThreshold = 14

    private let queue = DispatchQueue(label: "DeviceHub.audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private var packets = 0
    private var lastWasSilent: Bool?
    private var queuedBuffers = 0
    private var held: [AVAudioPCMBuffer] = []

    init?() {
        var description = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatMPEG4AAC_ELD,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: 480,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard
            let compressedFormat = AVAudioFormat(streamDescription: &description),
            let pcmFormat = AVAudioFormat(
                standardFormatWithSampleRate: 44100,
                channels: 2
            ),
            let converter = AVAudioConverter(from: compressedFormat, to: pcmFormat)
        else {
            Self.logger.error("AAC-ELD converter unavailable")
            return nil
        }
        converter.magicCookie = Self.audioSpecificConfig
        self.compressedFormat = compressedFormat
        self.pcmFormat = pcmFormat
        self.converter = converter

        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: pcmFormat)
            try engine.start()
            player.play()
        } catch {
            Self.logger.error("Audio engine failed to start")
            return nil
        }
    }

    deinit {
        player.stop()
        engine.stop()
    }

    /// Copies the payload; decoding and scheduling happen off the caller's thread.
    func enqueue(_ payload: Data) {
        queue.async { [self] in
            decodeAndSchedule(payload)
        }
    }

    private func decodeAndSchedule(_ payload: Data) {
        let input = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: 1,
            maximumPacketSize: payload.count
        )
        payload.withUnsafeBytes { bytes in
            input.data.copyMemory(from: bytes.baseAddress!, byteCount: payload.count)
        }
        input.byteLength = UInt32(payload.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(payload.count)
        )

        guard let output = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024) else {
            return
        }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        packets += 1
        let silent = payload.count <= 4
        let changed = silent != lastWasSilent
        lastWasSilent = silent
        if changed || packets.isMultiple(of: 500) || status == .error {
            DeviceHubNativeTrace.emit(
                "audio packet=\(packets) bytes=\(payload.count) status=\(status.rawValue) "
                    + "frames=\(output.frameLength) error=\(error?.code ?? 0) "
                    + "engine=\(engine.isRunning) playing=\(player.isPlaying)"
            )
        }
        // Always decode (the decoder is stateful); only skip playing when behind.
        guard
            status != .error,
            output.frameLength > 0,
            queuedBuffers < Self.maximumQueuedBuffers
        else {
            if queuedBuffers >= Self.maximumQueuedBuffers {
                DeviceHubNativeTrace.emit("audio overflow_drop queued=\(queuedBuffers)")
            }
            return
        }
        if queuedBuffers == 0 {
            if held.isEmpty {
                DeviceHubNativeTrace.emit("audio underrun packet=\(packets)")
            }
            held.append(output)
            guard held.count >= Self.resumeThreshold else {
                return
            }
            held.forEach(schedule)
            held.removeAll()
        } else {
            schedule(output)
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer) {
        queuedBuffers += 1
        player.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            queue.async { self.queuedBuffers -= 1 }
        }
    }
}
