import AVFoundation
import SwiftUI

/// Minimal spectrum analysis of one codec frame: Goertzel magnitude at
/// log-spaced frequencies, one per display band. Not a real FFT power
/// spectrum — just enough to draw a live equalizer.
enum AudioAnalyzer {
    static let bandCount = 4
    /// Log-spaced probe frequencies across the speech range.
    private static let frequencies: [Double] = (0..<bandCount).map { band in
        150 * pow(3_600 / 150, Double(band) / Double(bandCount - 1))
    }
    /// Speech rolls off ~6 dB/octave above the fundamentals, so without
    /// compensation only the low bands ever move. Tilt the higher bands up
    /// by the same slope.
    private static let tiltDecibels: [Float] = frequencies.map { frequency in
        Float(6 * log2(frequency / frequencies[0]))
    }

    /// Per-band levels normalized to 0...1 (floor −50 dBFS).
    static func spectrum(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 32 else {
            return Array(repeating: 0, count: bandCount)
        }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        return frequencies.enumerated().map { band, frequency in
            let coefficient = Float(2 * cos(2 * .pi * frequency / buffer.format.sampleRate))
            var s1: Float = 0, s2: Float = 0
            for sample in samples {
                let s = sample + coefficient * s1 - s2
                s2 = s1
                s1 = s
            }
            let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            let amplitude = 2 * sqrt(max(power, 0)) / Float(samples.count)
            let decibels = 20 * log10(amplitude + .leastNormalMagnitude) + tiltDecibels[band]
            return min(max(1 + decibels / 50, 0), 1)
        }
    }
}

/// Equalizer-style bars for one spectrum frame: spaced vertical bars,
/// vertically centered, expanding outward with gain. Levels are squared so
/// the noise floor stays flat and actual speech visibly jumps.
struct AudioMeterView: View {
    let spectrum: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 5) {
            ForEach(spectrum.indices, id: \.self) { band in
                let curved = CGFloat(spectrum[band]) * CGFloat(spectrum[band])
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 4 + 34 * curved)
            }
        }
        .frame(height: 38)
        .animation(.linear(duration: 0.1), value: spectrum)
    }
}
