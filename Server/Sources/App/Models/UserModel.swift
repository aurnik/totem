import Fluent
import Foundation
import TotemKit
import Vapor

final class UserModel: Model, Content, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "handle") var handle: String
    @Field(key: "display_name") var displayName: String
    /// `TotemKit.Avatar` as JSON, set by the client.
    @OptionalField(key: "avatar") var avatarJSON: String?
    /// Alert this user when a buddy signs on. Off by default; the icon badge
    /// already counts who is online.
    @Field(key: "sign_on_pushes") var signOnPushes: Bool
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    /// Stamped on sign-on, heartbeat, and deliberate sign-off.
    @OptionalField(key: "last_seen_at") var lastSeenAt: Date?

    init() {}

    init(handle: String) {
        self.handle = handle
        self.displayName = handle
        self.signOnPushes = false
    }

    var dto: TotemKit.User {
        User(
            id: id!,
            handle: handle,
            avatar: avatarJSON.flatMap {
                try? JSONDecoder().decode(Avatar.self, from: Data($0.utf8))
            },
            lastSeenAt: lastSeenAt
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

/// APNs device tokens, the only per-device state the server keeps.
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
