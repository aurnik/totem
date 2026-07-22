import Foundation

public struct User: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var displayName: String
    public var avatarURL: URL?
    public var createdAt: Date

    public init(id: UUID, handle: String, displayName: String, avatarURL: URL? = nil, createdAt: Date) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.createdAt = createdAt
    }
}

public enum BuddyStatus: String, Codable, Sendable {
    case pending
    case accepted
}

public struct Buddy: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var user: User
    public var status: BuddyStatus
    /// True when the other user initiated the request and we have not accepted yet.
    public var incoming: Bool
    /// For incoming pending requests: how many open (unaccepted) requests the
    /// requester has outstanding. Drives pending-list ordering.
    public var openRequestCount: Int?

    public init(id: UUID, user: User, status: BuddyStatus, incoming: Bool, openRequestCount: Int? = nil) {
        self.id = id
        self.user = user
        self.status = status
        self.incoming = incoming
        self.openRequestCount = openRequestCount
    }
}

/// Display state for a user, as shown on a buddy list.
public enum PresenceState: String, Codable, Sendable {
    case offline
    case online
    case idle
    case away
}

public struct Presence: Codable, Hashable, Sendable {
    public var state: PresenceState
    public var awayMessage: String?
    public var lastSeenAt: Date?

    public init(state: PresenceState, awayMessage: String? = nil, lastSeenAt: Date? = nil) {
        self.state = state
        self.awayMessage = awayMessage
        self.lastSeenAt = lastSeenAt
    }

    public static let offline = Presence(state: .offline)
}

public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var participantIDs: [UUID]
    public var startedAt: Date
    public var endedAt: Date?

    public init(id: UUID, participantIDs: [UUID], startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.participantIDs = participantIDs
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct ChatMessage: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var sessionID: UUID
    public var senderID: UUID
    public var body: String
    public var sentAt: Date

    public init(id: UUID, sessionID: UUID, senderID: UUID, body: String, sentAt: Date) {
        self.id = id
        self.sessionID = sessionID
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
    }
}

public enum Limits {
    public static let maxBuddies = 100
    public static let awayMessageMaxLength = 140
    public static let handleLength = 3...16
}
