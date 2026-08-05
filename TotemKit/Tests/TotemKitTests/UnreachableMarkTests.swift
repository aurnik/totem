import XCTest
@testable import TotemKit

/// The server marks a user it can't reach as away with no message. That shape
/// is only meaningful because clients can't produce it themselves — these pin
/// down the invariant the whole scheme rests on.
final class UnreachableMarkTests: XCTestCase {
    func testAwayWithNoMessageIsRecognizedAsTheServersMark() {
        XCTAssertTrue(Presence.unreachable.isUnreachableMark)
        XCTAssertFalse(Presence(state: .away, awayMessage: "brb").isUnreachableMark)
        XCTAssertFalse(Presence(state: .online).isUnreachableMark)
        XCTAssertFalse(Presence.offline.isUnreachableMark)
    }

    /// The client derives `away` from having a message, so no sequence of user
    /// actions produces the server's mark — otherwise a reconnect would clear
    /// an away the user had set on purpose.
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

    /// Reusing `away` rather than adding a `PresenceState` case is what lets
    /// this ship without breaking installed builds: the mark is an ordinary
    /// presence frame, and a new enum case would fail to decode and take the
    /// whole frame with it.
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
