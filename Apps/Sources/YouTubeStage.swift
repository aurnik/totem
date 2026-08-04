import SwiftUI
import TotemKit

enum YouTubeExtension: ChatExtension {
    static let id = ChatExtensionID.youtube
    static let name = "YouTube"
    static let symbol = "play.fill"
}

/// A video everyone in the chat watches together. There's no chrome of our
/// own: the picture is the whole control surface, and tapping it toggles
/// playback for everyone. Every device plays locally — nothing streams through
/// Totem — so all this has to keep in sync is a video, a play state, and a
/// position.
struct YouTubeStageView: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    let youtube: YouTubeState

    /// Last position the player reported, so pausing records where playback
    /// actually was rather than where the shared clock estimated it. Held in a
    /// reference box because it changes every couple of seconds and is only
    /// read on demand — as `@State` it would re-render the conversation
    /// continuously for the whole time a video is playing.
    @MainActor final class PositionBox { var value: Double? }
    @State private var position = PositionBox()
    @State private var unplayable = false
    /// Fixed at first render: the page URL carries the starting position, and
    /// re-deriving it on every update would reload the web view mid-video.
    @State private var initialURL: URL?

    var body: some View {
        ZStack {
            Color.black
            if let initialURL {
                YouTubePlayerView(
                    initialURL: initialURL,
                    youtube: youtube,
                    onTime: { position.value = $0 },
                    onEnded: { send(.setPlaying(false, positionSeconds: 0)) },
                    onUnplayable: { unplayable = true })
                    // The web view never takes a tap: YouTube's own controls
                    // would change playback for one person and desync the
                    // rest, so the gesture below is the only way in.
                    .allowsHitTesting(false)
            }
            if unplayable {
                Text("This video can't play here")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            send(.setPlaying(!youtube.isPlaying,
                             positionSeconds: position.value ?? youtube.position(at: Date())))
        }
        .onAppear {
            if initialURL == nil { initialURL = model.playerURL(for: youtube) }
        }
        .onChange(of: youtube.videoID) { unplayable = false }
    }

    private func send(_ action: YouTubeAction) {
        model.sendStageAction(.youtube(action), in: conversationID)
    }
}
