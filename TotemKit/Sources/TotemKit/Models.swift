import Foundation

public struct User: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var avatar: Avatar?

    public init(id: UUID, handle: String, avatar: Avatar? = nil) {
        self.id = id
        self.handle = handle
        self.avatar = avatar
    }
}

/// Cartoon-avatar settings: positions (0…1) into the client-defined skin and
/// hair palettes plus accessory toggles. Rides on the User DTO so buddy lists
/// and session participants always carry everyone's latest look; rendering is
/// a client concern.
public struct Avatar: Codable, Hashable, Sendable {
    public var skinTone: Double
    public var hair: Double
    public var glasses: Bool
    public var cigarette: Bool
    /// Freehand drawing over the head; nil until its owner draws something.
    public var doodle: Doodle?

    public init(skinTone: Double = 0.25, hair: Double = 0.36,
                glasses: Bool = false, cigarette: Bool = false,
                doodle: Doodle? = nil) {
        self.skinTone = skinTone
        self.hair = hair
        self.glasses = glasses
        self.cigarette = cigarette
        self.doodle = doodle
    }

    /// Every field defaults, so avatars encoded before a field existed still
    /// decode; retired fields decode as unknown keys and are dropped.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skinTone = try c.decodeIfPresent(Double.self, forKey: .skinTone) ?? 0.25
        hair = try c.decodeIfPresent(Double.self, forKey: .hair) ?? 0.36
        glasses = try c.decodeIfPresent(Bool.self, forKey: .glasses) ?? false
        cigarette = try c.decodeIfPresent(Bool.self, forKey: .cigarette) ?? false
        doodle = try c.decodeIfPresent(Doodle.self, forKey: .doodle)
    }
}

/// A drawing over the head: fixed-width freehand strokes, each in one colour
/// of a client-defined palette. Points are quantised to a square grid laid
/// over the head's box, so a point costs a few bytes and the wire never
/// depends on how a client lays the head out. It is a stroke list rather than
/// SVG because no platform here renders SVG text natively and a typed list
/// needs no sanitising: `Codable` refuses anything that isn't a stroke, and
/// `isValid` bounds what a stroke may contain.
public struct Doodle: Codable, Hashable, Sendable {
    public struct Stroke: Codable, Hashable, Sendable {
        /// Index into the palette.
        public var color: Int
        /// Flat x0, y0, x1, y1… on the grid.
        public var points: [Int]

        public init(color: Int, points: [Int]) {
            self.color = color
            self.points = points
        }
    }

    public var strokes: [Stroke]

    public init(strokes: [Stroke] = []) {
        self.strokes = strokes
    }

    /// Coordinates run 0..<gridSize on both axes.
    public static let gridSize = 256
    public static let paletteSize = 8
    public static let maxStrokes = 64
    /// Total across all strokes. Sized so a maximal doodle stays well inside
    /// Vapor's default 16 KB request body.
    public static let maxPoints = 1024

    public var pointCount: Int { strokes.reduce(0) { $0 + $1.points.count / 2 } }

    /// The bounds the server enforces; clients keep themselves inside them.
    public var isValid: Bool {
        guard strokes.count <= Self.maxStrokes, pointCount <= Self.maxPoints else { return false }
        return strokes.allSatisfy { stroke in
            (0..<Self.paletteSize).contains(stroke.color)
                && !stroke.points.isEmpty
                && stroke.points.count.isMultiple(of: 2)
                && stroke.points.allSatisfy { (0..<Self.gridSize).contains($0) }
        }
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

    /// What the server writes for a user it has just found unreachable: away,
    /// but with nothing to say. Reusing `away` rather than adding a state keeps
    /// this legible to builds that predate it — an unknown `PresenceState` case
    /// would fail to decode and take the whole frame with it.
    public static let unreachable = Presence(state: .away)

    /// True for the shape above. A user can only go away by writing a message
    /// (`PresenceStateMachine` derives `away` from the message's existence, and
    /// rejects an empty one), so a message-less away is always the server's
    /// mark and never the user's own.
    public var isUnreachableMark: Bool { state == .away && awayMessage == nil }
}

public struct ChatSession: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var participantIDs: [UUID]
    public var startedAt: Date

    public init(id: UUID, participantIDs: [UUID], startedAt: Date) {
        self.id = id
        self.participantIDs = participantIDs
        self.startedAt = startedAt
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

/// Body of `POST /auth/dev`'s response.
public struct LoginResponse: Codable, Sendable {
    public let token: String
    public let user: User

    public init(token: String, user: User) {
        self.token = token
        self.user = user
    }
}

/// Body of `GET`/`POST /push/settings`.
public struct PushSettings: Codable, Sendable {
    public let signOnPushes: Bool

    public init(signOnPushes: Bool) {
        self.signOnPushes = signOnPushes
    }
}

public enum Limits {
    public static let maxBuddies = 100
    public static let awayMessageMaxLength = 140
    /// An iroh endpoint ticket is a couple of hundred characters; anything
    /// past this is not one.
    public static let endpointTicketMaxLength = 1024
    public static let handleLength = 3...16
    /// At most one sign-on *push* per buddy per rolling 15 minutes (spec §7
    /// asked for 30). Pushes alone, because they interrupt someone who isn't
    /// using the app; a local alert only reaches a user already watching the
    /// buddy list, and is raised on every sign-on.
    public static let signOnPushThrottle: TimeInterval = 15 * 60
    public static let botPromptMaxLength = 2000
    public static let botReplyMaxLength = 1500
    /// Ceilings on the transcript a context tag sends. The newest messages are
    /// kept: a conversation long enough to hit these is one where the recent
    /// turns are what the prompt is about.
    public static let botContextMaxMessages = 60
    public static let botContextMaxCharacters = 8000
    /// A bot answers within this or it says so instead.
    public static let botResponseTimeout: TimeInterval = 20
    /// Bot invocations one user may start per rolling minute.
    public static let botInvocationsPerMinute = 6
}
