import Foundation

/// Client-side presence state machine. The server is authoritative; this machine
/// decides what the client should propose and what it should display for itself.
///
/// Pure value type that never reads a clock: every transition is driven by an
/// event, so reconnect races are testable directly.
public struct PresenceStateMachine: Equatable, Sendable {

    public enum Event: Equatable, Sendable {
        case signOn
        case signOff
        case setAwayMessage(String)
        case clearAwayMessage
        /// Socket dropped without a deliberate sign-off.
        case connectionLost
        case reconnected
    }

    public enum Effect: Equatable, Sendable {
        /// Propose this presence to the server (only emitted while signed on and connected).
        case sendPresence(PresenceState, awayMessage: String?)
        case playSignOnSound
        case playSignOffSound
    }

    public private(set) var isSignedOn = false
    /// True between a non-deliberate socket drop and reconnection. While reconnecting
    /// the client does not show itself as offline (spec §10).
    public private(set) var isReconnecting = false
    public private(set) var awayMessage: String?

    public init() {}

    /// What the buddy list shows for self, and what we propose to the server.
    public var displayState: PresenceState {
        guard isSignedOn else { return .offline }
        return awayMessage != nil ? .away : .online
    }

    @discardableResult
    public mutating func handle(_ event: Event) -> [Effect] {
        let before = displayState
        var effects: [Effect] = []

        switch event {
        case .signOn:
            guard !isSignedOn else { break }
            isSignedOn = true
            isReconnecting = false
            effects.append(.playSignOnSound)

        case .signOff:
            guard isSignedOn else { break }
            isSignedOn = false
            isReconnecting = false
            awayMessage = nil
            effects.append(.playSignOffSound)

        case .setAwayMessage(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSignedOn, !trimmed.isEmpty else { break }
            awayMessage = String(trimmed.prefix(Limits.awayMessageMaxLength))

        case .clearAwayMessage:
            awayMessage = nil

        case .connectionLost:
            if isSignedOn { isReconnecting = true }

        case .reconnected:
            guard isSignedOn, isReconnecting else { break }
            isReconnecting = false
            // Re-propose current state; away message survives a reconnect
            // within the same sign-on (spec §6).
            effects.append(.sendPresence(displayState, awayMessage: awayMessage))
        }

        let after = displayState
        if after != before, isSignedOn || before != .offline, !isReconnecting {
            // Sign-off is communicated too (as .offline) so the server need not
            // wait for the heartbeat TTL in the common case (spec §3).
            effects.append(.sendPresence(after, awayMessage: awayMessage))
        }
        return effects
    }
}
