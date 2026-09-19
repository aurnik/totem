import AVFoundation

/// Live voice for open chats: captures the mic as 20 ms Opus packets and plays
/// incoming packets through one decoder and player node per remote speaker.
///
/// iOS runs capture and playback on one engine with voice processing enabled,
/// since echo cancellation only covers audio the same IO unit renders. The
/// input node is not touched until the mic is first opened, because reaching
/// for it is what raises the microphone permission prompt. macOS uses separate
/// engines without voice processing.
@MainActor
final class AudioStreamer {
    nonisolated static let sampleRate: Double = 48_000
    /// 20 ms at 48 kHz: Opus's native frame, and one QUIC datagram.
    nonisolated static let frameSamples: AVAudioFrameCount = 960
    nonisolated static let frameDuration: Duration = .milliseconds(20)
    nonisolated static let bitrate = 32_000

    enum Playback {
        case heard(spectrum: [Float])
        case silent(reason: String)
    }

    private let playbackEngine: AVAudioEngine
    private let captureEngine: AVAudioEngine
    /// Player nodes are pooled per sender and never detached: removing a node
    /// from a live voice-processing graph asserts inside AVAudioEngine.
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var decoders: [UUID: OpusCodec] = [:]
    private var jitterBuffers: [UUID: JitterBuffer] = [:]
    private var activeSpeakers: Set<UUID> = []
    private var micLive = false
    private var pacer: PacketPacer?
    /// Kept so the tap can be rebuilt on a device change.
    private var captureSinks: (packet: (@Sendable (Data, [Float]) -> Void)?,
                               buffer: (@Sendable (AVAudioPCMBuffer) -> Void)?)?
    private var configurationObservers: [NSObjectProtocol] = []
    private var lastError: String?
    /// Fires on system output-volume changes so the owner can re-evaluate `outputMuted`.
    var onOutputVolumeChange: (@MainActor () -> Void)?
    #if os(iOS)
    private var volumeObservation: NSKeyValueObservation?
    private var captureReady = false
    #endif

    init() {
        #if os(iOS)
        let shared = AVAudioEngine()
        playbackEngine = shared
        captureEngine = shared
        volumeObservation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] _, _ in
            Task { @MainActor in self?.onOutputVolumeChange?() }
        }
        #else
        playbackEngine = AVAudioEngine()
        captureEngine = AVAudioEngine()
        #endif
        // A device change stops the engine and changes the input format;
        // nothing resumes on its own.
        let engines = playbackEngine === captureEngine ? [playbackEngine] : [playbackEngine, captureEngine]
        for engine in engines {
            configurationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.recoverFromConfigurationChange() }
            })
        }
    }

    /// True when hardware volume is at zero. The ring/silent switch does not
    /// affect the playback categories used here.
    var outputMuted: Bool {
        #if os(iOS)
        AVAudioSession.sharedInstance().outputVolume == 0
        #else
        false
        #endif
    }

    // MARK: - Capture

    /// Requests permission and taps the mic, emitting Opus packets (with a
    /// spectrum of each) and/or raw buffers for transcription, both on an audio
    /// thread. Calling this while live reinstalls the tap with the new sinks.
    func startMic(onPacket: (@Sendable (Data, [Float]) -> Void)? = nil,
                  onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async -> Bool {
        guard await Self.requestMicPermission() else {
            Log.audio.notice("mic permission denied")
            return false
        }

        prepareForCapture()
        configureSession()
        if micLive { captureEngine.inputNode.removeTap(onBus: 0) }
        captureSinks = (onPacket, onBuffer)
        guard installCapture(onPacket: onPacket, onBuffer: onBuffer) else { return false }
        micLive = true
        return startCaptureEngine()
    }

    /// Taps the node's input format: after a device change the output format
    /// still reports the old device's rate and a tap in it is rejected.
    private func installCapture(onPacket: (@Sendable (Data, [Float]) -> Void)?,
                                onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) -> Bool {
        let input = captureEngine.inputNode
        let tapFormat = input.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              let resampler = AVAudioConverter(from: tapFormat, to: OpusCodec.pcmFormat),
              let encoder = try? OpusCodec()
        else {
            Log.audio.error("mic unusable: \(tapFormat), \(self.lastError ?? "no session error")")
            return false
        }
        let framer = FrameAssembler()
        let pacer = PacketPacer()
        self.pacer?.stop()
        self.pacer = onPacket.map { sink in
            pacer.start { packet, spectrum in sink(packet, spectrum) }
            return pacer
        }

        input.installTap(onBus: 0, bufferSize: Self.frameSamples, format: tapFormat) { buffer, _ in
            onBuffer?(buffer)
            guard let onPacket,
                  let resampled = resampler.resample(buffer, into: OpusCodec.pcmFormat)
            else { return }
            framer.append(resampled)
            // A tap delivers about 100 ms at a time; the pacer spaces the
            // resulting packets one frame interval apart.
            while let frame = framer.nextFrame() {
                let spectrum = AudioAnalyzer.spectrum(of: frame)
                guard let packet = try? encoder.encode(frame) else { continue }
                pacer.enqueue(packet, spectrum)
            }
        }
        return true
    }

    private func startCaptureEngine() -> Bool {
        captureEngine.prepare()
        do {
            try captureEngine.start()
        } catch {
            lastError = "capture: \(error.localizedDescription)"
            Log.audio.error("capture engine failed to start: \(error)")
            stopMic()
            return false
        }
        return true
    }

    private func recoverFromConfigurationChange() {
        if micLive, let sinks = captureSinks {
            captureEngine.inputNode.removeTap(onBus: 0)
            if installCapture(onPacket: sinks.packet, onBuffer: sinks.buffer) {
                _ = startCaptureEngine()
            } else {
                stopMic()
            }
        }
        if !activeSpeakers.isEmpty, startPlaybackEngine() {
            for id in activeSpeakers {
                players[id]?.play()
            }
        }
    }

    func stopMic() {
        guard micLive else { return }
        micLive = false
        pacer?.stop()
        pacer = nil
        captureSinks = nil
        captureEngine.inputNode.removeTap(onBus: 0)
        #if os(iOS)
        if activeSpeakers.isEmpty { captureEngine.stop() }
        #else
        captureEngine.stop()
        #endif
    }

    // MARK: - Playback

    /// Decodes every packet so the meters keep moving; `audible` decides
    /// whether it also reaches the speaker.
    func play(_ packet: Data, from senderID: UUID, audible: Bool = true) -> Playback {
        let decoder: OpusCodec
        if let existing = decoders[senderID] {
            decoder = existing
        } else {
            guard let fresh = try? OpusCodec() else { return .silent(reason: "no Opus decoder") }
            decoders[senderID] = fresh
            decoder = fresh
        }
        guard let buffer = try? decoder.decode(packet) else { return .silent(reason: "bad packet") }
        let spectrum = AudioAnalyzer.spectrum(of: buffer)
        guard audible else { return .heard(spectrum: spectrum) }
        guard let player = playerNode(for: senderID) else {
            return .silent(reason: lastError ?? "audio engine failed")
        }
        let jitter = jitterBuffers[senderID] ?? JitterBuffer()
        jitterBuffers[senderID] = jitter
        for ready in jitter.admit(buffer) {
            player.scheduleBuffer(ready, at: nil, options: [],
                                  completionCallbackType: .dataPlayedBack) { _ in jitter.played() }
        }
        return .heard(spectrum: spectrum)
    }

    func stopSpeaker(_ senderID: UUID) {
        activeSpeakers.remove(senderID)
        players[senderID]?.stop()
        decoders[senderID] = nil
        jitterBuffers[senderID] = nil
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
            playbackEngine.connect(node, to: playbackEngine.mainMixerNode, format: OpusCodec.pcmFormat)
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
            Log.audio.error("playback engine failed to start: \(error)")
            return false
        }
    }

    // MARK: - Session

    /// Enables the voice-processing IO unit once, before the engine first
    /// captures. The category must be record-capable and the engine stopped.
    private func prepareForCapture() {
        #if os(iOS)
        guard !captureReady else { return }
        captureEngine.stop()
        do {
            try AVAudioSession.sharedInstance().setVoiceChatCategory()
            try captureEngine.inputNode.setVoiceProcessingEnabled(true)
            captureReady = true
        } catch {
            lastError = "voice processing: \(error.localizedDescription)"
            Log.audio.error("voice processing setup failed: \(error)")
        }
        #endif
    }

    private func configureSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        do {
            guard captureReady else {
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                return
            }
            try session.setVoiceChatCategory()
            try session.setActive(true)
            try session.overrideOutputAudioPort(.speaker)
        } catch {
            lastError = "audio session: \(error.localizedDescription)"
            Log.audio.error("audio session configuration failed: \(error)")
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

#if os(iOS)
private extension AVAudioSession {
    /// Duplex, echo-cancelling, on the loudspeaker, with the IO buffer matched
    /// to the codec frame so packets leave one at a time.
    func setVoiceChatCategory() throws {
        try setCategory(.playAndRecord, mode: .voiceChat,
                        options: [.defaultToSpeaker, .allowBluetooth])
        try setPreferredIOBufferDuration(Double(AudioStreamer.frameSamples) / AudioStreamer.sampleRate)
    }
}
#endif
