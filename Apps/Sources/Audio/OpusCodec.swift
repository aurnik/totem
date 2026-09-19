import AVFoundation

/// One direction of the system Opus codec behind `AVAudioConverter`. An
/// instance either encodes or decodes; the converter's state is bound to the
/// direction it was created for.
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

extension AVAudioConverter {
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
