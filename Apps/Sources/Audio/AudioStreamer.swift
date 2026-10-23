import AVFoundation
import os

/// Live voice for open chats: captures the mic as 20 ms Opus packets and plays
/// incoming packets through one decoder and player node per remote speaker.
///
/// Everything runs on one serial audio queue, off the main actor, so a packet
/// never waits behind SwiftUI. The UI hears about speakers through `onMeters`,
/// a coalesced report every `meterInterval` rather than one hop per packet.
///
/// iOS runs capture and playback on one engine with voice processing enabled,
/// since echo cancellation only covers audio the same IO unit renders. The
/// input node is not touched until the mic is first opened, because reaching
/// for it is what raises the microphone permission prompt. macOS uses separate
/// engines without voice processing.
final class AudioStreamer: @unchecked Sendable {
    static let sampleRate: Double = 48_000
    /// 20 ms at 48 kHz: Opus's native frame, and one QUIC datagram.
    static let frameSamples: AVAudioFrameCount = 960
    static let frameDuration: Duration = .milliseconds(20)
    static let bitrate = 32_000
    /// How often the UI is told about meters and speakers.
    static let meterInterval: DispatchTimeInterval = .milliseconds(50)
    /// A speaker whose packets stop for this long is no longer speaking.
    static let speakerTimeout: TimeInterval = 1.2
    /// Longer runs of missing packets are a dropout, not jitter, and are not concealed.
    static let maxConcealedGap: UInt32 = 3

    /// One voice in one conversation. The local user appears as a speaker
    /// while their own mic is live, metered from the capture path.
    struct Speaker: Hashable, Sendable {
        let conversationID: UUID
        let userID: UUID
    }

    /// Levels for every speaker heard since the last report, and speakers
    /// whose packets stopped.
    struct MeterReport: Sendable {
        let levels: [Speaker: [Float]]
        let stopped: Set<Speaker>
    }

    var onMeters: (@MainActor (MeterReport) -> Void)?
    /// A packet that could not reach the speaker, with the reason.
    var onPlaybackFailure: (@MainActor (_ conversationID: UUID, _ reason: String) -> Void)?
    /// Fires on system output-volume changes so the owner can re-evaluate `outputMuted`.
    var onOutputVolumeChange: (@MainActor () -> Void)?

    private let queue = DispatchQueue(label: "voice.audio", qos: .userInteractive)
    private let playbackEngine: AVAudioEngine
    private let captureEngine: AVAudioEngine
    /// Player nodes are pooled per sender and never detached: removing a node
    /// from a live voice-processing graph asserts inside AVAudioEngine.
    private var players: [UUID: AVAudioPlayerNode] = [:]
    private var decoders: [UUID: OpusCodec] = [:]
    private var jitterBuffers: [UUID: JitterBuffer] = [:]
    private var lastSequence: [UUID: UInt32] = [:]
    private var activeSpeakers: Set<UUID> = []
    /// Who may be heard in each open conversation: the client's copy of the
    /// server's participant check, pushed here so no packet needs the main actor.
    private var allowedSenders: [UUID: Set<UUID>] = [:]
    private var localUserID: UUID?
    private var mutedConversations: Set<UUID> = []
    private var lastError: String?
    private var configurationObservers: [NSObjectProtocol] = []

    private var capture: Capture?
    private var sinkNode: AVAudioSinkNode?
    /// Read on the realtime thread: the format to copy mic buffers in, nil while the mic is off.
    private let captureFormat = OSAllocatedUnfairLock<AVAudioFormat?>(uncheckedState: nil)

    private var pendingLevels: [Speaker: [Float]] = [:]
    private var lastHeard: [Speaker: TimeInterval] = [:]
    private var meterTimer: DispatchSourceTimer?

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
        configurationObservers.append(NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            // The engine is stopped for the interruption and nothing restarts it.
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended
            else { return }
            self?.queue.async { self?.recoverFromConfigurationChange() }
        })
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
                self?.queue.async { self?.recoverFromConfigurationChange() }
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

    // MARK: - Who is heard

    /// The senders allowed per open conversation. Absolute: the whole map each time.
    func setAllowedSenders(_ senders: [UUID: Set<UUID>], localUserID: UUID?) {
        queue.async {
            self.allowedSenders = senders
            self.localUserID = localUserID
        }
    }

    /// A muted conversation's packets still drive the meters.
    func setMuted(_ muted: Bool, in conversationID: UUID) {
        queue.async {
            if muted {
                self.mutedConversations.insert(conversationID)
            } else {
                self.mutedConversations.remove(conversationID)
            }
        }
    }

    // MARK: - Capture

    /// Requests permission and opens the mic, emitting Opus packets and/or
    /// raw buffers for transcription, both on the audio queue. With a
    /// `monitor`, the mic's own levels are reported under that speaker.
    /// Calling this while live swaps the sinks.
    func startMic(onPacket: (@Sendable (Data) -> Void)? = nil,
                  onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil,
                  monitor: Speaker? = nil) async -> Bool {
        guard await Self.requestMicPermission() else {
            Log.audio.notice("mic permission denied")
            return false
        }
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.openMic(onPacket: onPacket, onBuffer: onBuffer, monitor: monitor))
            }
        }
    }

    private func openMic(onPacket: (@Sendable (Data) -> Void)?,
                         onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
                         monitor: Speaker?) -> Bool {
        prepareForCapture()
        configureSession()
        if let monitor = capture?.monitor { forgetSpeaker(monitor) }
        guard let chain = makeCapture(onPacket: onPacket, onBuffer: onBuffer, monitor: monitor) else {
            Log.audio.error("mic unusable: \(self.captureEngine.inputNode.inputFormat(forBus: 0)), \(self.lastError ?? "no session error")")
            return false
        }
        guard installSink(for: chain) else { return false }
        capture = chain
        captureFormat.withLockUnchecked { $0 = chain.format }
        return startCaptureEngine()
    }

    private func makeCapture(onPacket: (@Sendable (Data) -> Void)?,
                             onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?,
                             monitor: Speaker?) -> Capture? {
        Capture(input: captureEngine.inputNode, onPacket: onPacket, onBuffer: onBuffer,
                monitor: monitor, onLevel: monitor.map { speaker in
                    { [weak self] spectrum in self?.meter(speaker, spectrum) }
                })
    }

    /// One sink node for the life of the engine, reconnected in the node's
    /// input format whenever the device changes (after a change the output
    /// format still reports the old device's rate and is rejected). Its render
    /// block only copies the buffer off the realtime thread.
    private func installSink(for chain: Capture) -> Bool {
        let input = captureEngine.inputNode
        if sinkNode == nil {
            let node = AVAudioSinkNode { [weak self] _, frameCount, bufferList in
                guard let self, let format = self.captureFormat.withLockUnchecked({ $0 }),
                      let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
                else { return noErr }
                copy.frameLength = frameCount
                let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
                let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                for (from, to) in zip(source, target) where from.mData != nil && to.mData != nil {
                    to.mData!.copyMemory(from: from.mData!, byteCount: Int(min(from.mDataByteSize, to.mDataByteSize)))
                }
                self.queue.async { self.capture?.process(copy) }
                return noErr
            }
            captureEngine.attach(node)
            sinkNode = node
        }
        guard let sinkNode else { return false }
        captureEngine.connect(input, to: sinkNode, format: chain.format)
        return true
    }

    private func startCaptureEngine() -> Bool {
        do {
            try start(captureEngine)
        } catch {
            lastError = "capture: \(error.localizedDescription)"
            Log.audio.error("capture engine failed to start: \(error)")
            closeMic()
            return false
        }
        return true
    }

    private func recoverFromConfigurationChange() {
        if let live = capture {
            if let chain = makeCapture(onPacket: live.onPacket, onBuffer: live.onBuffer, monitor: live.monitor),
               installSink(for: chain) {
                capture = chain
                captureFormat.withLockUnchecked { $0 = chain.format }
                _ = startCaptureEngine()
            } else {
                closeMic()
            }
        }
        if !activeSpeakers.isEmpty, startPlaybackEngine() {
            for id in activeSpeakers {
                players[id]?.play()
            }
        }
    }

    func stopMic() {
        queue.async { self.closeMic() }
    }

    private func closeMic() {
        guard let live = capture else { return }
        captureFormat.withLockUnchecked { $0 = nil }
        capture = nil
        if let monitor = live.monitor { forgetSpeaker(monitor) }
        #if os(iOS)
        if activeSpeakers.isEmpty { captureEngine.stop() }
        #else
        captureEngine.stop()
        #endif
    }

    /// Mic buffers in, packets out. Built once per mic open and used only on
    /// the audio queue; the format is whatever the input node is delivering.
    private final class Capture {
        let format: AVAudioFormat
        let onPacket: (@Sendable (Data) -> Void)?
        let onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
        let monitor: Speaker?
        private let onLevel: (([Float]) -> Void)?
        private let resampler: AVAudioConverter
        private let encoder: OpusCodec
        private let framer = FrameAssembler()

        init?(input: AVAudioInputNode, onPacket: (@Sendable (Data) -> Void)?,
              onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?, monitor: Speaker?,
              onLevel: (([Float]) -> Void)?) {
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.commonFormat == .pcmFormatFloat32,
                  let resampler = AVAudioConverter(from: format, to: OpusCodec.pcmFormat),
                  let encoder = try? OpusCodec()
            else { return nil }
            self.format = format
            self.resampler = resampler
            self.encoder = encoder
            self.onPacket = onPacket
            self.onBuffer = onBuffer
            self.monitor = monitor
            self.onLevel = onLevel
        }

        func process(_ buffer: AVAudioPCMBuffer) {
            onBuffer?(buffer)
            guard onPacket != nil || onLevel != nil,
                  let resampled = resampler.resample(buffer, into: OpusCodec.pcmFormat)
            else { return }
            framer.append(resampled)
            while let frame = framer.nextFrame() {
                onLevel?(AudioAnalyzer.spectrum(of: frame))
                guard let onPacket, let packet = try? encoder.encode(frame) else { continue }
                onPacket(packet)
            }
        }
    }

    // MARK: - Playback

    /// One packet from a sender. Dropped unless the sender is allowed in the
    /// conversation; after that it is decoded for the meters either way, and
    /// played unless the conversation is muted. `sequence` is used to conceal
    /// short gaps; nil for a stream that has none.
    func receive(_ packet: Data, sequence: UInt32?, from senderID: UUID, in conversationID: UUID) {
        queue.async { self.handle(packet, sequence: sequence, from: senderID, in: conversationID) }
    }

    private func handle(_ packet: Data, sequence: UInt32?, from senderID: UUID, in conversationID: UUID) {
        guard let allowed = allowedSenders[conversationID],
              senderID == localUserID || allowed.contains(senderID)
        else { return }
        let decoder: OpusCodec
        if let existing = decoders[senderID] {
            decoder = existing
        } else {
            guard let fresh = try? OpusCodec() else {
                return playbackFailed(conversationID, senderID, reason: "no Opus decoder")
            }
            decoders[senderID] = fresh
            decoder = fresh
        }
        // Concealment frames must go through the decoder before the packet
        // that follows the gap, so its state lines up.
        var frames: [AVAudioPCMBuffer] = []
        if let sequence {
            if let last = lastSequence[senderID], sequence > last &+ 1,
               sequence &- last <= Self.maxConcealedGap + 1 {
                for _ in 0..<(sequence &- last &- 1) {
                    guard let concealed = try? decoder.conceal() else { break }
                    frames.append(concealed)
                }
            }
            lastSequence[senderID] = sequence
        }
        guard let buffer = try? decoder.decode(packet) else {
            return playbackFailed(conversationID, senderID, reason: "bad packet")
        }
        frames.append(buffer)
        meter(Speaker(conversationID: conversationID, userID: senderID), AudioAnalyzer.spectrum(of: buffer))
        guard !mutedConversations.contains(conversationID) else { return }
        guard let player = playerNode(for: senderID) else {
            return playbackFailed(conversationID, senderID, reason: lastError ?? "audio engine failed")
        }
        let jitter = jitterBuffers[senderID] ?? JitterBuffer()
        jitterBuffers[senderID] = jitter
        for frame in frames {
            for ready in jitter.admit(frame) {
                player.scheduleBuffer(ready, at: nil, options: [],
                                      completionCallbackType: .dataPlayedBack) { _ in jitter.played() }
            }
        }
    }

    private func playbackFailed(_ conversationID: UUID, _ senderID: UUID, reason: String) {
        meter(Speaker(conversationID: conversationID, userID: senderID),
              Array(repeating: 0, count: AudioAnalyzer.bandCount))
        guard let onPlaybackFailure else { return }
        Task { @MainActor in onPlaybackFailure(conversationID, reason) }
    }

    func stopSpeaker(_ senderID: UUID) {
        queue.async {
            self.releaseSpeaker(senderID)
            for speaker in self.lastHeard.keys where speaker.userID == senderID {
                self.forgetSpeaker(speaker)
            }
        }
    }

    private func releaseSpeaker(_ senderID: UUID) {
        activeSpeakers.remove(senderID)
        players[senderID]?.stop()
        decoders[senderID] = nil
        jitterBuffers[senderID] = nil
        lastSequence[senderID] = nil
        stopEngineIfIdle()
    }

    /// Everything down, and nobody allowed until the next sign-on says so.
    func stopAll() {
        queue.async {
            self.closeMic()
            for id in Array(self.players.keys) {
                self.releaseSpeaker(id)
            }
            self.allowedSenders = [:]
            self.mutedConversations = []
            self.pendingLevels = [:]
            self.lastHeard = [:]
            self.stopMeterTimerIfIdle()
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
        if activeSpeakers.isEmpty && capture == nil { playbackEngine.stop() }
        #else
        if activeSpeakers.isEmpty { playbackEngine.stop() }
        #endif
    }

    private func startPlaybackEngine() -> Bool {
        do {
            try start(playbackEngine)
            lastError = nil
            return true
        } catch {
            lastError = "engine: \(error.localizedDescription)"
            Log.audio.error("playback engine failed to start: \(error)")
            return false
        }
    }

    /// Every engine start goes through here. A node that was playing when
    /// its engine stopped still reports `isPlaying` after the restart but
    /// renders nothing, and `play()` alone does not revive it (measured: only
    /// `stop()` then `play()` does). Stopping the pool here lets the
    /// `isPlaying` checks re-arm each node on its next packet; the jitter
    /// buffers go too, since the stopped node's completions would otherwise
    /// count against the fresh queue.
    private func start(_ engine: AVAudioEngine) throws {
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
        guard engine === playbackEngine else { return }
        for node in players.values {
            node.stop()
        }
        jitterBuffers = [:]
    }

    // MARK: - Meters

    private func meter(_ speaker: Speaker, _ spectrum: [Float]) {
        pendingLevels[speaker] = spectrum
        lastHeard[speaker] = CFAbsoluteTimeGetCurrent()
        guard meterTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.meterInterval, repeating: Self.meterInterval)
        timer.setEventHandler { [weak self] in self?.flushMeters() }
        meterTimer = timer
        timer.activate()
    }

    /// One hop to the main actor for everyone heard since the last tick, and
    /// the speakers whose packets stopped, whose nodes are released here.
    private func flushMeters() {
        let now = CFAbsoluteTimeGetCurrent()
        var stopped: Set<Speaker> = []
        for (speaker, heard) in lastHeard where now - heard > Self.speakerTimeout {
            stopped.insert(speaker)
            lastHeard[speaker] = nil
            if speaker != capture?.monitor {
                releaseSpeaker(speaker.userID)
            }
        }
        let levels = pendingLevels
        pendingLevels = [:]
        stopMeterTimerIfIdle()
        guard !levels.isEmpty || !stopped.isEmpty, let onMeters else { return }
        let report = MeterReport(levels: levels, stopped: stopped)
        Task { @MainActor in onMeters(report) }
    }

    /// Drops a speaker without reporting it; the owner already knows.
    private func forgetSpeaker(_ speaker: Speaker) {
        pendingLevels[speaker] = nil
        lastHeard[speaker] = nil
        stopMeterTimerIfIdle()
    }

    private func stopMeterTimerIfIdle() {
        guard lastHeard.isEmpty, pendingLevels.isEmpty else { return }
        meterTimer?.cancel()
        meterTimer = nil
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
    /// to the codec frame so the sink node hands over one frame at a time.
    func setVoiceChatCategory() throws {
        try setCategory(.playAndRecord, mode: .voiceChat,
                        options: [.defaultToSpeaker, .allowBluetooth])
        try setPreferredIOBufferDuration(Double(AudioStreamer.frameSamples) / AudioStreamer.sampleRate)
    }
}
#endif
