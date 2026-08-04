import Foundation

/// Extensions that can occupy a conversation's stage — the shared area at the
/// top of a chat that every participant sees. Closed list: adding one means a
/// case here plus cases in `StageState` and `StageAction`, so the compiler
/// finds every site that has to handle it.
public enum ChatExtensionID: String, Codable, Sendable, CaseIterable {
    case youtube

    /// Whether losing this stage would destroy something the participants
    /// can't trivially recreate. A video can be put back on in two taps; a
    /// chess game in progress can't, so another extension may not claim the
    /// stage out from under it.
    public var preservesState: Bool {
        switch self {
        case .youtube: false
        }
    }
}

// MARK: - YouTube

public struct YouTubeState: Codable, Hashable, Sendable {
    public var videoID: String
    public var title: String
    public var thumbnailURL: URL?
    public var isPlaying: Bool
    /// Playback position as of `positionAt`, which the server stamps. Clients
    /// derive the live position from these two rather than reporting their own
    /// clock, so a late joiner lands where everyone else already is.
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

public enum YouTubeAction: Codable, Sendable {
    /// Puts a video on the stage, replacing whatever was playing.
    case setVideo(videoID: String, title: String, thumbnailURL: URL?)
    /// Absolute, never a toggle: two people pausing at the same moment must
    /// converge on paused rather than undoing each other.
    case setPlaying(Bool, positionSeconds: Double)
}

// MARK: - Stage

public enum StageState: Codable, Hashable, Sendable {
    case youtube(YouTubeState)

    public var extensionID: ChatExtensionID {
        switch self {
        case .youtube: .youtube
        }
    }
}

public enum StageAction: Codable, Sendable {
    case youtube(YouTubeAction)

    public var extensionID: ChatExtensionID {
        switch self {
        case .youtube: .youtube
        }
    }

    /// Conditional actions change what the sender was looking at, so they carry
    /// the version they saw and are dropped if it has moved on — a pause aimed
    /// at one video can never land on the video someone just swapped in.
    /// Claiming the stage is unconditional: "put this on now" doesn't depend on
    /// what was playing before.
    public var isConditional: Bool {
        switch self {
        case .youtube(.setVideo): false
        case .youtube(.setPlaying): true
        }
    }
}

/// The stage plus the version that orders changes to it.
public struct Stage: Codable, Hashable, Sendable {
    public var version: Int
    public var state: StageState

    public init(version: Int, state: StageState) {
        self.version = version
        self.state = state
    }
}

/// Pure and shared: the server runs this to stay authoritative, and clients
/// carry the identical code so both agree on what an action means.
public enum StageReducer {
    public enum Outcome: Sendable, Equatable {
        /// Store it and broadcast to every participant, including the sender.
        case updated(Stage)
        /// A no-op — don't broadcast, or N clients reporting the same thing
        /// would make everyone re-seek.
        case unchanged
        /// Stale version, or a takeover of a stage worth preserving. Re-sync
        /// the sender only.
        case rejected
    }

    public static func reduce(_ current: Stage?, _ action: StageAction,
                              expectedVersion: Int?, at now: Date) -> Outcome {
        if action.isConditional {
            guard let current, current.state.extensionID == action.extensionID,
                  let expectedVersion, expectedVersion == current.version
            else { return .rejected }
        } else if let current, current.state.extensionID != action.extensionID,
                  current.state.extensionID.preservesState {
            return .rejected
        }

        switch action {
        case .youtube(let action): return apply(action, to: current, at: now)
        }
    }

    private static func apply(_ action: YouTubeAction, to current: Stage?, at now: Date) -> Outcome {
        switch action {
        case let .setVideo(videoID, title, thumbnailURL):
            let state = YouTubeState(videoID: videoID, title: title, thumbnailURL: thumbnailURL,
                                     isPlaying: true, positionSeconds: 0, positionAt: now)
            return .updated(Stage(version: (current?.version ?? 0) + 1, state: .youtube(state)))

        case let .setPlaying(isPlaying, positionSeconds):
            guard let current, case .youtube(var state) = current.state else { return .rejected }
            guard state.isPlaying != isPlaying else { return .unchanged }
            state.isPlaying = isPlaying
            state.positionSeconds = max(0, positionSeconds)
            state.positionAt = now
            return .updated(Stage(version: current.version + 1, state: .youtube(state)))
        }
    }
}

/// A search hit from the server's YouTube proxy, and what the picker shows.
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
