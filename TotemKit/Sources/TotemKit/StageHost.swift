import Foundation

/// Who decides what's on a stage now that no server holds it: the owner
/// (`Stage.ownerID`), whose device is the one place the reducer runs. Everyone
/// else sends their actions to the owner and renders whatever the owner
/// broadcasts back. One writer makes the version check trivially serial;
/// `expectedVersion` still travels so a stale conditional action is dropped
/// rather than applied to a stage that has moved.
///
/// Pure: every entry point takes the local copy of the stage and the local
/// user, and answers with the effects to carry out. A `broadcast` is both the
/// new local stage and what every participant is sent; nothing else changes
/// the local copy except accepting a broadcast from the owner (`accepts`).
public enum StageHost {
    public enum Effect: Hashable, Sendable {
        /// Owner → everyone, the local user included: this is the stage now.
        case broadcast(Stage?, actorID: UUID?)
        /// Owner → one participant, quietly: what's actually on the stage.
        case resync(Stage?, to: UUID)
        /// Not the owner: the action goes to whoever is.
        case forward(StageAction, expectedVersion: Int?, to: UUID)
        case forwardClose(to: UUID)
    }

    /// The local user acts. An empty stage is theirs to claim, so the reducer
    /// runs here and they become owner; a stage someone else holds gets the
    /// action forwarded instead.
    public static func act(_ action: StageAction, on current: Stage?, by selfID: UUID,
                           at now: Date) -> [Effect] {
        let expectedVersion = action.isConditional ? current?.version : nil
        if let current, current.ownerID != selfID {
            return [.forward(action, expectedVersion: expectedVersion, to: current.ownerID)]
        }
        return host(action, expectedVersion: expectedVersion, by: selfID, on: current,
                    resyncing: nil, at: now)
    }

    /// A participant's action arrived. Hosted only when this user owns the
    /// stage; otherwise the sender is aiming at the wrong device and is told
    /// what's really there, which names the real owner.
    public static func receive(_ action: StageAction, expectedVersion: Int?, from actorID: UUID,
                               on current: Stage?, selfID: UUID, at now: Date) -> [Effect] {
        guard let current, current.ownerID == selfID else {
            return [.resync(current, to: actorID)]
        }
        return host(action, expectedVersion: expectedVersion, by: actorID, on: current,
                    resyncing: actorID, at: now)
    }

    private static func host(_ action: StageAction, expectedVersion: Int?, by actorID: UUID,
                             on current: Stage?, resyncing: UUID?, at now: Date) -> [Effect] {
        switch StageReducer.reduce(current, action, by: actorID,
                                   expectedVersion: expectedVersion, at: now) {
        case .updated(let stage):
            return [.broadcast(stage, actorID: actorID)]
        case .unchanged:
            return []
        case .cleared:
            // Nobody chose this — the video ran out, the board timed out — so
            // it goes out unattributed and posts no notice.
            return [.broadcast(nil, actorID: nil)]
        case .rejected:
            // The local user acted on the truth and was refused; there's
            // nothing to correct. A peer acted on a stale copy.
            return resyncing.map { [.resync(current, to: $0)] } ?? []
        }
    }

    /// Whether a stage broadcast from `senderID` replaces the local copy. Only
    /// the owner's word counts for a stage; an empty stage is anyone's to
    /// fill; and when two claims collide — both started something at once
    /// from empty — the lower user ID holds it, a rule every participant can
    /// apply alone so all of them converge without a further round trip.
    public static func accepts(_ stage: Stage?, from senderID: UUID, on current: Stage?,
                               selfID: UUID) -> Bool {
        guard let stage else {
            return current.map { $0.ownerID == senderID } ?? false
        }
        guard stage.ownerID == senderID else { return false }
        guard let current else { return true }
        return current.ownerID == senderID
            || senderID.uuidString < current.ownerID.uuidString
    }

    /// Someone opened the chat or came back from a drop and asked what's on.
    /// Only the owner answers; silence means there is no stage.
    public static func receiveRequest(from requesterID: UUID, on current: Stage?,
                                      selfID: UUID) -> [Effect] {
        guard let current, current.ownerID == selfID else { return [] }
        return [.resync(current, to: requesterID)]
    }

    public static func close(on current: Stage?, by selfID: UUID) -> [Effect] {
        guard let current else { return [] }
        guard current.ownerID == selfID else { return [.forwardClose(to: current.ownerID)] }
        return [.broadcast(nil, actorID: selfID)]
    }

    public static func receiveClose(from actorID: UUID, on current: Stage?,
                                    selfID: UUID) -> [Effect] {
        guard let current, current.ownerID == selfID else { return [] }
        return [.broadcast(nil, actorID: actorID)]
    }
}
