import Foundation

/// Frames sent from client to server over the WebSocket.
public enum ClientFrame: Codable, Sendable {
    case heartbeat
    /// Client proposes a presence change; server is authoritative and echoes via `presence`.
    case setPresence(state: PresenceState, awayMessage: String?)
    case signOff
    /// `dictated` marks a body the sender spoke rather than typed; nil from
    /// clients that predate it, and relayed untouched.
    case sendMessage(recipientID: UUID, body: String, clientMessageID: UUID,
                     dictated: Bool? = nil)
    /// Message into an existing (group) session the sender belongs to.
    case sendSessionMessage(sessionID: UUID, body: String, clientMessageID: UUID,
                            dictated: Bool? = nil)
    case typing(recipientID: UUID)
    /// Live mic audio: raw little-endian Int16 mono PCM at
    /// `AudioWire.sampleRate`, ~100ms per chunk. Relay-only, best-effort —
    /// never stored, never acked, silently dropped for offline recipients.
    case sendAudio(recipientID: UUID, chunk: Data)
    case sendSessionAudio(sessionID: UUID, chunk: Data)
    /// This user can't hear incoming live audio right now (device volume at
    /// zero) — or can again. Sent on transitions while audio is audible in
    /// the chat, so other participants can show a crossed-out speaker.
    case setAudioMuted(recipientID: UUID, muted: Bool)
    case setSessionAudioMuted(sessionID: UUID, muted: Bool)
    /// Drive the conversation's stage. Unlike the pairs above there's one
    /// frame for both shapes: `conversationID` is the peer's user ID for 1:1
    /// and the session ID for groups, and the server works out which.
    /// `expectedVersion` is the stage version the sender was looking at,
    /// required for conditional actions and ignored otherwise.
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
    /// request. Optional associated values decode as nil when absent, so this
    /// stays readable in both directions across versions.
    case welcome(self_: Presence, buddies: [String: Presence], sessions: [SessionInfo],
                 freshSignOn: Bool, selfAvatar: Avatar?)
    /// A (group) session was created that includes this user.
    case sessionStarted(SessionInfo)
    case presence(userID: UUID, presence: Presence)
    case message(ChatMessage)
    /// Server ack for a sent message, correlating the client-generated ID.
    case messageSent(clientMessageID: UUID, message: ChatMessage)
    case typing(userID: UUID)
    /// Live mic audio from a chat participant. `conversationID` is what the
    /// receiving client keys the chat by: the sender's user ID for 1:1, the
    /// session ID for groups.
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
