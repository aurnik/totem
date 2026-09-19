import Foundation

/// Frames exchanged directly between peers over the iroh link's ordered
/// stream. `PeerLink` stamps the sender from the authenticated connection, and
/// a frame is applied only for a conversation that sender belongs to.
public enum PeerFrame: Codable, Hashable, Sendable {
    case message(ChatMessage)
    /// The only evidence of delivery: a write completes at the local send buffer.
    case ack(messageID: UUID)
    case typing(conversationID: UUID)
    case audioMuted(conversationID: UUID, muted: Bool)
    /// Sent to the stage's owner, who runs the reducer and answers with `stage`.
    case stageAction(conversationID: UUID, action: StageAction, expectedVersion: Int?)
    case stageClose(conversationID: UUID)
    /// Asked of everyone; only the owner answers.
    case stageRequest(conversationID: UUID)
    /// `actorID` is nil for a snapshot or re-sync, so only changes post a notice.
    case stage(conversationID: UUID, stage: Stage?, actorID: UUID?)
}

/// Length-prefixed framing: a big-endian 32-bit length, then the JSON.
public enum PeerWire {
    public static let maxFrameBytes = 256 * 1024

    public enum Error: Swift.Error, Equatable {
        case frameTooLarge(Int)
    }

    public static func encode(_ frame: PeerFrame) throws -> Data {
        let payload = try WireCoder.encoder().encode(frame)
        guard payload.count <= maxFrameBytes else { throw Error.frameTooLarge(payload.count) }
        var data = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    /// A frame that fails to decode is skipped, since the framing is intact.
    public struct Decoder {
        private var buffer = Data()

        public init() {}

        public mutating func append(_ chunk: Data) throws -> [PeerFrame] {
            buffer.append(chunk)
            var frames: [PeerFrame] = []
            while buffer.count >= 4 {
                let length = Int(buffer.prefix(4).withUnsafeBytes {
                    UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
                })
                guard length <= PeerWire.maxFrameBytes else { throw Error.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let payload = buffer.subdata(in: 4..<(4 + length))
                buffer.removeSubrange(0..<(4 + length))
                if let frame = try? WireCoder.decoder().decode(PeerFrame.self, from: payload) {
                    frames.append(frame)
                }
            }
            return frames
        }
    }
}
