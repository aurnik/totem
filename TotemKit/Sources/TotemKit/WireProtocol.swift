import Foundation

/// Frames sent from client to server over the WebSocket.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// Client proposes a presence change; server is authoritative and echoes via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    case sendMessage(recipientID: UUID, body: String, clientMessageID: UUID)
    case typing(recipientID: UUID)
}

/// Frames sent from server to client.
public enum ServerFrame: Codable, Sendable {
    /// Sent on connect: authoritative snapshot of own presence and all buddies',
    /// keyed by user UUID string (UUID keys would encode as a JSON array).
    case welcome(self_: Presence, buddies: [String: Presence])
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
