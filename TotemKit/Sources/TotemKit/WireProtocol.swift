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
    /// Live mic audio: raw little-endian Int16 mono PCM at
    /// `AudioWire.sampleRate`, ~100ms per chunk. Relay-only, best-effort —
    /// never stored, never acked, silently dropped for offline recipients.
    case streamAudio(conversationID: UUID, chunk: Data)
    /// This user can't hear incoming live audio right now (device volume at
    /// zero) — or can again. Sent on transitions while audio is audible in
    /// the chat, so other participants can show a crossed-out speaker.
    case setMuted(conversationID: UUID, muted: Bool)
    /// Superseded by `send`/`streamAudio`/`setMuted`: the pre-derived-ID
    /// frames, one per conversation shape, addressed by peer for 1:1 and by
    /// session for groups. Still accepted so installed builds keep working
    /// until they're expired; new clients never send them.
    case sendMessage(recipientID: UUID, body: String, clientMessageID: UUID,
                     dictated: Bool? = nil, botContext: [BotContextMessage]? = nil)
    case sendSessionMessage(sessionID: UUID, body: String, clientMessageID: UUID,
                            dictated: Bool? = nil, botContext: [BotContextMessage]? = nil)
    case sendAudio(recipientID: UUID, chunk: Data)
    case sendSessionAudio(sessionID: UUID, chunk: Data)
    case setAudioMuted(recipientID: UUID, muted: Bool)
    case setSessionAudioMuted(sessionID: UUID, muted: Bool)
    /// Typing stays peer-addressed: it's 1:1-only, and the recipient is the
    /// address, not the conversation.
    case typing(recipientID: UUID)
    /// Drive the conversation's stage. `conversationID` is the derived
    /// conversation ID; the server also still resolves a peer's user ID here,
    /// the pre-derived-ID convention installed builds send. `expectedVersion`
    /// is the stage version the sender was looking at, required for
    /// conditional actions and ignored otherwise.
    case stageAction(conversationID: UUID, action: StageAction, expectedVersion: Int?)
    /// Ask for the current stage — sent when a conversation is opened, and
    /// again after a reconnect, since stage pushes during the gap were missed.
    case requestStage(conversationID: UUID)
    case closeStage(conversationID: UUID)
}

public enum AudioWire {
    public static let sampleRate: Double = 16_000
    /// ~1s of PCM — anything larger is malformed and dropped by the server.
    public static let chunkMaxBytes = 32_768
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
    /// Live mic audio from a chat participant. `conversationID` is what the
    /// receiving client keys the chat by: the derived conversation ID for
    /// frames sent the unified way — or, relayed from an installed build's
    /// peer-addressed frame, the sender's user ID, which only a same-era
    /// client keys correctly.
    case audio(conversationID: UUID, senderID: UUID, chunk: Data)
    /// A chat participant's device went (or stopped being) unable to play
    /// live audio. Same `conversationID` keying as `audio`.
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
    /// The conversation's stage, authoritative. Same `conversationID` keying as
    /// `audio`. `senderID` is whoever acted, and nil when this is a snapshot
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
