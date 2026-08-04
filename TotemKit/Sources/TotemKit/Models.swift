import Foundation

public struct User: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var displayName: String
    public var avatarURL: URL?
    public var avatar: Avatar?
    public var createdAt: Date

    public init(id: UUID, handle: String, displayName: String, avatarURL: URL? = nil,
                avatar: Avatar? = nil, createdAt: Date) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.avatar = avatar
        self.createdAt = createdAt
    }
}

/// Cartoon-avatar settings: positions (0…1) into the client-defined skin and
/// hair palettes, a hairstyle, and accessory toggles. Rides on the User DTO
/// so buddy lists and session participants always carry everyone's latest
/// look; rendering is a client concern.
public struct Avatar: Codable, Hashable, Sendable {
    public enum Hairstyle: String, Codable, CaseIterable, Sendable {
        case spiky = "default"
        case long
    }

    public var skinTone: Double
    public var hair: Double
    public var hairstyle: Hairstyle
    public var glasses: Bool
    public var cigarette: Bool

    public init(skinTone: Double = 0.25, hair: Double = 0.36, hairstyle: Hairstyle = .spiky,
                glasses: Bool = false, cigarette: Bool = false) {
        self.skinTone = skinTone
        self.hair = hair
        self.hairstyle = hairstyle
        self.glasses = glasses
        self.cigarette = cigarette
    }

    /// Every field defaults, so avatars encoded before a field existed (or by
    /// a newer client with an unknown hairstyle) still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skinTone = try c.decodeIfPresent(Double.self, forKey: .skinTone) ?? 0.25
        hair = try c.decodeIfPresent(Double.self, forKey: .hair) ?? 0.36
        hairstyle = ((try? c.decodeIfPresent(String.self, forKey: .hairstyle))
            .flatMap { $0 }.flatMap(Hairstyle.init(rawValue:))) ?? .spiky
        glasses = try c.decodeIfPresent(Bool.self, forKey: .glasses) ?? false
        cigarette = try c.decodeIfPresent(Bool.self, forKey: .cigarette) ?? false
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

    public init(state: PresenceState, awayMessage: String? = nil) {
        self.state = state
        self.awayMessage = awayMessage
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
    /// Spoken rather than typed. Absent from clients that predate dictation.
    public var dictated: Bool?

    public init(id: UUID, sessionID: UUID, senderID: UUID, body: String, sentAt: Date,
                dictated: Bool? = nil) {
        self.id = id
        self.sessionID = sessionID
        self.senderID = senderID
        self.body = body
        self.sentAt = sentAt
        self.dictated = dictated
    }
}

public enum Limits {
    public static let maxBuddies = 100
    public static let awayMessageMaxLength = 140
    public static let handleLength = 3...16
}
