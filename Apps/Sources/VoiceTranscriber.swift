import AVFoundation
import Speech

/// On-device dictation: mic buffers in, finished utterances out as chat-ready
/// text. Nothing leaves the device — `SpeechAnalyzer` runs the model locally,
/// and the caller sends the text as an ordinary message.
///
/// Speech breaks are the transcriber's own: it finalizes a range once it stops
/// revising it, which lands on natural pauses. A short quiet timer coalesces
/// the finals that arrive back-to-back mid-sentence, so one breath of speech
/// becomes one message rather than three.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class VoiceTranscriber {
    /// Quiet time after the last finalized text before it's sent as a message.
    /// Short enough to feel like a reply, long enough to gather the finals
    /// that arrive back-to-back at the end of a phrase.
    private static let utteranceGap = Duration.milliseconds(300)

    /// Words the speaker has finished saying — one call per utterance.
    private let onUtterance: @MainActor (String) -> Void
    /// Brackets an actual model download, which only happens when the locale's
    /// assets aren't already on the device.
    private let onDownloading: @MainActor (Bool) -> Void

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending = ""

    /// Whether this device can transcribe at all — false on hardware without
    /// the on-device speech models (Apple Intelligence hardware gate).
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    init(onUtterance: @escaping @MainActor (String) -> Void,
         onDownloading: @escaping @MainActor (Bool) -> Void) {
        self.onUtterance = onUtterance
        self.onDownloading = onDownloading
    }

    /// Brings up the analyzer and returns the mic sink to hand the capture tap.
    /// The sink is called on the audio thread, so it does its own conversion
    /// and hands buffers off without touching this actor.
    func start() async throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        let locale = await Self.preferredLocale()
        // Finalized phrases only. The presets add `.fastResults` (accuracy
        // traded for latency) or `.volatileResults` (revisable partials);
        // nothing here shows text before it's sent, so neither earns its keep.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        try await installModel(for: transcriber)

        // Only meaningful once the assets are installed — before that it's nil.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw TranscriptionError.noCompatibleAudioFormat }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Consume results before starting so nothing is missed, then feed.
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(result)
                }
            } catch {
                print("transcription stopped: \(error)")
            }
        }
        try await analyzer.start(inputSequence: stream)

        self.analyzer = analyzer
        input = continuation

        let converter = TranscriptionConverter(target: format)
        return { buffer in
            guard let converted = converter.convert(buffer) else { return }
            continuation.yield(AnalyzerInput(buffer: converted))
        }
    }

    /// Finishes the analyzer, letting trailing speech finalize, and sends
    /// whatever is left as a last utterance.
    func stop() async {
        flushTask?.cancel()
        flushTask = nil
        input?.finish()
        input = nil
        let finishing = analyzer
        analyzer = nil
        try? await finishing?.finalizeAndFinishThroughEndOfInput()

        // The results stream ends with the analyzer, so this returns as soon
        // as the last finalized text lands. The timeout is there so an
        // analyzer that never finishes can't wedge the mic for the session.
        let results = resultsTask
        resultsTask = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await results?.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
        results?.cancel()
        flush()
    }

    /// Only finalized phrases become messages. Where the model ends a phrase
    /// is where a sentence actually ends — forcing a cut on a timer instead
    /// lands mid-clause and sends fragments that open with a comma.
    private func receive(_ result: SpeechTranscriber.Result) {
        guard result.isFinal else { return }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        pending += pending.isEmpty ? text : " " + text
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: Self.utteranceGap)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    private func flush() {
        let utterance = pending.trimmingCharacters(in: .whitespaces)
        pending = ""
        flushTask = nil
        guard !utterance.isEmpty else { return }
        onUtterance(utterance)
    }

    /// The device's language if the transcriber speaks it, else US English.
    private static func preferredLocale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: .current)
            ?? Locale(identifier: "en_US")
    }

    /// Downloads the language model on first use. The request is nil when
    /// there's nothing to fetch, so this is cheap on every later start; the
    /// locale reservation it needs is made for us.
    private func installModel(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        else { return }
        // A non-nil request doesn't mean bytes: it also covers re-reserving a
        // locale whose assets are already on disk, which returns immediately.
        // Only call it a download once it's plainly not instant.
        let notice = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.onDownloading(true)
        }
        defer {
            notice.cancel()
            onDownloading(false)
        }
        try await request.downloadAndInstall()
    }

    enum TranscriptionError: Error {
        case noCompatibleAudioFormat
    }
}

/// Resamples mic buffers into the analyzer's format. Built lazily because the
/// tap's format isn't known until it's installed, and rebuilt if the route
/// changes it mid-session. Only ever touched from the serial capture tap.
@available(iOS 26.0, macOS 26.0, *)
private final class TranscriptionConverter: @unchecked Sendable {
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?

    init(target: AVAudioFormat) {
        self.target = target
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            // Drops the resampler's warm-up samples rather than padding with
            // them, which would drift the analyzer's timeline over a session.
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)
        else { return nil }
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
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
