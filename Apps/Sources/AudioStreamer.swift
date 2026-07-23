import AVFoundation
import TotemKit

/// Live voice for open chats: captures the mic as wire-format PCM chunks
/// (16 kHz mono Int16) and plays incoming chunks through one player node per
/// remote speaker.
///
/// Capture and playback use separate engines: touching `inputNode` wires the
/// input into an engine's graph permanently, and starting such an engine
/// under a play-only session category fails with CoreAudio 'what'
/// (2003329396). Keeping playback input-free avoids the whole class.
///
/// Deliberately no `setVoiceProcessingEnabled`: on macOS the voice-processing
/// IO unit has a habit of delivering silent input buffers. iOS gets echo
/// cancellation from the `.voiceChat` session mode instead; on macOS,
/// headphones are the answer.
@MainActor
final class AudioStreamer {
    private let playbackEngine = AVAudioEngine()
    private let captureEngine = AVAudioEngine()
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var micLive = false
    /// Once the mic has ever been used, the iOS session category stays
    /// `.playAndRecord` — flipping categories mid-flight kills running
    /// engines out from under us.
    private var everRecorded = false
    /// Last session/engine failure — playback problems are otherwise
    /// invisible (the meters run off the raw chunks, not the engine).
    private var lastError: String?

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

        let firstRecording = !everRecorded
        everRecorded = true
        configureSession()
        // The first mic use flips the session category, which can stop a
        // running playback engine out from under its player nodes.
        if firstRecording { restartPlayback() }

        let input = captureEngine.inputNode
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
        captureEngine.prepare()
        do {
            try captureEngine.start()
        } catch {
            lastError = "capture: \(error.localizedDescription)"
            print("capture engine failed to start: \(error)")
            stopMic()
            return false
        }
        return true
    }

    func stopMic() {
        guard micLive else { return }
        micLive = false
        captureEngine.inputNode.removeTap(onBus: 0)
        captureEngine.stop()
    }

    // MARK: - Playback

    /// Returns nil on success, else a short description of why nothing will
    /// be heard, so the caller can surface it.
    func play(_ chunk: Data, from senderID: UUID) -> String? {
        let frames = AVAudioFrameCount(chunk.count / 2)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: Self.playbackFormat, frameCapacity: frames)
        else { return "bad chunk" }
        buffer.frameLength = frames
        chunk.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<Int(frames) {
                out[i] = Float(samples[i]) / 32_768
            }
        }
        guard let player = playerNode(for: senderID) else {
            return lastError ?? "audio engine failed"
        }
        player.scheduleBuffer(buffer)
        return nil
    }

    /// The speaker went quiet (or their chat closed) — drop their node.
    func stopSpeaker(_ senderID: UUID) {
        guard let player = players.removeValue(forKey: senderID) else { return }
        player.stop()
        playbackEngine.detach(player)
        if players.isEmpty {
            playbackEngine.stop()
        }
    }

    func stopAll() {
        stopMic()
        for id in Array(players.keys) {
            stopSpeaker(id)
        }
    }

    private func playerNode(for senderID: UUID) -> AVAudioPlayerNode? {
        if let existing = players[senderID] { return existing }
        if !playbackEngine.isRunning {
            configureSession()
        }
        let node = AVAudioPlayerNode()
        playbackEngine.attach(node)
        playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: Self.playbackFormat)
        players[senderID] = node
        guard startPlaybackEngine() else {
            players[senderID] = nil
            playbackEngine.detach(node)
            return nil
        }
        node.play()
        return node
    }

    private func startPlaybackEngine() -> Bool {
        guard !playbackEngine.isRunning else { return true }
        playbackEngine.prepare()
        do {
            try playbackEngine.start()
            lastError = nil
            return true
        } catch {
            lastError = "engine: \(error.localizedDescription)"
            print("playback engine failed to start: \(error)")
            return false
        }
    }

    private func restartPlayback() {
        guard !players.isEmpty else { return }
        playbackEngine.stop()
        if startPlaybackEngine() {
            players.values.forEach { $0.play() }
        }
    }

    // MARK: - Session

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            if everRecorded {
                try session.setCategory(
                    .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try session.setCategory(.playback, mode: .default)
            }
            try session.setActive(true)
        } catch {
            lastError = "audio session: \(error.localizedDescription)"
            print("audio session configuration failed: \(error)")
        }
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
