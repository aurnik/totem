import AVFoundation

/// Live voice for open chats: captures the mic as 20 ms Opus packets and plays
/// incoming packets through one decoder and player node per remote speaker.
/// Opus is the only thing on the wire; PCM exists at the two ends of the codec.
///
/// iOS: capture and playback share ONE engine with the voice-processing IO
/// unit enabled — echo cancellation only works against audio the same unit
/// renders, so a split graph lets the peer's speaker output loop back through
/// their mic uncancelled. Until the mic is first opened the engine stays on a
/// play-only category and `inputNode` is never touched: reaching for the input
/// at all is what raises the system microphone prompt, and listening is not a
/// reason to ask.
///
/// macOS: separate engines, no `setVoiceProcessingEnabled` — the VP unit
/// there has a habit of delivering silent input buffers; headphones are the
/// answer.
@MainActor
final class AudioStreamer {
    static let sampleRate: Double = 48_000
    /// 20 ms at 48 kHz: Opus's native frame, and a packet that fits a QUIC
    /// datagram with room to spare.
    static let frameSamples: AVAudioFrameCount = 960
    static let frameDuration: Duration = .milliseconds(20)
    static let bitrate = 32_000

    enum Playback {
        case heard(spectrum: [Float])
        /// Why nothing will be heard, so the caller can surface it.
        case silent(reason: String)
    }

    private let playbackEngine: AVAudioEngine
    private let captureEngine: AVAudioEngine
    /// Player nodes are pooled per sender and NEVER detached — removing a
    /// node from a live voice-processing graph asserts inside AVAudioEngine
    /// (SIGABRT in RemoveNode, seen on TestFlight). Quiet speakers just stop.
    private var players: [UUID: AVAudioPlayerNode] = [:]
    /// Opus decoders carry state between packets, so one per sender too.
    private var decoders: [UUID: OpusCodec] = [:]
    private var jitterBuffers: [UUID: JitterBuffer] = [:]
    private var activeSpeakers: Set<UUID> = []
    private var micLive = false
    private var pacer: PacketPacer?
    /// What the live tap feeds, kept so the tap can be rebuilt on a device
    /// change without the owner knowing anything happened.
    private var captureSinks: (packet: (@Sendable (Data, [Float]) -> Void)?,
                               buffer: (@Sendable (AVAudioPCMBuffer) -> Void)?)?
    private var configurationObservers: [NSObjectProtocol] = []
    /// Last session/engine failure — playback problems are otherwise
    /// invisible (the meters run off decoded audio, not the engine).
    private var lastError: String?
    /// Fires on system output-volume changes so the owner can re-evaluate
    /// `outputMuted` (the crossed-out-speaker signal to chat peers).
    var onOutputVolumeChange: (@MainActor () -> Void)?
    #if os(iOS)
    private var volumeObservation: NSKeyValueObservation?
    /// Whether the voice-processing IO unit has been wired in — set once, the
    /// first time the user opens the mic.
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
        // A device coming or going (AirPods mid-call, a default-device switch)
        // stops the engine and changes the input node's format; nothing
        // resumes on its own. Observed per engine — one on iOS, two on macOS.
        let engines = playbackEngine === captureEngine ? [playbackEngine] : [playbackEngine, captureEngine]
        for engine in engines {
            configurationObservers.append(NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                Task { @MainActor in self?.recoverFromConfigurationChange() }
            })
        }
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

    // MARK: - Capture

    /// Requests permission and taps the mic, emitting Opus packets (with a
    /// meter frame of the audio that went into each) for broadcast and/or raw
    /// buffers for on-device transcription — both on an audio thread. Sinks
    /// are fixed when the tap is installed, so calling this while already
    /// live reinstalls the tap with the new pair. Returns false if permission
    /// was denied or the engine couldn't start.
    func startMic(onPacket: (@Sendable (Data, [Float]) -> Void)? = nil,
                  onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)? = nil) async -> Bool {
        guard await Self.requestMicPermission() else {
            print("voice: mic permission denied")
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

    /// Builds the codec path and taps the mic. The tap takes the node's
    /// *input* format: after a device change the output format still reports
    /// the old device's rate, and a tap in that format is rejected outright.
    private func installCapture(onPacket: (@Sendable (Data, [Float]) -> Void)?,
                                onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?) -> Bool {
        let input = captureEngine.inputNode
        let tapFormat = input.inputFormat(forBus: 0)
        guard tapFormat.sampleRate > 0,
              let resampler = AVAudioConverter(from: tapFormat, to: OpusCodec.pcmFormat),
              let encoder = try? OpusCodec()
        else {
            print("voice: mic unusable — input \(tapFormat), \(lastError ?? "no session error")")
            return false
        }
        let framer = FrameAssembler()
        let pacer = PacketPacer()
        self.pacer?.stop()
        self.pacer = onPacket.map { sink in
            pacer.start { packet, spectrum in sink(packet, spectrum) }
            return pacer
        }

        var reportedBufferSize = false
        input.installTap(onBus: 0, bufferSize: Self.frameSamples, format: tapFormat) { buffer, _ in
            // Audio thread. Transcription gets the buffer untouched; the wire
            // path resamples, normalizes, and encodes its own copy. Converter
            // and framer are stateful but only ever touched from this serial tap.
            if !reportedBufferSize {
                reportedBufferSize = true
                // The size the OS actually hands over decides whether packets
                // leave one at a time or in bursts — worth knowing when voice
                // sounds choppy at the other end.
                print("voice: tap \(Int(tapFormat.sampleRate)) Hz, \(buffer.frameLength)-frame buffers")
            }
            onBuffer?(buffer)
            guard let onPacket,
                  let resampled = resampler.resample(buffer, into: OpusCodec.pcmFormat)
            else { return }
            framer.append(resampled)
            // A tap hands over 100 ms at a time (its documented floor), which
            // is several packets at once. The pacer lets them out one per
            // frame interval, so the receiver sees a steady stream it can
            // play with a short buffer rather than a burst to absorb.
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
            print("capture engine failed to start: \(error)")
            stopMic()
            return false
        }
        return true
    }

    /// The engine has stopped under us. Put back whatever was running: the
    /// tap on the new input format, and playback for anyone still audible.
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
        // Shared engine: keep it alive if playback still needs it.
        if activeSpeakers.isEmpty { captureEngine.stop() }
        #else
        captureEngine.stop()
        #endif
    }

    // MARK: - Playback

    /// Decodes every packet so the meters keep moving; `audible` is whether it
    /// also reaches the speaker.
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

    /// The speaker went quiet (or their chat closed) — halt their node.
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
            print("playback engine failed to start: \(error)")
            return false
        }
    }

    // MARK: - Session

    /// Wires the voice-processing IO unit in, the one thing that has to happen
    /// before the engine ever starts capturing: the category has to be
    /// record-capable first (enabling fails under a play-only one), and the
    /// engine has to be stopped, since listening may already have started it.
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
            print("voice processing setup failed: \(error)")
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

/// Smooths one speaker's arrivals into gapless playback. Playback starts only
/// once a few frames are in hand, so ordinary jitter lands inside that
/// cushion instead of at the speaker; a link that starves the node re-primes
/// the same way. The other bound matters as much: a burst — the first seconds
/// on a relay, a hiccup on the link — would otherwise queue up and stay
/// queued, since the node drains at exactly real time, so past the cap frames
/// are dropped. A 20 ms gap is far less audible than a lasting lag.
/// Completions land on an audio thread, so it locks.
private final class JitterBuffer: @unchecked Sendable {
    private static let prefill = 3
    /// Generous because "played back" completions arrive in batches on some
    /// outputs (Bluetooth reports every 100 ms or so), and the count has to
    /// ride out a batch without touching the cap.
    private static let cap = 15
    private let lock = NSLock()
    private var held: [AVAudioPCMBuffer] = []
    /// Scheduled but not yet played.
    private var queued = 0

    /// Takes a decoded frame and returns whatever should be scheduled now:
    /// nothing while priming, the whole cushion once it's full, then each
    /// frame as it comes.
    func admit(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        lock.withLock {
            if queued == 0 || !held.isEmpty {
                held.append(buffer)
                guard held.count >= Self.prefill else { return [] }
                queued += held.count
                defer { held = [] }
                return held
            }
            guard queued < Self.cap else { return [] }
            queued += 1
            return [buffer]
        }
    }

    func played() {
        lock.withLock { queued = max(0, queued - 1) }
    }
}

/// One direction of the system Opus codec behind `AVAudioConverter`: an
/// instance either encodes or decodes, since the converter's state is bound
/// to the direction it was created for.
final class OpusCodec {
    static let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: AudioStreamer.sampleRate,
        channels: 1, interleaved: false)!
    static let opusFormat: AVAudioFormat = {
        var description = AudioStreamBasicDescription(
            mSampleRate: AudioStreamer.sampleRate, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(AudioStreamer.frameSamples),
            mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0, mReserved: 0)
        return AVAudioFormat(streamDescription: &description)!
    }()

    private lazy var encoder: AVAudioConverter? = {
        let converter = AVAudioConverter(from: Self.pcmFormat, to: Self.opusFormat)
        converter?.bitRate = AudioStreamer.bitrate
        return converter
    }()
    private lazy var decoder = AVAudioConverter(from: Self.opusFormat, to: Self.pcmFormat)

    struct Unavailable: Error {}

    init() throws {
        guard AVAudioConverter(from: Self.pcmFormat, to: Self.opusFormat) != nil else {
            throw Unavailable()
        }
    }

    /// One 20 ms frame in, one packet out.
    func encode(_ frame: AVAudioPCMBuffer) throws -> Data {
        guard let encoder else { throw Unavailable() }
        let out = AVAudioCompressedBuffer(
            format: Self.opusFormat, packetCapacity: 1,
            maximumPacketSize: encoder.maximumOutputPacketSize)
        try encoder.convert(into: out, from: frame)
        guard out.packetCount == 1 else { throw Unavailable() }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    func decode(_ packet: Data) throws -> AVAudioPCMBuffer {
        guard let decoder else { throw Unavailable() }
        let input = AVAudioCompressedBuffer(
            format: Self.opusFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { raw in
            input.data.copyMemory(from: raw.baseAddress!, byteCount: packet.count)
        }
        input.byteLength = UInt32(packet.count)
        input.packetCount = 1
        input.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        let out = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat,
                                   frameCapacity: AudioStreamer.frameSamples * 2)!
        try decoder.convert(into: out, from: input)
        guard out.frameLength > 0 else { throw Unavailable() }
        return out
    }
}

private extension AVAudioConverter {
    /// Feeds exactly one buffer and returns whatever the converter produced.
    func convert(into out: AVAudioBuffer, from input: AVAudioBuffer) throws {
        var fed = false
        var error: NSError?
        let status = convert(to: out, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        if status == .error { throw OpusCodec.Unavailable() }
    }

    func resample(_ buffer: AVAudioPCMBuffer, into format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
              (try? convert(into: out, from: buffer)) != nil, out.frameLength > 0
        else { return nil }
        return out
    }
}

/// Lets encoded packets out one per frame interval on a strict timer. One-shot
/// dispatch delays would do the spacing too, but the system may coalesce
/// those by tens of milliseconds, and bunched arrivals are what a short
/// receive buffer can't ride out.
private final class PacketPacer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voice.pacer", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pending: [(Data, [Float])] = []

    func start(_ sink: @escaping @Sendable (Data, [Float]) -> Void) {
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !self.pending.isEmpty else { return }
            let (packet, spectrum) = self.pending.removeFirst()
            sink(packet, spectrum)
        }
        self.timer = timer
        timer.activate()
    }

    func enqueue(_ packet: Data, _ spectrum: [Float]) {
        queue.async { self.pending.append((packet, spectrum)) }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }
}

/// Re-cuts the tap's arbitrary buffers into exact codec frames, with the
/// gain normalizer riding on each frame on the way out.
private final class FrameAssembler {
    private var pending: [Float] = []
    private let normalizer = AudioNormalizer()

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData else { return }
        pending.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
    }

    func nextFrame() -> AVAudioPCMBuffer? {
        let count = Int(AudioStreamer.frameSamples)
        guard pending.count >= count,
              let frame = AVAudioPCMBuffer(pcmFormat: OpusCodec.pcmFormat,
                                           frameCapacity: AudioStreamer.frameSamples)
        else { return nil }
        frame.frameLength = AudioStreamer.frameSamples
        let samples = frame.floatChannelData![0]
        pending.withUnsafeBufferPointer { samples.update(from: $0.baseAddress!, count: count) }
        pending.removeFirst(count)
        normalizer.normalize(samples, frames: count)
        return frame
    }
}

/// Smoothed automatic gain riding on the capture path: nudges frame loudness
/// toward a target peak so quiet and loud mics arrive at comparable levels.
/// Attack (gain down) is fast to dodge clipping; release (gain up) is slow to
/// avoid pumping. State is only touched from the serial tap, never concurrently.
private final class AudioNormalizer {
    private var gain: Float = 1
    private static let targetPeak: Float = 0.7
    /// Per-frame smoothing. Frames are 20 ms, so these are a fifth of what
    /// felt right at 100 ms — the same settling time, without the gain
    /// stepping audibly at every frame edge.
    private static let attack: Float = 0.13
    private static let release: Float = 0.01
    /// Below this peak the frame is treated as silence/noise — gain holds
    /// rather than winding up to amplify the noise floor.
    private static let noiseFloor: Float = 0.02
    private static let maxGain: Float = 8

    func normalize(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        var peak: Float = 0
        for i in 0..<frames {
            peak = max(peak, abs(samples[i]))
        }
        if peak >= Self.noiseFloor {
            let desired = min(Self.targetPeak / peak, Self.maxGain)
            gain += (desired - gain) * (desired < gain ? Self.attack : Self.release)
        }
        // Hard ceiling regardless of smoothing: never let this frame clip.
        if peak * gain > 1 { gain = 1 / peak }
        guard abs(gain - 1) > 0.01 else { return }
        for i in 0..<frames {
            samples[i] = max(-1, min(1, samples[i] * gain))
        }
    }
}

/// On-disk shape of a recorded sound sample: Opus packets back to back, each
/// behind a two-byte big-endian length.
enum OpusPacketFile {
    static func encode(_ packets: [Data]) -> Data {
        var data = Data()
        for packet in packets where packet.count <= Int(UInt16.max) {
            withUnsafeBytes(of: UInt16(packet.count).bigEndian) { data.append(contentsOf: $0) }
            data.append(packet)
        }
        return data
    }

    static func decode(_ data: Data) -> [Data] {
        var packets: [Data] = []
        var offset = data.startIndex
        while offset + 2 <= data.endIndex {
            let length = Int(data[offset]) << 8 | Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.endIndex else { break }
            packets.append(data[offset..<offset + length])
            offset += length
        }
        return packets
    }
}

#if os(iOS)
private extension AVAudioSession {
    /// The one category live voice runs under: duplex, echo-cancelling, and
    /// routed to the loudspeaker rather than the receiver. The IO buffer is
    /// asked to match the codec frame so packets leave one at a time rather
    /// than several per larger buffer — bursts are what a receiver hears as
    /// gaps.
    func setVoiceChatCategory() throws {
        try setCategory(.playAndRecord, mode: .voiceChat,
                        options: [.defaultToSpeaker, .allowBluetooth])
        try setPreferredIOBufferDuration(Double(AudioStreamer.frameSamples) / AudioStreamer.sampleRate)
    }
}
#endif
