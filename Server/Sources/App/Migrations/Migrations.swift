import Fluent
import Foundation
import SQLKit
import TotemKit

// Registered in `configure.swift` in this order.

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

/// Messages are never stored server-side; drops the table from older databases.
struct DropMessageStorage: AsyncMigration {
    func prepare(on db: Database) async throws {
        try? await db.schema("messages").delete()
    }

    func revert(on db: Database) async throws {}
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

struct AddBots: AsyncMigration {
    /// Fixed so a fresh database keeps answering as the sender clients cached.
    static let geminiID = UUID(uuidString: "B07B07B0-0000-4000-A000-000000000001")!

    func prepare(on db: Database) async throws {
        // A failed seed on an earlier run leaves the table without a migration
        // record; drop it so the create below cannot collide.
        try? await db.schema(BotModel.schema).delete()
        try await db.schema(BotModel.schema)
            .id()
            .field("handle", .string, .required)
            .field("display_name", .string, .required)
            .field("aliases", .string, .required, .sql(.default("[]")))
            .field("context_aliases", .string)
            .unique(on: "handle")
            .create()
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

/// Adds `context_aliases` to databases that ran `AddBots` before the column
/// existed; a fresh database already has it, hence the tolerated failure.
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

/// Creates `conversations` and backfills a pair row per accepted buddyship, so
/// every 1:1 a client can derive already exists. Uses raw SQL so the migration
/// depends on the schema it creates rather than on the model's current columns.
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

/// Conversations own identity and sittings own liveness; the sessions table is
/// gone. Tolerates the table already being absent.
struct DropSessionStorage: AsyncMigration {
    func prepare(on db: Database) async throws {
        try? await db.schema("sessions").delete()
    }

    func revert(on db: Database) async throws {}
}

/// Sign-on alerts became opt-in when the badge took over showing who is online.
struct SignOnAlertsOptIn: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await UserModel.query(on: db).set(\.$signOnPushes, to: false).update()
    }

    func revert(on db: Database) async throws {}
}

struct AddLastSeen: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserModel.schema).field("last_seen_at", .datetime).update()
    }

    func revert(on db: Database) async throws {
        try await db.schema(UserModel.schema).deleteField("last_seen_at").update()
    }
}
