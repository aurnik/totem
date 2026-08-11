import Foundation
import TotemKit

/// Shared stage state for live conversations — the first server-held mutable
/// conversation state. In-memory and single-process like `ConnectionManager`,
/// because none of it needs to outlive a restart: a lost stage just means the
/// next client to open the chat finds an empty one.
///
/// Keyed by conversation ID — derived from the participant set, so both
/// parties of a 1:1 resolve the same entry without any pair-ordering rule.
actor StageStore {
    private struct Entry {
        var stage: Stage
        /// Captured on write so shape checks and reaping never need a
        /// database lookup — a pair has two participants, a group more.
        var participants: [UUID]
    }

    private var entries: [UUID: Entry] = [:]

    enum Applied {
        case updated(Stage)
        case unchanged
        /// The stage emptied itself — a video running out, not someone
        /// pressing close.
        case cleared
        /// Carries what's actually on the stage, to re-sync whoever acted.
        case rejected(current: Stage?)
    }

    /// Reads, reduces and writes in one actor-isolated step, with no
    /// suspension in between. Splitting these apart would defeat the whole
    /// point of the version check: two actions could both read the same
    /// version, both pass, and both write.
    func apply(_ action: StageAction, by actorID: UUID, expectedVersion: Int?,
               to conversationID: UUID, participants: [UUID], at now: Date) -> Applied {
        let current = entries[conversationID]?.stage
        switch StageReducer.reduce(current, action, by: actorID,
                                   expectedVersion: expectedVersion, at: now) {
        case .updated(let stage):
            entries[conversationID] = Entry(stage: stage, participants: participants)
            return .updated(stage)
        case .unchanged:
            return .unchanged
        case .cleared:
            entries[conversationID] = nil
            return .cleared
        case .rejected:
            return .rejected(current: current)
        }
    }

    func get(_ conversationID: UUID) -> Stage? {
        entries[conversationID]?.stage
    }

    func clear(_ conversationID: UUID) {
        entries[conversationID] = nil
    }

    /// A 1:1 stage dies when either party goes offline. Unconditional rather
    /// than tied to the sitting's death: a stage can exist with no message
    /// traffic at all, and therefore with no sitting to die.
    func clearPairs(involving userID: UUID) {
        entries = entries.filter { _, entry in
            entry.participants.count > 2 || !entry.participants.contains(userID)
        }
    }

    /// A game needs both its players, so it dies when either one goes. 1:1
    /// stages are already covered by `clearPairs`; this is the group case,
    /// which otherwise survives an individual signing off. Returns what it
    /// cleared so the caller can tell the rest of the group.
    func clearGames(involving userID: UUID) -> [(conversationID: UUID, participants: [UUID])] {
        let ended = entries.compactMap { id, entry -> (conversationID: UUID, participants: [UUID])? in
            guard entry.participants.count > 2, case .four(let game) = entry.stage.state,
                  game.red == userID || game.yellow == userID
            else { return nil }
            return (id, entry.participants)
        }
        for (id, _) in ended {
            entries[id] = nil
        }
        return ended
    }
}
