import Fluent
import Foundation
import TotemKit

/// One row per direction. A pair is mutual when both directions are `accepted`.
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

    static func acceptedBuddyIDs(of userID: UUID, on db: Database) async throws -> [UUID] {
        try await query(on: db)
            .filter(\.$user.$id == userID)
            .filter(\.$status == .accepted)
            .all()
            .map { $0.$buddy.id }
    }
}
