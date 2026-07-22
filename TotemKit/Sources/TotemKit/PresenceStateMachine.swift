import Foundation

/// Client-side presence state machine. The server is authoritative; this machine
/// decides what the client should propose and what it should display for itself.
///
/// Pure value type with all time injected through events, so it can be tested
/// against clock skew and reconnect races without a real clock.
public struct PresenceStateMachine: Equatable, Sendable {

    public enum Event: Equatable, Sendable {
        case signOn(at: Date)
        case signOff(at: Date)
        case appBackgrounded(at: Date)
        case appForegrounded(at: Date)
        /// macOS: system idle threshold crossed (CGEventSource-driven).
        case systemIdle(at: Date)
        case systemActive(at: Date)
        case setAwayMessage(String, at: Date)
        case clearAwayMessage(at: Date)
        /// Socket dropped without a deliberate sign-off.
        case connectionLost(at: Date)
        case reconnected(at: Date)
        /// Periodic timer; evaluates the background-idle threshold.
        case tick(at: Date)
    }

    public enum Effect: Equatable, Sendable {
        /// Propose this presence to the server (only emitted while signed on and connected).
        case sendPresence(PresenceState, awayMessage: String?)
        case playSignOnSound
        case playSignOffSound
    }

    public static let idleThreshold: TimeInterval = 5 * 60

    public private(set) var isSignedOn = false
    /// True between a non-deliberate socket drop and reconnection. While reconnecting
    /// the client does not show itself as offline (spec §10).
    public private(set) var isReconnecting = false
    public private(set) var awayMessage: String?
    private var isIdle = false
    private var backgroundedAt: Date?
    /// Monotonic guard: the latest timestamp observed. Events dated earlier than
    /// this (clock skew, replays) cannot trigger threshold transitions.
    private var lastEventAt = Date.distantPast

    public init() {}

    /// What the buddy list shows for self, and what we propose to the server.
    public var displayState: PresenceState {
        guard isSignedOn else { return .offline }
        if awayMessage != nil { return .away }
        return isIdle ? .idle : .online
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        let before = displayState
        var effects: [Effect] = []

        switch event {
        case .signOn(let at):
            advanceClock(to: at)
            guard !isSignedOn else { break }
            isSignedOn = true
            isReconnecting = false
            isIdle = false
            backgroundedAt = nil
            effects.append(.playSignOnSound)

        case .signOff(let at):
            advanceClock(to: at)
            guard isSignedOn else { break }
            isSignedOn = false
            isReconnecting = false
            awayMessage = nil
            isIdle = false
            backgroundedAt = nil
            effects.append(.playSignOffSound)

        case .appBackgrounded(let at):
            advanceClock(to: at)
            if isSignedOn && backgroundedAt == nil { backgroundedAt = at }

        case .appForegrounded(let at), .systemActive(let at):
            advanceClock(to: at)
            backgroundedAt = nil
            isIdle = false

        case .systemIdle(let at):
            advanceClock(to: at)
            if isSignedOn { isIdle = true }

        case .setAwayMessage(let message, let at):
            advanceClock(to: at)
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSignedOn, !trimmed.isEmpty else { break }
            awayMessage = String(trimmed.prefix(Limits.awayMessageMaxLength))

        case .clearAwayMessage(let at):
            advanceClock(to: at)
            awayMessage = nil

        case .connectionLost(let at):
            advanceClock(to: at)
            if isSignedOn { isReconnecting = true }

        case .reconnected(let at):
            advanceClock(to: at)
            guard isSignedOn, isReconnecting else { break }
            isReconnecting = false
            // Re-propose current state; away message survives a reconnect
            // within the same sign-on (spec §6).
            effects.append(.sendPresence(displayState, awayMessage: awayMessage))

        case .tick(let at):
            // Reject clock-skewed ticks entirely: a timestamp earlier than one we
            // have already processed must not drive a threshold transition.
            guard at >= lastEventAt else { break }
            advanceClock(to: at)
            if isSignedOn, let since = backgroundedAt,
               at.timeIntervalSince(since) >= Self.idleThreshold {
                isIdle = true
            }
        }

        let after = displayState
        if after != before, isSignedOn || before != .offline, !isReconnecting {
            // Sign-off is communicated too (as .offline) so the server need not
            // wait for the heartbeat TTL in the common case (spec §3).
            effects.append(.sendPresence(after, awayMessage: awayMessage))
        }
        return effects
    }

    private mutating func advanceClock(to date: Date) {
        if date > lastEventAt { lastEventAt = date }
    }
}
