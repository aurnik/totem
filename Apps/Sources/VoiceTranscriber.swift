import AVFoundation
import Speech

/// On-device dictation: mic buffers in, finished utterances out as text.
/// Phrase breaks come from the transcriber; a short quiet timer coalesces
/// finals that arrive back-to-back so one breath of speech is one message.
@available(iOS 26.0, macOS 26.0, *)
@MainActor
final class VoiceTranscriber {
    /// Quiet time after the last finalized text before it's sent as a message.
    private static let utteranceGap = Duration.milliseconds(300)

    private let onUtterance: @MainActor (String) -> Void
    /// Brackets an actual model download.
    private let onDownloading: @MainActor (Bool) -> Void

    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pending = ""

    /// False on hardware without the on-device speech models.
    static var isSupported: Bool { SpeechTranscriber.isAvailable }

    init(onUtterance: @escaping @MainActor (String) -> Void,
         onDownloading: @escaping @MainActor (Bool) -> Void) {
        self.onUtterance = onUtterance
        self.onDownloading = onDownloading
    }

    /// Brings up the analyzer and returns the sink for the capture tap, which
    /// runs on the audio thread and never touches this actor.
    func start() async throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        let locale = await Self.preferredLocale()
        // Finalized phrases only: no partials, since nothing is shown before send.
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [])
        try await installModel(for: transcriber)

        // Nil until the assets are installed.
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        else { throw TranscriptionError.noCompatibleAudioFormat }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream(
            bufferingPolicy: .bufferingNewest(32))
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.receive(result)
                }
            } catch {
                Log.audio.error("transcription stopped: \(error)")
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

    /// Lets trailing speech finalize and sends what is left as a last utterance.
    func stop() async {
        flushTask?.cancel()
        flushTask = nil
        input?.finish()
        input = nil
        let finishing = analyzer
        analyzer = nil
        try? await finishing?.finalizeAndFinishThroughEndOfInput()

        // Bounded so an analyzer that never finishes can't wedge the mic.
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

    /// Only finalized phrases become messages; a timer-forced cut would land
    /// mid-clause.
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

    private static func preferredLocale() async -> Locale {
        await SpeechTranscriber.supportedLocale(equivalentTo: .current)
            ?? Locale(identifier: "en_US")
    }

    /// Downloads the language model on first use.
    private func installModel(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
        else { return }
        // A non-nil request may just be re-reserving an installed locale, so
        // only report a download once it is plainly slow.
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

/// Resamples mic buffers into the analyzer's format, rebuilt if the route
/// changes it. Only touched from the serial capture tap.
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
            // Padding with warm-up samples would drift the analyzer's timeline.
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
