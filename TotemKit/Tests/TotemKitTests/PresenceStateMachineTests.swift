import XCTest
@testable import TotemKit

final class PresenceStateMachineTests: XCTestCase {

    func signedOn() -> PresenceStateMachine {
        var m = PresenceStateMachine()
        m.handle(.signOn)
        return m
    }

    // MARK: - Basic transitions

    func testStartsOffline() {
        XCTAssertEqual(PresenceStateMachine().displayState, .offline)
    }

    func testSignOnGoesOnlineAndPlaysSound() {
        var m = PresenceStateMachine()
        let effects = m.handle(.signOn)
        XCTAssertEqual(m.displayState, .online)
        XCTAssertTrue(effects.contains(.playSignOnSound))
        XCTAssertTrue(effects.contains(.sendPresence(.online, awayMessage: nil)))
    }

    func testSignOffGoesOfflineNotifiesServerAndPlaysSound() {
        var m = signedOn()
        let effects = m.handle(.signOff)
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertTrue(effects.contains(.playSignOffSound))
        // Explicit sign-off proposes offline so the server need not wait out the TTL.
        XCTAssertTrue(effects.contains(.sendPresence(.offline, awayMessage: nil)))
    }

    func testDuplicateSignOnIsIgnored() {
        var m = signedOn()
        let effects = m.handle(.signOn)
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.displayState, .online)
    }

    func testSignOffWhenOfflineIsIgnored() {
        var m = PresenceStateMachine()
        XCTAssertTrue(m.handle(.signOff).isEmpty)
    }

    // MARK: - Away

    func testAwayOverridesOnline() {
        var m = signedOn()
        m.handle(.setAwayMessage("bbl"))
        XCTAssertEqual(m.displayState, .away)
    }

    func testClearAwayReturnsToOnline() {
        var m = signedOn()
        m.handle(.setAwayMessage("lunch"))
        let effects = m.handle(.clearAwayMessage)
        XCTAssertEqual(m.displayState, .online)
        XCTAssertTrue(effects.contains(.sendPresence(.online, awayMessage: nil)))
    }

    func testSignOffClearsAwayMessage() {
        var m = signedOn()
        m.handle(.setAwayMessage("brb"))
        m.handle(.signOff)
        XCTAssertNil(m.awayMessage)
        m.handle(.signOn)
        XCTAssertEqual(m.displayState, .online, "away does not survive sign-off")
    }

    func testAwayMessageTruncatedTo140() {
        var m = signedOn()
        m.handle(.setAwayMessage(String(repeating: "x", count: 200)))
        XCTAssertEqual(m.awayMessage?.count, Limits.awayMessageMaxLength)
    }

    func testEmptyAwayMessageIgnored() {
        var m = signedOn()
        m.handle(.setAwayMessage("   "))
        XCTAssertEqual(m.displayState, .online)
        XCTAssertNil(m.awayMessage)
    }

    // MARK: - Reconnect races

    func testConnectionLossDoesNotShowOffline() {
        var m = signedOn()
        m.handle(.connectionLost)
        XCTAssertTrue(m.isReconnecting)
        XCTAssertEqual(m.displayState, .online, "reconnecting must not display as offline")
    }

    func testAwayMessageSurvivesReconnect() {
        var m = signedOn()
        m.handle(.setAwayMessage("afk"))
        m.handle(.connectionLost)
        let effects = m.handle(.reconnected)
        XCTAssertEqual(m.displayState, .away)
        XCTAssertTrue(effects.contains(.sendPresence(.away, awayMessage: "afk")),
                      "reconnect re-proposes current state so the server snapshot recovers")
    }

    func testNoPresenceSentWhileReconnecting() {
        var m = signedOn()
        m.handle(.connectionLost)
        let effects = m.handle(.setAwayMessage("hold on"))
        XCTAssertFalse(effects.contains(where: {
            if case .sendPresence = $0 { return true } else { return false }
        }), "state changes while disconnected wait for the reconnect re-propose")
        // The reconnect then carries the away state up.
        let reconnectEffects = m.handle(.reconnected)
        XCTAssertTrue(reconnectEffects.contains(.sendPresence(.away, awayMessage: "hold on")))
    }

    func testReconnectedWithoutLossIsIgnored() {
        var m = signedOn()
        XCTAssertTrue(m.handle(.reconnected).isEmpty)
    }

    func testSignOffWhileReconnectingWinsTheRace() {
        var m = signedOn()
        m.handle(.connectionLost)
        m.handle(.signOff)
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertTrue(m.handle(.reconnected).isEmpty,
                      "a late reconnect after deliberate sign-off must not resurrect the session")
        XCTAssertEqual(m.displayState, .offline)
    }
}
