import Accelerate
import AVFoundation

/// Smooths one speaker's arrivals into gapless playback. Playback starts once
/// a few frames are in hand and re-primes after a starve. A player node's
/// queue drains at exactly real time, so the backlog a burst leaves behind
/// never shrinks on its own: when the depth stays above `trimAbove` for a
/// whole window, one frame is dropped, a quiet one if any comes along in
/// time. Past `cap` queued frames are dropped outright. Completions land on
/// an audio thread.
final class JitterBuffer: @unchecked Sendable {
    private static let prefill = 3
    /// Frames scheduled but not yet played; the window's lowest reading is
    /// the latency nothing is absorbing.
    private static let trimAbove = 5
    private static let window = 25
    /// Loose because some outputs (Bluetooth) report playback in ~100 ms batches.
    private static let cap = 15
    private static let quietPeak: Float = 0.02
    private let lock = NSLock()
    private var held: [AVAudioPCMBuffer] = []
    private var queued = 0
    private var admitted = 0
    private var windowMinDepth = Int.max
    private var trimDue = false
    private var trimWaited = 0

    /// Returns whatever should be scheduled now: nothing while priming, the
    /// whole cushion once full, then each frame as it comes.
    func admit(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        lock.withLock {
            if queued == 0 || !held.isEmpty {
                held.append(buffer)
                guard held.count >= Self.prefill else { return [] }
                queued += held.count
                windowMinDepth = .max
                trimDue = false
                defer { held = [] }
                return held
            }
            guard queued < Self.cap, !shouldTrim(buffer) else { return [] }
            queued += 1
            return [buffer]
        }
    }

    private func shouldTrim(_ buffer: AVAudioPCMBuffer) -> Bool {
        windowMinDepth = min(windowMinDepth, queued)
        admitted += 1
        if admitted % Self.window == 0 {
            if windowMinDepth > Self.trimAbove {
                trimDue = true
                trimWaited = 0
            }
            windowMinDepth = .max
        }
        guard trimDue else { return false }
        trimWaited += 1
        guard Self.peak(of: buffer) < Self.quietPeak || trimWaited >= Self.window else { return false }
        trimDue = false
        return true
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var peak: Float = 0
        vDSP_maxmgv(channel[0], 1, &peak, vDSP_Length(buffer.frameLength))
        return peak
    }

    func played() {
        lock.withLock { queued = max(0, queued - 1) }
    }
}
