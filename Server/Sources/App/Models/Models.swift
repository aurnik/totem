import Fluent
import Foundation
import TotemKit
import Vapor

final class UserModel: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "avatar_url") var avatarURL: String?
    /// User setting: push "X signed on" to this user's devices while the
    /// app is closed. On by default, toggleable in the app.
    @Field(key: "sign_on_pushes") var signOnPushes: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(handle: String, displayName: String) {
        self.handle = handle
        self.displayName = displayName
        self.signOnPushes = true
    }

    var dto: TotemKit.User {
        User(
            id: id!,
            handle: handle,
            displayName: displayName,
            avatarURL: avatarURL.flatMap(URL.init(string:)),
            createdAt: createdAt ?? Date()
        )
    }
}

final class TokenModel: Model, @unchecked Sendable {
    static let schema = "tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "value") var value: String
    @Parent(key: "user_id") var user: UserModel

    init() {}

    init(value: String, userID: UUID) {
        self.value = value
        self.$user.id = userID
    }
}

/// One row per direction (spec §5). A pair is mutual when both directions are `accepted`.
final class BuddyModel: Model, @unchecked Sendable {
    static let schema = "buddies"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "buddy_id") var buddy: UserModel
    @Enum(key: "status") var status: BuddyStatus
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, buddyID: UUID, status: BuddyStatus) {
        self.$user.id = userID
        self.$buddy.id = buddyID
        self.status = status
    }
}

final class SessionModel: Model, @unchecked Sendable {
    static let schema = "sessions"

    @ID(key: .id) var id: UUID?
    /// First two participants, kept for the original two-party schema and
    /// still used for 1:1 open-session lookups. `participants` is the source
    /// of truth and holds all members for group sessions.
    @Field(key: "participant_a") var participantA: UUID
    @Field(key: "participant_b") var participantB: UUID
    @Field(key: "participants") var participantsJSON: String
    @Timestamp(key: "started_at", on: .create) var startedAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?

    init() {}

    init(participants: [UUID]) {
        precondition(participants.count >= 2)
        self.participantA = participants[0]
        self.participantB = participants[1]
        self.participants = participants
    }

    convenience init(participantA: UUID, participantB: UUID) {
        self.init(participants: [participantA, participantB])
    }

    var participants: [UUID] {
        get {
            (try? JSONDecoder().decode([UUID].self, from: Data(participantsJSON.utf8)))
                ?? [participantA, participantB]
        }
        set {
            participantsJSON = String(
                decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self)
        }
    }

    var isGroup: Bool { participants.count > 2 }

    func includes(_ userID: UUID) -> Bool {
        participants.contains(userID)
    }

    func peer(of userID: UUID) -> UUID {
        participants.first { $0 != userID } ?? participantA
    }

    var dto: ChatSession {
        ChatSession(id: id!, participantIDs: participants, startedAt: startedAt ?? Date(), endedAt: endedAt)
    }
}

struct AddSessionParticipants: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(SessionModel.schema)
            .field("participants", .string, .required, .sql(.default("[]")))
            .update()
        for session in try await SessionModel.query(on: db).all() where session.participantsJSON == "[]" {
            session.participants = [session.participantA, session.participantB]
            try await session.save(on: db)
        }
    }

    func revert(on db: Database) async throws {
        try await db.schema(SessionModel.schema).deleteField("participants").update()
    }
}

/// APNs device tokens — the one piece of per-device state the server keeps.
/// Message content still never touches storage.
final class PushTokenModel: Model, @unchecked Sendable {
    static let schema = "push_tokens"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "token") var token: String
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}

    init(userID: UUID, token: String) {
        self.$user.id = userID
        self.token = token
    }
}

struct AddPushSupport: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserModel.schema)
            .field("sign_on_pushes", .bool, .required, .sql(.default(true)))
            .update()
        try await db.schema(PushTokenModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token", .string, .required)
            .field("updated_at", .datetime)
            .unique(on: "token")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(PushTokenModel.schema).delete()
        try await db.schema(UserModel.schema).deleteField("sign_on_pushes").update()
    }
}

/// Messages are never stored server-side — pure relay. Drops the table from
/// databases created before that decision.
struct DropMessageStorage: AsyncMigration {
    func prepare(on db: Database) async throws {
        try? await db.schema("messages").delete()
    }

    func revert(on db: Database) async throws {}
}

struct CreateSchema: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserModel.schema)
            .id()
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("avatar_url", .string)
            .field("created_at", .datetime)
            .unique(on: "handle")
            .create()
        try await db.schema(TokenModel.schema)
            .id()
            .field("value", .string, .required)
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .unique(on: "value")
            .create()
        try await db.schema(BuddyModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("buddy_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "buddy_id")
            .create()
        try await db.schema(SessionModel.schema)
            .id()
            .field("participant_a", .uuid, .required)
            .field("participant_b", .uuid, .required)
            .field("started_at", .datetime)
            .field("ended_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(SessionModel.schema).delete()
        try await db.schema(BuddyModel.schema).delete()
        try await db.schema(TokenModel.schema).delete()
        try await db.schema(UserModel.schema).delete()
    }
}
