import XCTest
@testable import TotemKit

/// The server marks an unreachable user as away with no message, a shape
/// clients cannot produce. These pin that invariant down.
final class UnreachableMarkTests: XCTestCase {
    func testAwayWithNoMessageIsRecognizedAsTheServersMark() {
        XCTAssertTrue(Presence.unreachable.isUnreachableMark)
        XCTAssertFalse(Presence(state: .away, awayMessage: "brb").isUnreachableMark)
        XCTAssertFalse(Presence(state: .online).isUnreachableMark)
        XCTAssertFalse(Presence.offline.isUnreachableMark)
    }

    /// No sequence of user actions produces a message-less away.
    func testAClientCanNeverPutItselfAwayWithoutAMessage() {
        var machine = PresenceStateMachine()
        machine.handle(.signOn)

        for attempt in ["", "   ", "\n\t "] {
            machine.handle(.setAwayMessage(attempt))
            XCTAssertEqual(machine.displayState, .online, "empty message \"\(attempt)\" set away")
            XCTAssertNil(machine.awayMessage)
        }

        machine.handle(.setAwayMessage("brb"))
        XCTAssertEqual(machine.displayState, .away)
        XCTAssertNotNil(machine.awayMessage)
        XCTAssertFalse(
            Presence(state: machine.displayState, awayMessage: machine.awayMessage)
                .isUnreachableMark)
    }

    /// The mark is an ordinary presence frame; a new enum case would fail to decode.
    func testTheMarkIsAnOrdinaryPresenceFrameOnTheWire() throws {
        let encoded = try WireCoder.encoder().encode(
            ServerFrame.presence(userID: UUID(), presence: .unreachable))
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains("\"away\""))
        XCTAssertFalse(json.contains("awayMessage"), "nil keys are omitted, not encoded as null")

        let decoded = try WireCoder.decoder().decode(ServerFrame.self, from: encoded)
        guard case .presence(_, let presence) = decoded else {
            return XCTFail("expected a presence frame, got \(decoded)")
        }
        XCTAssertEqual(presence, Presence.unreachable)
    }
}
