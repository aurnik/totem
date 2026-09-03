import Foundation

/// Frames sent from client to server over the WebSocket. Nothing
/// conversation-shaped travels here — messages, typing, the stage and mute
/// state go peer to peer as `PeerFrame`s. The server keeps identity,
/// presence, introductions, sittings, bots, pushes and badges.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// Client proposes a presence change; server is authoritative and echoes via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    /// This device's iroh endpoint ticket — how peers dial it, for everything
    /// in a conversation. Socket state, like `viewing`: sent once the
    /// endpoint is online, again after every reconnect, and whenever its
    /// addresses change.
    case announceEndpoint(ticket: String)
    /// The conversation this client has on screen right now — nil when none
    /// (chat list showing, app in the background). Absolute, not a toggle, so
    /// a resend after a reconnect is harmless; the server derives the
    /// transitions and tells the peer of a 1:1. Groups are accepted and
    /// treated as nil.
    case viewing(conversationID: UUID?)
    /// A message that tagged a bot. It went to the humans over the peer
    /// links; this copy is for the server alone, which runs the bot and fans
    /// its reply out as `botMessage`. Bots see nothing that doesn't tag them.
    /// `context` is the conversation so far, attached only when the tag asks
    /// for it — the server keeps no transcript, so the sender's client is the
    /// only party that can supply one. Used for the prompt, never relayed.
    case botQuery(conversationID: UUID, body: String, context: [BotContextMessage]?)
    /// A 1:1 message went unacknowledged over the peer link. The server
    /// ping-verifies the user before marking them away — a client's word
    /// alone is never enough to change what everyone else sees of someone.
    case unreachable(userID: UUID)
    /// Message traffic just started in a pair, on either end — the server
    /// opens the sitting, since it no longer sees the traffic itself.
    case conversationActive(conversationID: UUID)
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
    /// and any open group sessions the user belongs to. `freshSignOn` is true
    /// when the server considered this user offline before the connect — the
    /// previous online session ended, so the client must drop its transcripts;
    /// false means a reconnect within the presence grace window.
    /// `selfAvatar` is the account's stored avatar (nil if it has never
    /// published one), so a client reconciles its own without a separate
    /// request. `bots` is the registry of taggable bots this server runs —
    /// clients bold their tags and render their replies from it, and a server
    /// with none configured simply sends none. `latestBuild` is the newest
    /// build available to testers, so a client behind it can say so — the
    /// server is told at release time and sends nothing when it hasn't been.
    /// Optional associated values decode as nil when absent, so this stays
    /// readable in both directions across versions.
    case welcome(self_: Presence, buddies: [String: Presence], sessions: [SessionInfo],
                 freshSignOn: Bool, selfAvatar: Avatar?, bots: [Bot]? = nil,
                 latestBuild: String? = nil)
    /// A (group) session was created that includes this user.
    case sessionStarted(SessionInfo)
    case presence(userID: UUID, presence: Presence)
    /// The peer of this 1:1 conversation opened it on screen, or left it —
    /// including by their socket dropping. Connection state, not presence: it
    /// is never in `welcome`, so a reconnecting client is told again.
    case viewing(conversationID: UUID, userID: UUID, viewing: Bool)
    /// A buddy's or group co-participant's peer endpoint. Connection state
    /// like `viewing`: never in `welcome`, but a connecting client is sent
    /// every one currently known; a peer going offline retires theirs.
    case endpoint(userID: UUID, ticket: String)
    /// A buddy (or group co-participant) published a new avatar, or signed on
    /// carrying one the recipient's cached buddy list predates. Clients patch
    /// their cached copy — nothing else about the user changed.
    case avatarChanged(userID: UUID, avatar: Avatar)
    case sessionClosed(sessionID: UUID)
    /// A buddy request arrived (or one of yours was accepted — paired with a
    /// `presence` push). Clients refetch the buddy list rather than patching
    /// local state.
    case buddyRequest
    /// A bot answered in a conversation. `message.senderID` is the bot's ID,
    /// which clients resolve against the registry from `welcome`.
    /// `conversationID` is the derived conversation ID — the same value as
    /// `message.sessionID`, kept on the frame for decode compatibility with
    /// builds that still read it. Sent to everyone in the conversation, the
    /// tagger included.
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
