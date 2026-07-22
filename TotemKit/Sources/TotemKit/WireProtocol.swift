import Foundation

/// Frames sent from client to server over the WebSocket.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// Client proposes a presence change; server is authoritative and echoes via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    case sendMessage(recipientID: UUID, body: String, clientMessageID: UUID)
    /// Message into an existing (group) session the sender belongs to.
    case sendSessionMessage(sessionID: UUID, body: String, clientMessageID: UUID)
    case typing(recipientID: UUID)
}

/// A session plus the users in it — what a client needs to render a group chat.
public struct SessionInfo: Codable, Hashable, Sendable {
    public let session: ChatSession
    public let participants: [User]

    public init(session: ChatSession, participants: [User]) {
        self.session = session
        self.participants = participants
    }

    public var isGroup: Bool { session.participantIDs.count > 2 }
}

/// Frames sent from server to client.
public enum ServerFrame: Codable, Sendable {
    /// Sent on connect: authoritative snapshot of own presence, all buddies'
    /// (keyed by user UUID string — UUID keys would encode as a JSON array),
    /// and any open group sessions the user belongs to.
    case welcome(self_: Presence, buddies: [String: Presence], sessions: [SessionInfo])
    /// A (group) session was created that includes this user.
    case sessionStarted(SessionInfo)
    case presence(userID: UUID, presence: Presence)
    case message(ChatMessage)
    /// Server ack for a sent message, correlating the client-generated ID.
    case messageSent(clientMessageID: UUID, message: ChatMessage)
    case typing(userID: UUID)
    case sessionClosed(sessionID: UUID)
    /// A buddy request arrived (or one of yours was accepted — paired with a
    /// `presence` push). Clients refetch the buddy list rather than patching
    /// local state.
    case buddyRequest(from: User)
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
