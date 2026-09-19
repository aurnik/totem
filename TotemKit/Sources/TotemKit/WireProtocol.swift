import Foundation

/// Client to server. Conversation content travels peer to peer as `PeerFrame`;
/// the server keeps identity, presence, introductions, sittings and bots.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// The server is authoritative and echoes the result via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    case announceEndpoint(ticket: String)
    /// Absolute rather than a toggle, so resending after a reconnect is harmless.
    case viewing(conversationID: UUID?)
    /// Only a bot-tagged message reaches the server; `context` comes from the sender.
    case botQuery(conversationID: UUID, body: String, context: [BotContextMessage]?)
    /// Evidence only: the server ping-verifies before marking anyone away.
    case unreachable(userID: UUID)
    /// Opens the pair's sitting, which the server cannot see traffic for.
    case conversationActive(conversationID: UUID)
}

public struct SessionInfo: Codable, Hashable, Sendable {
    public let session: ChatSession
    public let participants: [User]

    public init(session: ChatSession, participants: [User]) {
        self.session = session
        self.participants = participants
    }

    public var isGroup: Bool { session.participantIDs.count > 2 }
}

/// Server to client. `viewing` and `endpoint` are socket state, never in `welcome`.
public enum ServerFrame: Codable, Sendable {
    /// Buddies are keyed by UUID string, since UUID keys encode as a JSON
    /// array. `freshSignOn` is false only for a reconnect inside the presence
    /// grace window; otherwise the client drops its transcripts.
    case welcome(self_: Presence, buddies: [String: Presence], sessions: [SessionInfo],
                 freshSignOn: Bool, selfAvatar: Avatar?, bots: [Bot]? = nil,
                 latestBuild: String? = nil)
    case sessionStarted(SessionInfo)
    case presence(userID: UUID, presence: Presence)
    case viewing(conversationID: UUID, userID: UUID, viewing: Bool)
    case endpoint(userID: UUID, ticket: String)
    case avatarChanged(userID: UUID, avatar: Avatar)
    case sessionClosed(sessionID: UUID)
    case buddyRequest
    case botMessage(conversationID: UUID, message: ChatMessage)
    case error(String)
}

public enum WireCoder {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
