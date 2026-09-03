import Foundation

/// Frames sent from client to server over the WebSocket.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// Client proposes a presence change; server is authoritative and echoes via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    /// The one way to say something, whatever the conversation's shape:
    /// `conversationID` is the derived ID (`ConversationID.derive`) both
    /// sides compute from the participant set. `dictated` marks a body the
    /// sender spoke rather than typed; nil from clients that predate it, and
    /// relayed untouched. `botContext` is the conversation so far, attached
    /// only when the body tags a bot with one of its context aliases — the
    /// server keeps no transcript, so the sender's client is the only party
    /// that can supply one. It is used for the bot prompt and nothing else:
    /// never relayed, never stored.
    case send(conversationID: UUID, body: String, clientMessageID: UUID,
              dictated: Bool? = nil, botContext: [BotContextMessage]? = nil)
    /// This device's iroh endpoint ticket — how peers dial it for live voice,
    /// which never crosses the server. Socket state, like `viewing`: sent once
    /// the endpoint is online, again after every reconnect, and whenever its
    /// addresses change.
    case announceEndpoint(ticket: String)
    /// This user can't hear incoming live audio right now (device volume at
    /// zero) — or can again. Sent on transitions while audio is audible in
    /// the chat, so other participants can show a crossed-out speaker.
    case setMuted(conversationID: UUID, muted: Bool)
    /// Typing stays peer-addressed: it's 1:1-only, and the recipient is the
    /// address, not the conversation.
    case typing(recipientID: UUID)
    /// The conversation this client has on screen right now — nil when none
    /// (chat list showing, app in the background). Absolute, not a toggle, so
    /// a resend after a reconnect is harmless; the server derives the
    /// transitions and tells the peer of a 1:1. Groups are accepted and
    /// treated as nil.
    case viewing(conversationID: UUID?)
    /// Drive the conversation's stage. `expectedVersion` is the stage version
    /// the sender was looking at, required for conditional actions and
    /// ignored otherwise.
    case stageAction(conversationID: UUID, action: StageAction, expectedVersion: Int?)
    /// Ask for the current stage — sent when a conversation is opened, and
    /// again after a reconnect, since stage pushes during the gap were missed.
    case requestStage(conversationID: UUID)
    case closeStage(conversationID: UUID)
    /// A message that tagged a bot. It went to the humans over the peer
    /// links; this copy is for the server alone, which runs the bot and fans
    /// its reply out as `botMessage`. Bots see nothing that doesn't tag them.
    /// `context` is as on `send`: used for the prompt, never relayed.
    case botQuery(conversationID: UUID, body: String, context: [BotContextMessage]?)
    /// A 1:1 message found no peer link to travel on. The server ping-verifies
    /// the user before marking them away — a client's word alone is never
    /// enough to change what everyone else sees of someone.
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
    case message(ChatMessage)
    /// Server ack for a sent message, correlating the client-generated ID.
    case messageSent(clientMessageID: UUID, message: ChatMessage)
    case typing(userID: UUID)
    /// The peer of this 1:1 conversation opened it on screen, or left it —
    /// including by their socket dropping. Connection state, not presence: it
    /// is never in `welcome`, so a reconnecting client is told again.
    case viewing(conversationID: UUID, userID: UUID, viewing: Bool)
    /// A buddy's or group co-participant's live-voice endpoint. Connection
    /// state like `viewing`: never in `welcome`, but a connecting client is
    /// sent every one currently known; a peer going offline retires theirs.
    case endpoint(userID: UUID, ticket: String)
    /// A chat participant's device went (or stopped being) unable to play
    /// live audio, keyed by the conversation ID.
    case audioMuted(conversationID: UUID, userID: UUID, muted: Bool)
    /// A buddy (or group co-participant) published a new avatar, or signed on
    /// carrying one the recipient's cached buddy list predates. Clients patch
    /// their cached copy — nothing else about the user changed.
    case avatarChanged(userID: UUID, avatar: Avatar)
    case sessionClosed(sessionID: UUID)
    /// A buddy request arrived (or one of yours was accepted — paired with a
    /// `presence` push). Clients refetch the buddy list rather than patching
    /// local state.
    case buddyRequest
    /// The conversation's stage, authoritative, keyed by the conversation ID.
    /// `senderID` is whoever acted, and nil when this is a snapshot
    /// reply or a re-sync after a rejected action — clients only post a
    /// transcript notice when someone actually did something. A nil `stage`
    /// means the stage is empty.
    case stage(conversationID: UUID, senderID: UUID?, stage: Stage?)
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
