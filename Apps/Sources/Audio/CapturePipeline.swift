import AVFoundation

/// Releases encoded packets one per frame interval on a strict timer. One-shot
/// dispatch delays get coalesced by tens of milliseconds, and bunched arrivals
/// are what a short receive buffer cannot absorb.
final class PacketPacer: @unchecked Sendable {
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

/// Re-cuts the tap's arbitrary buffers into exact codec frames, normalizing
/// gain on the way out. Used only from the serial tap.
final class FrameAssembler {
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

/// Smoothed automatic gain: fast attack to dodge clipping, slow release to
/// avoid pumping, and no gain change on frames below the noise floor.
final class AudioNormalizer {
    private var gain: Float = 1
    private static let targetPeak: Float = 0.7
    private static let attack: Float = 0.13
    private static let release: Float = 0.01
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
        if peak * gain > 1 { gain = 1 / peak }
        guard abs(gain - 1) > 0.01 else { return }
        for i in 0..<frames {
            samples[i] = max(-1, min(1, samples[i] * gain))
        }
    }
}
