import AVFoundation

/// Smooths one speaker's arrivals into gapless playback. Playback starts once
/// a few frames are in hand and re-primes after a starve. Past `cap` queued
/// frames are dropped: a player node drains at real time, so a burst would
/// otherwise become a permanent delay. Completions land on an audio thread.
final class JitterBuffer: @unchecked Sendable {
    private static let prefill = 3
    /// Loose because some outputs (Bluetooth) report playback in ~100 ms batches.
    private static let cap = 15
    private let lock = NSLock()
    private var held: [AVAudioPCMBuffer] = []
    private var queued = 0

    /// Returns whatever should be scheduled now: nothing while priming, the
    /// whole cushion once full, then each frame as it comes.
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
