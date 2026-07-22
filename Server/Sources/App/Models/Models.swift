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
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(handle: String, displayName: String) {
        self.handle = handle
        self.displayName = displayName
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
    @Field(key: "participant_a") var participantA: UUID
    @Field(key: "participant_b") var participantB: UUID
    @Timestamp(key: "started_at", on: .create) var startedAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?

    init() {}

    init(participantA: UUID, participantB: UUID) {
        self.participantA = participantA
        self.participantB = participantB
    }

    func includes(_ userID: UUID) -> Bool {
        participantA == userID || participantB == userID
    }

    func peer(of userID: UUID) -> UUID {
        participantA == userID ? participantB : participantA
    }
}

/// Persists for 24h to cover reconnects and offline delivery, then hard-deleted (spec §5).
final class MessageModel: Model, @unchecked Sendable {
    static let schema = "messages"

    @ID(key: .id) var id: UUID?
    @Parent(key: "session_id") var session: SessionModel
    @Field(key: "sender_id") var senderID: UUID
    @Field(key: "body") var body: String
    @Timestamp(key: "sent_at", on: .create) var sentAt: Date?
    @OptionalField(key: "delivered_at") var deliveredAt: Date?

    init() {}

    init(sessionID: UUID, senderID: UUID, body: String) {
        self.$session.id = sessionID
        self.senderID = senderID
        self.body = body
    }

    var dto: ChatMessage {
        ChatMessage(id: id!, sessionID: $session.id, senderID: senderID, body: body, sentAt: sentAt ?? Date())
    }
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
        try await db.schema(MessageModel.schema)
            .id()
            .field("session_id", .uuid, .required, .references("sessions", "id", onDelete: .cascade))
            .field("sender_id", .uuid, .required)
            .field("body", .string, .required)
            .field("sent_at", .datetime)
            .field("delivered_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(MessageModel.schema).delete()
        try await db.schema(SessionModel.schema).delete()
        try await db.schema(BuddyModel.schema).delete()
        try await db.schema(TokenModel.schema).delete()
        try await db.schema(UserModel.schema).delete()
    }
}
