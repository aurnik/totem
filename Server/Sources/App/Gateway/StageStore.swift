import Foundation
import TotemKit

/// Shared stage state for live conversations — the first server-held mutable
/// conversation state. In-memory and single-process like `ConnectionManager`,
/// because none of it needs to outlive a restart: a lost stage just means the
/// next client to open the chat finds an empty one.
actor StageStore {
    enum Key: Hashable {
        case group(UUID)
        case pair(UUID, UUID)

        /// 1:1 keys are order-independent, so either party resolves the same entry.
        static func forPair(_ a: UUID, _ b: UUID) -> Key {
            a.uuidString < b.uuidString ? .pair(a, b) : .pair(b, a)
        }
    }

    private struct Entry {
        var stage: Stage
        /// Captured on write so reaping never needs a database lookup.
        var participants: [UUID]
    }

    private var entries: [Key: Entry] = [:]

    enum Applied {
        case updated(Stage)
        case unchanged
        /// Carries what's actually on the stage, to re-sync whoever acted.
        case rejected(current: Stage?)
    }

    /// Reads, reduces and writes in one actor-isolated step, with no
    /// suspension in between. Splitting these apart would defeat the whole
    /// point of the version check: two actions could both read the same
    /// version, both pass, and both write.
    func apply(_ action: StageAction, expectedVersion: Int?, to key: Key,
               participants: [UUID], at now: Date) -> Applied {
        let current = entries[key]?.stage
        switch StageReducer.reduce(current, action, expectedVersion: expectedVersion, at: now) {
        case .updated(let stage):
            entries[key] = Entry(stage: stage, participants: participants)
            return .updated(stage)
        case .unchanged:
            return .unchanged
        case .rejected:
            return .rejected(current: current)
        }
    }

    func get(_ key: Key) -> Stage? {
        entries[key]?.stage
    }

    func clear(_ key: Key) {
        entries[key] = nil
    }

    /// A 1:1 stage dies with the conversation when either party goes offline,
    /// the same way the session row does.
    func clearPairs(involving userID: UUID) {
        entries = entries.filter { key, _ in
            guard case let .pair(a, b) = key else { return true }
            return a != userID && b != userID
        }
    }

    /// Group stages outlive any individual's presence, so the liveness sweep is
    /// the only thing that ever frees them.
    func groupEntries() -> [(key: Key, participants: [UUID])] {
        entries.compactMap { key, entry in
            guard case .group = key else { return nil }
            return (key, entry.participants)
        }
    }
}
