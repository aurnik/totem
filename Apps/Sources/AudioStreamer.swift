import AVFoundation
import TotemKit

/// Live voice for open chats: captures the mic as wire-format PCM chunks
/// (16 kHz mono Int16) and plays incoming chunks through one player node per
/// remote speaker. A single AVAudioEngine handles both directions; voice
/// processing (echo cancellation) is enabled while the mic is live so nearby
/// devices don't feed back into each other.
@MainActor
final class AudioStreamer {
    private let engine = AVAudioEngine()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var micLive = false

    private static let wireFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: AudioWire.sampleRate,
        channels: 1, interleaved: true)!
    private static let playbackFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioWire.sampleRate,
        channels: 1, interleaved: false)!

    // MARK: - Capture

    /// Requests permission, taps the mic, and emits wire-format chunks on an
    /// audio thread. Returns false if permission was denied or the engine
    /// couldn't start.
    func startMic(onChunk: @escaping @Sendable (Data) -> Void) async -> Bool {
        guard await Self.requestMicPermission() else { return false }
        guard !micLive else { return true }

        configureSession(record: true)
        let input = engine.inputNode
        if !input.isVoiceProcessingEnabled {
            if engine.isRunning { engine.stop() }
            try? input.setVoiceProcessingEnabled(true)
        }
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: tapFormat, to: Self.wireFormat)
        else { return false }

        input.installTap(onBus: 0, bufferSize: 2048, format: tapFormat) { buffer, _ in
            // Audio thread: resample to the wire format and hand off. The
            // converter is stateful (resampler carry-over) but only ever
            // touched from this serial tap.
            let ratio = AudioWire.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
            guard let out = AVAudioPCMBuffer(pcmFormat: Self.wireFormat, frameCapacity: capacity)
            else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, out.frameLength > 0, let channel = out.int16ChannelData
            else { return }
            onChunk(Data(bytes: channel[0], count: Int(out.frameLength) * 2))
        }

        micLive = true
        guard startEngine() else {
            stopMic()
            return false
        }
        return true
    }

    func stopMic() {
        guard micLive else { return }
        micLive = false
        engine.inputNode.removeTap(onBus: 0)
        stopEngineIfIdle()
    }

    // MARK: - Playback

    func play(_ chunk: Data, from senderID: UUID) {
        let frames = AVAudioFrameCount(chunk.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat, frameCapacity: frames)
        else { return }
        buffer.frameLength = frames
        chunk.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                out[i] = Float(samples[i]) / 32_768
            }
        }
        guard let player = playerNode(for: senderID) else { return }
        player.scheduleBuffer(buffer)
    }

    /// The speaker went quiet (or their chat closed) — drop their node.
    func stopSpeaker(_ senderID: UUID) {
        guard let player = players.removeValue(forKey: senderID) else { return }
        player.stop()
        engine.detach(player)
        stopEngineIfIdle()
    }

    func stopAll() {
        stopMic()
        for id in Array(players.keys) {
            stopSpeaker(id)
        }
    }

    private func playerNode(for senderID: UUID) -> AVAudioPlayerNode? {
        if let existing = players[senderID] { return existing }
        if !engine.isRunning {
            configureSession(record: micLive)
        }
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: Self.playbackFormat)
        players[senderID] = node
        guard startEngine() else {
            players[senderID] = nil
            engine.detach(node)
            return nil
        }
        node.play()
        return node
    }

    // MARK: - Engine & session

    private func startEngine() -> Bool {
        guard !engine.isRunning else { return true }
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            print("audio engine failed to start: \(error)")
            return false
        }
    }

    private func stopEngineIfIdle() {
        if !micLive && players.isEmpty && engine.isRunning {
            engine.stop()
        }
    }

    private func configureSession(record: Bool) {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if record {
            try? session.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try? session.setCategory(.playback, mode: .default)
        }
        try? session.setActive(true)
        #endif
    }

    private static func requestMicPermission() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
