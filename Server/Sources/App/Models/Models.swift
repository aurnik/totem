import Fluent
import Foundation
import SQLKit
import TotemKit
import Vapor

final class UserModel: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    /// Cartoon-avatar settings as JSON (TotemKit.Avatar), set by the client.
    @OptionalField(key: "avatar") var avatarJSON: String?
    /// User setting: push "X signed on" to this user's devices while the
    /// app is closed. On by default, toggleable in the app.
    @Field(key: "sign_on_pushes") var signOnPushes: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(handle: String) {
        self.handle = handle
        self.displayName = handle
        self.signOnPushes = true
    }

    var dto: TotemKit.User {
        User(
            id: id!,
            handle: handle,
            avatar: avatarJSON.flatMap {
                try? JSONDecoder().decode(Avatar.self, from: Data($0.utf8))
            }
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

    init() {}

    init(userID: UUID, buddyID: UUID, status: BuddyStatus) {
        self.$user.id = userID
        self.$buddy.id = buddyID
        self.status = status
    }
}

/// The session era's storage is gone: conversations own identity, sittings
/// own liveness. Tolerates the table already being absent, because a fresh
/// database never creates it.
struct DropSessionStorage: AsyncMigration {
    func prepare(on db: Database) async throws {
        try? await db.schema("sessions").delete()
    }

    func revert(on db: Database) async throws {}
}

/// A conversation is its participant set, and its ID is derived from it
/// (`ConversationID.derive`), so any combination of people names exactly one
/// row. Rows are permanent and idempotent — creating the same combination
/// twice returns the same row — and carry no lifetime state: whether a
/// conversation is *live* is a fact about the present, kept in `SittingStore`.
final class ConversationModel: Model, @unchecked Sendable {
    static let schema = "conversations"

    @ID(custom: "id", generatedBy: .user) var id: UUID?
    @Field(key: "participants") var participantsJSON: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(participants: [UUID]) {
        precondition(participants.count >= 2)
        self.id = ConversationID.derive(participants)
        self.participants = participants
    }

    var participants: [UUID] {
        get {
            (try? JSONDecoder().decode([UUID].self, from: Data(participantsJSON.utf8))) ?? []
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
        participants.first { $0 != userID } ?? userID
    }
}

/// Creates `conversations` and backfills a pair conversation per accepted
/// buddyship, so every 1:1 a client can open already has its row — a derived
/// ID arriving on the wire can't be reversed into participants, so the row
/// has to exist before anyone names it. Reads and writes raw SQL throughout:
/// seeding through a model type couples the migration to the model's *current*
/// columns rather than the schema this migration sees, which passes on every
/// already-migrated database and dies on the next fresh one (production being
/// the only fresh database that matters).
struct AdoptDerivedConversations: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(ConversationModel.schema)
            .field("id", .uuid, .identifier(auto: false))
            .field("participants", .string, .required, .sql(.default("[]")))
            .field("created_at", .datetime)
            .create()
        guard let sql = db as? SQLDatabase else { return }
        let rows = try await sql
            .raw("SELECT user_id, buddy_id FROM buddies WHERE status = 'accepted'")
            .all()
        var seen = Set<UUID>()
        for row in rows {
            guard let a = UUID(uuidString: try row.decode(column: "user_id", as: String.self)),
                  let b = UUID(uuidString: try row.decode(column: "buddy_id", as: String.self)),
                  a != b
            else { continue }
            let id = ConversationID.derive([a, b])
            // Buddyships are one row per direction; both derive the same ID.
            guard seen.insert(id).inserted else { continue }
            let participants = String(
                decoding: try JSONEncoder().encode([a, b]), as: UTF8.self)
            try await sql.raw("""
                INSERT OR IGNORE INTO conversations (id, participants)
                VALUES (\(bind: id.uuidString), \(bind: participants))
                """).run()
        }
    }

    func revert(on db: Database) async throws {
        try await db.schema(ConversationModel.schema).delete()
    }
}

/// A bot's durable identity. The row's ID becomes `ChatMessage.senderID` on
/// everything it says, so it has to be stable across restarts — clients cache
/// bots by ID to render their bubbles.
///
/// `endpoint`, `secret`, and `owner_id` are unused by built-in bots and exist
/// for user-registered webhook bots: same table, same registry, different
/// `BotBackend`.
final class BotModel: Model, @unchecked Sendable {
    static let schema = "bots"

    @ID(key: .id) var id: UUID?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    /// JSON array of tags including the leading "@" — same string-column
    /// pattern as `sessions.participants`.
    @Field(key: "aliases") var aliasesJSON: String
    /// Subset of `aliases` whose use also sends the conversation so far.
    @OptionalField(key: "context_aliases") var contextAliasesJSON: String?
    @Field(key: "kind") var kind: String
    @OptionalField(key: "endpoint") var endpoint: String?
    @OptionalField(key: "secret") var secret: String?
    @OptionalField(key: "owner_id") var ownerID: UUID?

    init() {}

    init(id: UUID? = nil, handle: String, displayName: String, aliases: [String],
         contextAliases: [String] = [], kind: BotKind = .builtin) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.kind = kind.rawValue
        self.aliases = aliases
        self.contextAliases = contextAliases
    }

    var aliases: [String] {
        get { Self.decode(aliasesJSON) }
        set { aliasesJSON = Self.encode(newValue) }
    }

    var contextAliases: [String] {
        get { contextAliasesJSON.map(Self.decode) ?? [] }
        set { contextAliasesJSON = Self.encode(newValue) }
    }

    private static func decode(_ json: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
    }

    private static func encode(_ values: [String]) -> String {
        String(decoding: (try? JSONEncoder().encode(values.map { $0.lowercased() }))
            ?? Data("[]".utf8), as: UTF8.self)
    }

    var dto: TotemKit.Bot {
        Bot(id: id!, handle: handle, displayName: displayName,
            aliases: aliases, contextAliases: contextAliases)
    }
}

enum BotKind: String {
    case builtin
    /// Reserved: a user-registered bot reached at `endpoint`.
    case webhook
}

struct AddBots: AsyncMigration {
    /// Fixed so a redeploy — or a fresh database — keeps answering as the same
    /// sender clients already have cached.
    static let geminiID = UUID(uuidString: "B07B07B0-0000-4000-A000-000000000001")!

    func prepare(on db: Database) async throws {
        // A previous run of this migration created the table and then failed
        // seeding, which leaves the table behind but the migration unrecorded —
        // so creating it again would fail on "already exists". Dropping first
        // is safe here and only here: at this point the table holds seed rows
        // and nothing else.
        try? await db.schema(BotModel.schema).delete()
        try await db.schema(BotModel.schema)
            .id()
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("aliases", .string, .required, .sql(.default("[]")))
            .field("context_aliases", .string)
            .field("kind", .string, .required, .sql(.default("builtin")))
            .field("endpoint", .string)
            .field("secret", .string)
            .field("owner_id", .uuid, .references("users", "id", onDelete: .cascade))
            .unique(on: "handle")
            .create()

        // Seeding goes through BotModel, so every column the model declares has
        // to exist by now. Splitting a column into a later migration broke this
        // on any database that had not already run it: the model had the field,
        // the fresh table did not, and boot died in the migrator.
        try await BotModel(
            id: Self.geminiID, handle: "gemini", displayName: "Gemini",
            aliases: ["@gemini", "@g", "@gemini_", "@g_"],
            contextAliases: ["@gemini_", "@g_"]
        ).create(on: db)
    }

    func revert(on db: Database) async throws {
        try await db.schema(BotModel.schema).delete()
    }
}

/// Trailing-underscore tags send the conversation along with the prompt.
///
/// Only does anything for a database that ran `AddBots` before it grew the
/// column — a fresh one already has it, and adding it twice is an error, hence
/// the tolerated failure rather than an unconditional update.
struct AddBotContextAliases: AsyncMigration {
    func prepare(on db: Database) async throws {
        try? await db.schema(BotModel.schema).field("context_aliases", .string).update()
        if let gemini = try await BotModel.query(on: db).filter(\.$handle == "gemini").first() {
            gemini.aliases = ["@gemini", "@g", "@gemini_", "@g_"]
            gemini.contextAliases = ["@gemini_", "@g_"]
            try await gemini.save(on: db)
        }
    }

    func revert(on db: Database) async throws {
        try await db.schema(BotModel.schema).deleteField("context_aliases").update()
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

struct AddAvatar: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserModel.schema).field("avatar", .string).update()
    }

    func revert(on db: Database) async throws {
        try await db.schema(UserModel.schema).deleteField("avatar").update()
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
    }

    func revert(on db: Database) async throws {
        try await db.schema(BuddyModel.schema).delete()
        try await db.schema(TokenModel.schema).delete()
        try await db.schema(UserModel.schema).delete()
    }
}
