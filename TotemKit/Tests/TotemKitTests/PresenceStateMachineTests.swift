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

    // MARK: - Idle

    func testBackgroundedFiveMinutesBecomesIdle() {
        var m = signedOn()
        m.handle(.appBackgrounded(at: t(10)))
        XCTAssertEqual(m.displayState, .online, "no idle before threshold")
        m.handle(.tick(at: t(10 + 299)))
        XCTAssertEqual(m.displayState, .online)
        let effects = m.handle(.tick(at: t(10 + 300)))
        XCTAssertEqual(m.displayState, .idle)
        XCTAssertTrue(effects.contains(.sendPresence(.idle, awayMessage: nil)))
    }

    func testForegroundReturnsToOnline() {
        var m = signedOn()
        m.handle(.appBackgrounded(at: t(0)))
        m.handle(.tick(at: t(301)))
        XCTAssertEqual(m.displayState, .idle)
        let effects = m.handle(.appForegrounded(at: t(400)))
        XCTAssertEqual(m.displayState, .online)
        XCTAssertTrue(effects.contains(.sendPresence(.online, awayMessage: nil)))
    }

    func testMacSystemIdleTransitions() {
        var m = signedOn()
        m.handle(.systemIdle(at: t(301)))
        XCTAssertEqual(m.displayState, .idle)
        m.handle(.systemActive(at: t(400)))
        XCTAssertEqual(m.displayState, .online)
    }

    func testSystemIdleWhileSignedOffIsIgnored() {
        var m = PresenceStateMachine()
        m.handle(.systemIdle(at: t0))
        XCTAssertEqual(m.displayState, .offline)
    }

    // MARK: - Away

    func testAwayOverridesOnlineAndIdle() {
        var m = signedOn()
        m.handle(.setAwayMessage("bbl", at: t(1)))
        XCTAssertEqual(m.displayState, .away)
        // Going idle underneath doesn't change the display.
        m.handle(.appBackgrounded(at: t(2)))
        m.handle(.tick(at: t(400)))
        XCTAssertEqual(m.displayState, .away)
        // Clearing away while idle reveals idle, not online.
        m.handle(.clearAwayMessage(at: t(401)))
        XCTAssertEqual(m.displayState, .idle)
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

    // MARK: - Clock skew

    func testBackdatedTickCannotTriggerIdle() {
        var m = signedOn()
        m.handle(.appBackgrounded(at: t(1000)))
        // Clock jumps backwards: a tick dated before the background event.
        m.handle(.tick(at: t(100)))
        XCTAssertEqual(m.displayState, .online, "skewed tick must not compute a bogus idle duration")
    }

    func testForwardSkewThenCorrectionDoesNotIdleEarly() {
        var m = signedOn()
        m.handle(.appBackgrounded(at: t(0)))
        m.handle(.tick(at: t(600)))          // clock briefly wrong, far in the future
        XCTAssertEqual(m.displayState, .idle) // idle per the (wrong) clock — acceptable
        m.handle(.appForegrounded(at: t(50))) // correction: user active, earlier timestamp
        XCTAssertEqual(m.displayState, .online, "activity always clears idle regardless of timestamps")
    }
}
