import Foundation

public struct User: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var avatar: Avatar?
    /// Last evidence the server had that this user was signed on. Nil for
    /// accounts that have never signed on.
    public var lastSeenAt: Date?

    public init(id: UUID, handle: String, avatar: Avatar? = nil, lastSeenAt: Date? = nil) {
        self.id = id
        self.handle = handle
        self.avatar = avatar
        self.lastSeenAt = lastSeenAt
    }
}

/// Cartoon-avatar settings: positions into the client-defined skin and hair
/// palettes, plus accessory toggles. Carried on `User` so buddy lists and
/// participants always have everyone's current look.
public struct Avatar: Codable, Hashable, Sendable {
    public var skinTone: Double
    public var hair: Double
    public var glasses: Bool
    public var cigarette: Bool
    /// A row of silver teeth over the mouth.
    public var grills: Bool
    /// Parted in the middle and past the jaw, instead of the short crop.
    public var longHair: Bool
    /// Freehand drawing over the head.
    public var doodle: Doodle?

    public init(skinTone: Double = 0.25, hair: Double = 0.36,
                glasses: Bool = false, cigarette: Bool = false,
                grills: Bool = false, longHair: Bool = false, doodle: Doodle? = nil) {
        self.skinTone = skinTone
        self.hair = hair
        self.glasses = glasses
        self.cigarette = cigarette
        self.grills = grills
        self.longHair = longHair
        self.doodle = doodle
    }

    /// Every field defaults, so avatars encoded before a field existed still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        skinTone = try c.decodeIfPresent(Double.self, forKey: .skinTone) ?? 0.25
        hair = try c.decodeIfPresent(Double.self, forKey: .hair) ?? 0.36
        glasses = try c.decodeIfPresent(Bool.self, forKey: .glasses) ?? false
        cigarette = try c.decodeIfPresent(Bool.self, forKey: .cigarette) ?? false
        grills = try c.decodeIfPresent(Bool.self, forKey: .grills) ?? false
        longHair = try c.decodeIfPresent(Bool.self, forKey: .longHair) ?? false
        doodle = try c.decodeIfPresent(Doodle.self, forKey: .doodle)
    }
}

/// A drawing over the head: fixed-width freehand strokes, each in one color of
/// a client-defined palette. Points are quantized to a grid over the head's
/// box, so the wire does not depend on how a client lays the head out. A typed
/// stroke list needs no sanitizing: `Codable` rejects anything else and
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
    /// Total across all strokes, sized so a maximal doodle fits inside Vapor's
    /// default 16 KB request body.
    public static let maxPoints = 1024

    public var pointCount: Int { strokes.reduce(0) { $0 + $1.points.count / 2 } }

    /// The bounds the server enforces.
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
    /// The other user sent the request and it has not been accepted yet.
    public var incoming: Bool
    /// For incoming pending requests: how many unaccepted requests the
    /// requester has outstanding. Orders the pending list.
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

    /// What the server writes for a user it has found unreachable: away with
    /// no message. `away` is reused rather than adding a state, since an
    /// unknown `PresenceState` case fails to decode and takes the frame with it.
    public static let unreachable = Presence(state: .away)

    /// A message-less away is always the server's mark: clients derive `away`
    /// from having a message and reject an empty one.
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
    /// Spoken rather than typed.
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
    /// An iroh endpoint ticket runs a few hundred characters.
    public static let endpointTicketMaxLength = 1024
    public static let handleLength = 3...16
    /// At most one sign-on push per buddy per rolling window. Pushes only:
    /// local alerts reach a user already watching the buddy list and are never
    /// throttled.
    public static let signOnPushThrottle: TimeInterval = 15 * 60
    /// At most one knock push per sender to a given buddy per rolling window.
    public static let knockPushThrottle: TimeInterval = 15 * 60
    public static let botPromptMaxLength = 2000
    public static let botReplyMaxLength = 1500
    /// Ceilings on the transcript a context tag sends; the newest messages are kept.
    public static let botContextMaxMessages = 60
    public static let botContextMaxCharacters = 8000
    /// A bot answers within this or the dispatcher says so instead.
    public static let botResponseTimeout: TimeInterval = 20
    /// Bot invocations one user may start per rolling minute.
    public static let botInvocationsPerMinute = 6
}
