import Foundation

/// Frames that travel between peers over the iroh link's ordered stream —
/// everything conversation-shaped, which the server no longer sees. Encoded
/// with `WireCoder` like the socket frames, so the same compatibility rules
/// apply: an optional new field is safe in both directions, a new case needs
/// both ends updated.
///
/// The receiver never trusts a frame about who sent it: `PeerLink` stamps the
/// sender from the authenticated connection, and a frame is applied only for
/// a conversation that sender is actually in.
public enum PeerFrame: Codable, Hashable, Sendable {
    /// `sessionID` carries the conversation ID; `id` and `sentAt` are the
    /// sender's own, there being no server left to mint them.
    case message(ChatMessage)
    case typing(conversationID: UUID)
    /// The sender can't hear the conversation's live audio right now, or can
    /// again.
    case audioMuted(conversationID: UUID, muted: Bool)
    /// Sent to the stage's owner only, who runs the reducer and answers with
    /// `stage`. `expectedVersion` is what the sender was looking at, so a
    /// conditional action aimed at a stage that has since moved is dropped.
    case stageAction(conversationID: UUID, action: StageAction, expectedVersion: Int?)
    /// Sent to the owner: take the stage down.
    case stageClose(conversationID: UUID)
    /// Asked of everyone in the conversation; only the owner answers.
    case stageRequest(conversationID: UUID)
    /// The stage, from its owner — the one party whose word counts for it.
    /// `actorID` is whoever acted, and nil for a snapshot or a re-sync after a
    /// refused action, so only real changes post a transcript notice.
    case stage(conversationID: UUID, stage: Stage?, actorID: UUID?)
}

/// Length-prefixed framing for `PeerFrame` on a byte stream: a big-endian
/// 32-bit length, then the JSON.
public enum PeerWire {
    /// Nothing legitimate comes near this; a peer sending more is broken or
    /// hostile, and the stream carrying it is dropped.
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

    /// Reassembles frames from a stream read in arbitrary chunks. A frame that
    /// doesn't decode — a case this build predates — is skipped, since the
    /// framing around it is intact; only an oversize length is fatal.
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
