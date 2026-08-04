import XCTest
@testable import TotemKit

final class PresenceStateMachineTests: XCTestCase {

    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func t(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func signedOn() -> PresenceStateMachine {
        var m = PresenceStateMachine()
        m.handle(.signOn(at: t0))
        return m
    }

    // MARK: - Basic transitions

    func testStartsOffline() {
        XCTAssertEqual(PresenceStateMachine().displayState, .offline)
    }

    func testSignOnGoesOnlineAndPlaysSound() {
        var m = PresenceStateMachine()
        let effects = m.handle(.signOn(at: t0))
        XCTAssertEqual(m.displayState, .online)
        XCTAssertTrue(effects.contains(.playSignOnSound))
        XCTAssertTrue(effects.contains(.sendPresence(.online, awayMessage: nil)))
    }

    func testSignOffGoesOfflineNotifiesServerAndPlaysSound() {
        var m = signedOn()
        let effects = m.handle(.signOff(at: t(10)))
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertTrue(effects.contains(.playSignOffSound))
        // Explicit sign-off proposes offline so the server doesn't wait out the TTL.
        XCTAssertTrue(effects.contains(.sendPresence(.offline, awayMessage: nil)))
    }

    func testDuplicateSignOnIsIgnored() {
        var m = signedOn()
        let effects = m.handle(.signOn(at: t(5)))
        XCTAssertTrue(effects.isEmpty)
        XCTAssertEqual(m.displayState, .online)
    }

    func testSignOffWhenOfflineIsIgnored() {
        var m = PresenceStateMachine()
        XCTAssertTrue(m.handle(.signOff(at: t0)).isEmpty)
    }

    // MARK: - Away

    func testAwayOverridesOnline() {
        var m = signedOn()
        m.handle(.setAwayMessage("bbl", at: t(1)))
        XCTAssertEqual(m.displayState, .away)
    }

    func testClearAwayReturnsToOnline() {
        var m = signedOn()
        m.handle(.setAwayMessage("lunch", at: t(1)))
        let effects = m.handle(.clearAwayMessage(at: t(2)))
        XCTAssertEqual(m.displayState, .online)
        XCTAssertTrue(effects.contains(.sendPresence(.online, awayMessage: nil)))
    }

    func testSignOffClearsAwayMessage() {
        var m = signedOn()
        m.handle(.setAwayMessage("brb", at: t(1)))
        m.handle(.signOff(at: t(2)))
        XCTAssertNil(m.awayMessage)
        m.handle(.signOn(at: t(3)))
        XCTAssertEqual(m.displayState, .online, "away does not survive sign-off")
    }

    func testAwayMessageTruncatedTo140() {
        var m = signedOn()
        m.handle(.setAwayMessage(String(repeating: "x", count: 200), at: t(1)))
        XCTAssertEqual(m.awayMessage?.count, Limits.awayMessageMaxLength)
    }

    func testEmptyAwayMessageIgnored() {
        var m = signedOn()
        m.handle(.setAwayMessage("   ", at: t(1)))
        XCTAssertEqual(m.displayState, .online)
        XCTAssertNil(m.awayMessage)
    }

    // MARK: - Reconnect races

    func testConnectionLossDoesNotShowOffline() {
        var m = signedOn()
        m.handle(.connectionLost(at: t(10)))
        XCTAssertTrue(m.isReconnecting)
        XCTAssertEqual(m.displayState, .online, "reconnecting must not display as offline (spec §10)")
    }

    func testAwayMessageSurvivesReconnect() {
        var m = signedOn()
        m.handle(.setAwayMessage("afk", at: t(1)))
        m.handle(.connectionLost(at: t(10)))
        let effects = m.handle(.reconnected(at: t(20)))
        XCTAssertEqual(m.displayState, .away)
        XCTAssertTrue(effects.contains(.sendPresence(.away, awayMessage: "afk")),
                      "reconnect re-proposes current state so the server snapshot recovers")
    }

    func testNoPresenceSentWhileReconnecting() {
        var m = signedOn()
        m.handle(.connectionLost(at: t(10)))
        let effects = m.handle(.setAwayMessage("hold on", at: t(11)))
        XCTAssertFalse(effects.contains(where: {
            if case .sendPresence = $0 { return true } else { return false }
        }), "state changes while disconnected wait for the reconnect re-propose")
        // The reconnect then carries the away state up.
        let reconnectEffects = m.handle(.reconnected(at: t(12)))
        XCTAssertTrue(reconnectEffects.contains(.sendPresence(.away, awayMessage: "hold on")))
    }

    func testReconnectedWithoutLossIsIgnored() {
        var m = signedOn()
        XCTAssertTrue(m.handle(.reconnected(at: t(5))).isEmpty)
    }

    func testSignOffWhileReconnectingWinsTheRace() {
        var m = signedOn()
        m.handle(.connectionLost(at: t(10)))
        m.handle(.signOff(at: t(11)))
        XCTAssertEqual(m.displayState, .offline)
        XCTAssertTrue(m.handle(.reconnected(at: t(12))).isEmpty,
                      "a late reconnect after deliberate sign-off must not resurrect the session")
        XCTAssertEqual(m.displayState, .offline)
    }
}
