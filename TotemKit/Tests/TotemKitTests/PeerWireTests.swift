import XCTest
@testable import TotemKit

final class PeerWireTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func sampleFrames() -> [PeerFrame] {
        let conversation = UUID(), me = UUID(), them = UUID()
        let message = ChatMessage(id: UUID(), sessionID: conversation, senderID: me,
                                  body: "hello — ünïcödé 🎉", sentAt: t0, dictated: true)
        var game = FourState(red: me)
        game.yellow = them
        let stage = Stage(version: 4, state: .four(game), ownerID: me)
        return [
            .message(message),
            .typing(conversationID: conversation),
            .audioMuted(conversationID: conversation, muted: true),
            .stageAction(conversationID: conversation, action: .four(.drop(column: 3)), expectedVersion: 4),
            .stageAction(conversationID: conversation,
                         action: .youtube(.setVideo(videoID: "v", title: "T", thumbnailURL: nil)),
                         expectedVersion: nil),
            .stageClose(conversationID: conversation),
            .stageRequest(conversationID: conversation),
            .stage(conversationID: conversation, stage: stage, actorID: them),
            .stage(conversationID: conversation, stage: nil, actorID: nil),
        ]
    }

    func testEveryFrameRoundTripsThroughTheLengthPrefix() throws {
        for frame in sampleFrames() {
            var decoder = PeerWire.Decoder()
            let decoded = try decoder.append(try PeerWire.encode(frame))
            XCTAssertEqual(decoded, [frame])
        }
    }

    /// A QUIC stream hands back whatever bytes have arrived: several frames
    /// at once, or half of one. Both must reassemble to exactly the frames
    /// that were written, in order.
    func testConcatenatedAndSplitChunksReassemble() throws {
        let frames = sampleFrames()
        var stream = Data()
        for frame in frames { stream.append(try PeerWire.encode(frame)) }

        var whole = PeerWire.Decoder()
        XCTAssertEqual(try whole.append(stream), frames)

        var dribbled = PeerWire.Decoder()
        var received: [PeerFrame] = []
        for byte in stream {
            received += try dribbled.append(Data([byte]))
        }
        XCTAssertEqual(received, frames)
    }

    /// A case this build doesn't know decodes as nothing, and the frames
    /// after it still arrive — the framing, not the payload, keeps the
    /// stream readable.
    func testUnknownPayloadIsSkippedWithoutLosingTheStream() throws {
        let known = PeerFrame.typing(conversationID: UUID())
        let unknown = Data(#"{"futureCase":{"x":1}}"#.utf8)
        var stream = Data()
        withUnsafeBytes(of: UInt32(unknown.count).bigEndian) { stream.append(contentsOf: $0) }
        stream.append(unknown)
        stream.append(try PeerWire.encode(known))

        var decoder = PeerWire.Decoder()
        XCTAssertEqual(try decoder.append(stream), [known])
    }

    func testOversizeLengthIsFatal() {
        var stream = Data()
        withUnsafeBytes(of: UInt32(PeerWire.maxFrameBytes + 1).bigEndian) { stream.append(contentsOf: $0) }
        var decoder = PeerWire.Decoder()
        XCTAssertThrowsError(try decoder.append(stream)) { error in
            XCTAssertEqual(error as? PeerWire.Error, .frameTooLarge(PeerWire.maxFrameBytes + 1))
        }
    }

    func testClientFrameAdditionsRoundTrip() throws {
        let conversation = UUID(), user = UUID()
        let frames: [ClientFrame] = [
            .botQuery(conversationID: conversation, body: "@g hi",
                      context: [BotContextMessage(speaker: "a", body: "b")]),
            .botQuery(conversationID: conversation, body: "@g hi", context: nil),
            .unreachable(userID: user),
            .conversationActive(conversationID: conversation),
        ]
        for frame in frames {
            let data = try WireCoder.encoder().encode(frame)
            let decoded = try WireCoder.decoder().decode(ClientFrame.self, from: data)
            switch (frame, decoded) {
            case let (.botQuery(id, body, context), .botQuery(gotID, gotBody, gotContext)):
                XCTAssertEqual(id, gotID)
                XCTAssertEqual(body, gotBody)
                XCTAssertEqual(context, gotContext)
            case let (.unreachable(id), .unreachable(gotID)):
                XCTAssertEqual(id, gotID)
            case let (.conversationActive(id), .conversationActive(gotID)):
                XCTAssertEqual(id, gotID)
            default:
                XCTFail("wrong case: \(decoded)")
            }
        }
    }
}
