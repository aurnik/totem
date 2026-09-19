import Foundation

/// Client-side presence state machine: what the client proposes to the
/// authoritative server, and what it displays for itself. A pure value type
/// that never reads a clock, so reconnect races are directly testable.
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
        /// Propose this presence to the server.
        case sendPresence(PresenceState, awayMessage: String?)
        case playSignOnSound
        case playSignOffSound
    }

    public private(set) var isSignedOn = false
    /// True between a non-deliberate drop and reconnection; the client shows
    /// itself as reconnecting rather than offline.
    public private(set) var isReconnecting = false
    public private(set) var awayMessage: String?

    public init() {}

    /// What the buddy list shows for self, and what is proposed to the server.
    /// Away requires a message, so a message-less away can only be the server's
    /// unreachable mark.
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
            // An away message survives a reconnect within the same sign-on.
            effects.append(.sendPresence(displayState, awayMessage: awayMessage))
        }

        let after = displayState
        if after != before, isSignedOn || before != .offline, !isReconnecting {
            // Sign-off is sent as .offline so the server need not wait for the TTL.
            effects.append(.sendPresence(after, awayMessage: awayMessage))
        }
        return effects
    }
}
