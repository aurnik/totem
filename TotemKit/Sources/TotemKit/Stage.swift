import Foundation

/// Extensions that can occupy a conversation's stage, the shared area at the
/// top of a chat. Adding one means a case here plus cases in `StageState` and
/// `StageAction`, so the compiler finds every site that has to handle it.
public enum ChatExtensionID: String, Codable, Sendable, CaseIterable {
    case youtube
    case four
}

// MARK: - YouTube

public struct YouTubeState: Codable, Hashable, Sendable {
    public var videoID: String
    public var title: String
    public var thumbnailURL: URL?
    public var isPlaying: Bool
    /// Playback position as of `positionAt`. Clients derive the live position
    /// from the pair rather than reporting their own clock.
    public var positionSeconds: Double
    public var positionAt: Date

    public init(videoID: String, title: String, thumbnailURL: URL? = nil,
                isPlaying: Bool, positionSeconds: Double, positionAt: Date) {
        self.videoID = videoID
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.isPlaying = isPlaying
        self.positionSeconds = positionSeconds
        self.positionAt = positionAt
    }

    public func position(at now: Date) -> Double {
        guard isPlaying else { return positionSeconds }
        return positionSeconds + max(0, now.timeIntervalSince(positionAt))
    }
}

public enum YouTubeAction: Codable, Hashable, Sendable {
    /// Puts a video on the stage, replacing whatever was playing.
    case setVideo(videoID: String, title: String, thumbnailURL: URL?)
    /// Absolute rather than a toggle, so concurrent identical intents converge.
    case setPlaying(Bool, positionSeconds: Double)
    /// Moves the playhead, leaving the play state alone. Separate from
    /// `setPlaying`, which no-ops when the play state already matches.
    case seek(positionSeconds: Double)
    /// The video ended. Every client reports this; the version check keeps the first.
    case ended

    public static let skipInterval: Double = 15
}

// MARK: - Four

public enum FourDisc: String, Codable, Hashable, Sendable {
    case red, yellow
}

/// A cell on the board. `row` counts up from the bottom.
public struct FourSlot: Codable, Hashable, Sendable {
    public var column: Int
    public var row: Int

    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }
}

public enum FourOutcome: Codable, Hashable, Sendable {
    /// `line` is the whole winning run, four cells or more, so clients draw it
    /// rather than re-deriving it.
    case won(disc: FourDisc, line: [FourSlot])
    case draw
}

public struct FourState: Codable, Hashable, Sendable {
    public static let columns = 7
    public static let rows = 6
    public static let winLength = 4
    /// How long a finished board stays up before it clears itself.
    public static let lingerSeconds: Double = 30

    /// Column-major bottom-up stacks, so a floating piece is unrepresentable.
    public var stacks: [[FourDisc]]
    /// Whoever started the game, always red.
    public var red: UUID
    /// Nil until someone takes the second seat.
    public var yellow: UUID?
    public var outcome: FourOutcome?
    /// Stamped when `outcome` is set; the clearing countdown runs off it.
    public var finishedAt: Date?

    public init(red: UUID) {
        self.stacks = Array(repeating: [], count: Self.columns)
        self.red = red
    }

    public init(stacks: [[FourDisc]], red: UUID, yellow: UUID? = nil,
                outcome: FourOutcome? = nil, finishedAt: Date? = nil) {
        self.stacks = stacks
        self.red = red
        self.yellow = yellow
        self.outcome = outcome
        self.finishedAt = finishedAt
    }

    /// Derived from the board so it cannot disagree with it. Red starts, so an
    /// even piece count means red is up.
    public var turn: FourDisc {
        stacks.reduce(0) { $0 + $1.count }.isMultiple(of: 2) ? .red : .yellow
    }

    public func player(_ disc: FourDisc) -> UUID? {
        switch disc {
        case .red: red
        case .yellow: yellow
        }
    }

    public func disc(at slot: FourSlot) -> FourDisc? {
        guard stacks.indices.contains(slot.column),
              stacks[slot.column].indices.contains(slot.row)
        else { return nil }
        return stacks[slot.column][slot.row]
    }

    public var isFull: Bool {
        stacks.allSatisfy { $0.count >= Self.rows }
    }

    /// Walked in both directions from the slot just filled, the only cell that
    /// can have completed a line.
    private static let axes = [(1, 0), (0, 1), (1, 1), (1, -1)]

    public func winningLine(from slot: FourSlot) -> [FourSlot]? {
        guard let disc = disc(at: slot) else { return nil }
        for (dx, dy) in Self.axes {
            var line = [slot]
            for sign in [1, -1] {
                var step = 1
                while true {
                    let next = FourSlot(column: slot.column + dx * step * sign,
                                        row: slot.row + dy * step * sign)
                    guard self.disc(at: next) == disc else { break }
                    line.append(next)
                    step += 1
                }
            }
            guard line.count >= Self.winLength else { continue }
            // Sorted so the ends of the run are the ends of the array.
            return line.sorted { ($0.column, $0.row) < ($1.column, $1.row) }
        }
        return nil
    }
}

public enum FourAction: Codable, Hashable, Sendable {
    /// Puts an empty board on the stage with the sender as red.
    case start
    /// Takes the second seat.
    case join
    case drop(column: Int)
    /// The finished board's time is up. Every client reports this; the version
    /// check keeps the first.
    case expire
}

// MARK: - Stage

public enum StageState: Codable, Hashable, Sendable {
    case youtube(YouTubeState)
    case four(FourState)

    public var extensionID: ChatExtensionID {
        switch self {
        case .youtube: .youtube
        case .four: .four
        }
    }

    /// Whether losing this stage would destroy something the participants
    /// cannot recreate, so another extension may not claim it. It depends on
    /// the state, not the extension: a finished game is as disposable as a video.
    public var preservesState: Bool {
        switch self {
        case .youtube: false
        case .four(let game): game.outcome == nil
        }
    }
}

public enum StageAction: Codable, Hashable, Sendable {
    case youtube(YouTubeAction)
    case four(FourAction)

    public var extensionID: ChatExtensionID {
        switch self {
        case .youtube: .youtube
        case .four: .four
        }
    }

    /// A conditional action carries the version it targeted and is dropped if
    /// the stage has moved on. Claiming the stage is unconditional.
    public var isConditional: Bool {
        switch self {
        case .youtube(.setVideo), .four(.start): false
        case .youtube(.setPlaying), .youtube(.seek), .youtube(.ended): true
        case .four(.join), .four(.drop), .four(.expire): true
        }
    }
}

/// The stage plus the version that orders changes to it.
public struct Stage: Codable, Hashable, Sendable {
    public var version: Int
    public var state: StageState
    /// Whoever claimed the stage from empty; only emptying it changes hands.
    /// Their device runs the reducer and is the only party whose broadcast of
    /// the stage counts (`StageHost`).
    public var ownerID: UUID

    public init(version: Int, state: StageState, ownerID: UUID) {
        self.version = version
        self.state = state
        self.ownerID = ownerID
    }
}

/// The stage owner runs this for everyone's actions; every client carries the
/// same code so all agree on what an action means.
public enum StageReducer {
    public enum Outcome: Sendable, Equatable {
        /// Store and broadcast to every participant, including the sender.
        case updated(Stage)
        /// A no-op. Broadcasting would make everyone re-seek when several
        /// clients report the same thing.
        case unchanged
        /// The stage is finished. Sent unattributed, so it posts no notice.
        case cleared
        /// Stale version, or a takeover of a stage that preserves state.
        /// Re-sync the sender alone.
        case rejected
    }

    /// `actorID` is authenticated by the caller. It is a parameter rather than
    /// part of the action payload so a client cannot act as someone else.
    public static func reduce(_ current: Stage?, _ action: StageAction, by actorID: UUID,
                              expectedVersion: Int?, at now: Date) -> Outcome {
        if action.isConditional {
            guard let current, current.state.extensionID == action.extensionID,
                  let expectedVersion, expectedVersion == current.version
            else { return .rejected }
        } else if let current, current.state.extensionID != action.extensionID,
                  current.state.preservesState {
            return .rejected
        }

        switch action {
        case .youtube(let action): return apply(action, by: actorID, to: current, at: now)
        case .four(let action): return apply(action, by: actorID, to: current, at: now)
        }
    }

    /// The next version of the stage, and the only place ownership is assigned:
    /// an empty stage goes to whoever fills it, a held one keeps its owner.
    private static func next(_ current: Stage?, _ state: StageState, by actorID: UUID) -> Stage {
        Stage(version: (current?.version ?? 0) + 1, state: state,
              ownerID: current?.ownerID ?? actorID)
    }

    private static func apply(_ action: YouTubeAction, by actorID: UUID,
                              to current: Stage?, at now: Date) -> Outcome {
        switch action {
        case let .setVideo(videoID, title, thumbnailURL):
            let state = YouTubeState(videoID: videoID, title: title, thumbnailURL: thumbnailURL,
                                     isPlaying: true, positionSeconds: 0, positionAt: now)
            return .updated(next(current, .youtube(state), by: actorID))

        case let .setPlaying(isPlaying, positionSeconds):
            guard let current, case .youtube(var state) = current.state else { return .rejected }
            guard state.isPlaying != isPlaying else { return .unchanged }
            state.isPlaying = isPlaying
            state.positionSeconds = max(0, positionSeconds)
            state.positionAt = now
            return .updated(next(current, .youtube(state), by: actorID))

        case let .seek(positionSeconds):
            guard let current, case .youtube(var state) = current.state else { return .rejected }
            state.positionSeconds = max(0, positionSeconds)
            state.positionAt = now
            return .updated(next(current, .youtube(state), by: actorID))

        case .ended:
            // The version check above dropped every report but the first.
            return .cleared
        }
    }

    private static func apply(_ action: FourAction, by actorID: UUID,
                              to current: Stage?, at now: Date) -> Outcome {
        switch action {
        case .start:
            // Starting is unconditional, so guard a live game here. A finished
            // board may be replaced: that is "play again".
            if let current, case .four(let game) = current.state, game.outcome == nil {
                return .rejected
            }
            return .updated(next(current, .four(FourState(red: actorID)), by: actorID))

        case .join:
            guard let current, case .four(var game) = current.state,
                  game.yellow == nil, game.red != actorID
            else { return .rejected }
            game.yellow = actorID
            return .updated(next(current, .four(game), by: actorID))

        case .drop(let column):
            guard let current, case .four(var game) = current.state,
                  game.outcome == nil,
                  // Nobody moves until there is someone to move against.
                  game.yellow != nil,
                  game.player(game.turn) == actorID,
                  game.stacks.indices.contains(column),
                  game.stacks[column].count < FourState.rows
            else { return .rejected }

            let disc = game.turn
            let slot = FourSlot(column: column, row: game.stacks[column].count)
            game.stacks[column].append(disc)
            if let line = game.winningLine(from: slot) {
                game.outcome = .won(disc: disc, line: line)
                game.finishedAt = now
            } else if game.isFull {
                game.outcome = .draw
                game.finishedAt = now
            }
            return .updated(next(current, .four(game), by: actorID))

        case .expire:
            // A win leaves the board up so everyone sees the line; this takes
            // it down. Refused while the game is live.
            guard let current, case .four(let game) = current.state,
                  game.outcome != nil
            else { return .rejected }
            return .cleared
        }
    }
}

/// A search hit from the server's YouTube proxy.
public struct YouTubeVideo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var channel: String
    public var thumbnailURL: URL?

    public init(id: String, title: String, channel: String, thumbnailURL: URL? = nil) {
        self.id = id
        self.title = title
        self.channel = channel
        self.thumbnailURL = thumbnailURL
    }
}
