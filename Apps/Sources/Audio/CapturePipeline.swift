import AVFoundation

/// Re-cuts the mic's buffers into exact codec frames, normalizing gain on
/// the way out. Used only from the audio queue.
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
