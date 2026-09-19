import Fluent
import Foundation
import TotemKit

/// A conversation is its participant set; the ID is `ConversationID.derive`
/// of that set, so any combination of people names exactly one row. Rows are
/// permanent. Whether a conversation is live is kept in `SittingStore`.
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
