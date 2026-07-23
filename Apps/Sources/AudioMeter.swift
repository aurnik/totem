import Foundation
import SwiftUI
import TotemKit

/// Minimal spectrum analysis of a wire-format audio chunk: Goertzel magnitude
/// at log-spaced frequencies, one per display band. Not a real FFT power
/// spectrum — just enough to draw a live equalizer at ~10 updates/s.
enum AudioAnalyzer {
    static let bandCount = 12
    /// Log-spaced probe frequencies across the speech range.
    private static let frequencies: [Double] = (0..<bandCount).map { band in
        100 * pow(6_000 / 100, Double(band) / Double(bandCount - 1))
    }

    /// Per-band levels normalized to 0...1 (floor −50 dBFS).
    static func spectrum(of chunk: Data) -> [Float] {
        let samples: [Float] = chunk.withUnsafeBytes { raw in
            raw.bindMemory(to: Int16.self).map { Float($0) / 32_768 }
        }
        guard samples.count > 32 else { return Array(repeating: 0, count: bandCount) }
        return frequencies.map { frequency in
            let coefficient = Float(2 * cos(2 * .pi * frequency / AudioWire.sampleRate))
            var s1: Float = 0, s2: Float = 0
            for sample in samples {
                let s = sample + coefficient * s1 - s2
                s2 = s1
                s1 = s
            }
            let power = s1 * s1 + s2 * s2 - coefficient * s1 * s2
            let amplitude = 2 * sqrt(max(power, 0)) / Float(samples.count)
            let decibels = 20 * log10(amplitude + .leastNormalMagnitude)
            return min(max(1 + decibels / 50, 0), 1)
        }
    }
}

/// Equalizer-style bars for one spectrum frame.
struct AudioMeterView: View {
    let spectrum: [Float]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(spectrum.indices, id: \.self) { band in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 3 + 13 * CGFloat(spectrum[band]))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.1), value: spectrum)
    }
}
