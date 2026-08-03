import AVFoundation
import TotemKit

/// Live voice for open chats: captures the mic as wire-format PCM chunks
/// (16 kHz mono Int16) and plays incoming chunks through one player node per
/// remote speaker.
///
/// iOS: capture and playback share ONE engine with the voice-processing IO
/// unit enabled — echo cancellation only works against audio the same unit
/// renders, so a split graph lets the peer's speaker output loop back through
/// their mic uncancelled. The session category is `.playAndRecord` from the
/// start so touching `inputNode` (which wires it in permanently) never
/// conflicts with a play-only category.
///
/// macOS: separate engines, no `setVoiceProcessingEnabled` — the VP unit
/// there has a habit of delivering silent input buffers; headphones are the
/// answer.
@MainActor
final class AudioStreamer {
    private let playbackEngine: AVAudioEngine
    private let captureEngine: AVAudioEngine
    /// Player nodes are pooled per sender and NEVER detached — removing a
    /// node from a live voice-processing graph asserts inside AVAudioEngine
    /// (SIGABRT in RemoveNode, seen on TestFlight). Quiet speakers just stop.
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var activeSpeakers: Set<UUID> = []
    private var micLive = false
    /// Last session/engine failure — playback problems are otherwise
    /// invisible (the meters run off the raw chunks, not the engine).
    private var lastError: String?
    /// Fires on system output-volume changes so the owner can re-evaluate
    /// `outputMuted` (the crossed-out-speaker signal to chat peers).
    var onOutputVolumeChange: (@MainActor () -> Void)?
    #if os(iOS)
    private var volumeObservation: NSKeyValueObservation?
    #endif

    init() {
        #if os(iOS)
        let shared = AVAudioEngine()
        playbackEngine = shared
        captureEngine = shared
        // The session category must be record-capable BEFORE the
        // voice-processing unit is instantiated — under the launch-default
        // category enabling can fail, and it must happen before the engine
        // ever starts. Setting the category alone doesn't activate the
        // session, so other apps' audio isn't interrupted at launch.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try shared.inputNode.setVoiceProcessingEnabled(true)
        } catch {
            lastError = "voice processing: \(error.localizedDescription)"
            print("voice processing setup failed: \(error)")
        }
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            Task { @MainActor in self?.onOutputVolumeChange?() }
        }
        #else
        playbackEngine = AVAudioEngine()
        captureEngine = AVAudioEngine()
        #endif
    }

    /// True when the device can't render incoming voice: hardware volume at
    /// zero. The ring/silent switch is irrelevant — the `.playback` /
    /// `.playAndRecord` categories play through it.
    var outputMuted: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputVolume == 0
        #else
        false
        #endif
    }

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

        configureSession()
        let input = captureEngine.inputNode
        let tapFormat = input.outputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: tapFormat, to: Self.wireFormat)
        else { return false }
        let normalizer = AudioNormalizer()

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
            normalizer.normalize(channel[0], frames: Int(out.frameLength))
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
        #if os(iOS)
        // Shared engine: keep it alive if playback still needs it.
        if activeSpeakers.isEmpty { captureEngine.stop() }
        #else
        captureEngine.stop()
        #endif
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

    /// The speaker went quiet (or their chat closed) — halt their node.
    func stopSpeaker(_ senderID: UUID) {
        activeSpeakers.remove(senderID)
        players[senderID]?.stop()
        stopEngineIfIdle()
    }

    func stopAll() {
        stopMic()
        for id in Array(players.keys) {
            stopSpeaker(id)
        }
    }

    private func playerNode(for senderID: UUID) -> AVAudioPlayerNode? {
        if !playbackEngine.isRunning {
            configureSession()
        }
        let node: AVAudioPlayerNode
        if let existing = players[senderID] {
            node = existing
        } else {
            node = AVAudioPlayerNode()
            playbackEngine.attach(node)
            playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: Self.playbackFormat)
            players[senderID] = node
        }
        guard startPlaybackEngine() else { return nil }
        if !node.isPlaying { node.play() }
        activeSpeakers.insert(senderID)
        return node
    }

    private func stopEngineIfIdle() {
        #if os(iOS)
        if activeSpeakers.isEmpty && !micLive { playbackEngine.stop() }
        #else
        if activeSpeakers.isEmpty { playbackEngine.stop() }
        #endif
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

    // MARK: - Session

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            // .voiceChat prefers the quiet receiver up top; voice chat
            // belongs on the loudspeaker.
            try session.overrideOutputAudioPort(.speaker)
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

/// Smoothed automatic gain riding on the capture tap: nudges chunk loudness
/// toward a target peak so quiet and loud mics arrive at comparable levels.
/// Attack (gain down) is fast to dodge clipping; release (gain up) is slow to
/// avoid pumping. Like the converter, state is only touched from the serial
/// tap, never concurrently.
private final class AudioNormalizer {
    private var gain: Float = 1
    private static let targetPeak: Float = 0.7
    /// Below this peak the chunk is treated as silence/noise — gain holds
    /// rather than winding up to amplify the noise floor.
    private static let noiseFloor: Float = 0.02
    private static let maxGain: Float = 8

    func normalize(_ samples: UnsafeMutablePointer<Int16>, frames: Int) {
        var peak: Float = 0
        for i in 0..<frames {
            peak = max(peak, abs(Float(samples[i])) / 32_768)
        }
        if peak >= Self.noiseFloor {
            let desired = min(Self.targetPeak / peak, Self.maxGain)
            gain += (desired - gain) * (desired < gain ? 0.5 : 0.05)
        }
        // Hard ceiling regardless of smoothing: never let this chunk clip.
        if peak * gain > 1 { gain = 1 / peak }
        guard abs(gain - 1) > 0.01 else { return }
        for i in 0..<frames {
            samples[i] = Int16(max(-32_768, min(32_767, Float(samples[i]) * gain)))
        }
    }
}
