import SwiftUI
import TotemKit

enum YouTubeExtension: ChatExtension {
    static let id = ChatExtensionID.youtube
    static let name = "YouTube"
    static let symbol = "play.fill"
}

/// A video everyone in the chat watches together. There's no chrome of our
/// own: the picture is the whole control surface — tap to toggle playback,
/// double-tap either edge to skip — and every action moves the shared stage,
/// so it lands for everyone at once. Each device plays locally; nothing
/// streams through Totem.
struct YouTubeStageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.stageBox) private var stageBox
    let conversationID: UUID
    let youtube: YouTubeState

    /// Fraction of the width at each side that counts as an edge. The gap in
    /// the middle keeps a double-tap aimed at the picture from being read as a
    /// skip in whichever direction happens to be nearer.
    private static let edgeFraction: CGFloat = 0.35

    /// Last position the player reported, so seeking and pausing work from
    /// where playback really is rather than where the shared clock estimated.
    /// Held in a reference box because it changes every couple of seconds and
    /// is only read on demand — as `@State` it would re-render the
    /// conversation continuously for the whole time a video is playing.
    @MainActor final class PositionBox { var value: Double? }
    @State private var position = PositionBox()
    @State private var unplayable = false
    @State private var width: CGFloat = 0
    /// Briefly shown after a skip, since a jump with no feedback reads as a
    /// glitch. Nil when nothing happened recently.
    @State private var skipped: Skip?
    /// Fixed at first render: the page URL carries the starting position, and
    /// re-deriving it on every update would reload the web view mid-video.
    @State private var initialURL: URL?

    private enum Skip: Equatable { case back, forward }

    var body: some View {
        ZStack {
            Color.black
            if let initialURL {
                YouTubePlayerView(
                    initialURL: initialURL,
                    youtube: youtube,
                    onTime: { position.value = $0 },
                    onEnded: { send(.ended) },
                    onUnplayable: { unplayable = true })
                    // The web view never takes a tap: YouTube's own controls
                    // would change playback for one person and desync the
                    // rest, so the gestures below are the only way in.
                    .allowsHitTesting(false)
            }
            skipIndicator
            if unplayable {
                Text("This video can't play here")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 6))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: heightCap)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { width = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, new in width = new }
            }
        }
        .contentShape(Rectangle())
        // Declared before the single tap so a second tap is given the chance
        // to arrive before the first is treated as a play/pause.
        .onTapGesture(count: 2) { location in skip(at: location) }
        .onTapGesture { togglePlayback() }
        .onAppear {
            if initialURL == nil { initialURL = model.playerURL(for: youtube) }
        }
        .onChange(of: youtube.videoID) { unplayable = false }
    }

    @ViewBuilder
    private var skipIndicator: some View {
        if let skipped {
            HStack {
                if skipped == .forward { Spacer() }
                Image(systemName: skipped == .back
                      ? "gobackward.\(Int(YouTubeAction.skipInterval))"
                      : "goforward.\(Int(YouTubeAction.skipInterval))")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.35), in: .circle)
                if skipped == .back { Spacer() }
            }
            .padding(.horizontal, 24)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    /// Nil unless the conversation is too short to give the video its full
    /// width — a cap bigger than the picture would be claimed as empty bands.
    private var heightCap: CGFloat? {
        guard stageBox.width > 0 else { return nil }
        let natural = stageBox.width * 9 / 16
        return stageBox.height < natural ? stageBox.height : nil
    }

    private var currentPosition: Double {
        position.value ?? youtube.position(at: Date())
    }

    private func togglePlayback() {
        send(.setPlaying(!youtube.isPlaying, positionSeconds: currentPosition))
    }

    private func skip(at location: CGPoint) {
        guard width > 0 else { return }
        let edge = width * Self.edgeFraction
        let direction: Skip
        if location.x <= edge {
            direction = .back
        } else if location.x >= width - edge {
            direction = .forward
        } else {
            // The middle is neither edge; leave the playhead alone rather than
            // guessing which way was meant.
            return
        }
        let delta = direction == .back ? -YouTubeAction.skipInterval : YouTubeAction.skipInterval
        let target = max(0, currentPosition + delta)
        position.value = target
        send(.seek(positionSeconds: target))

        withAnimation(.easeOut(duration: 0.15)) { skipped = direction }
        Task {
            try? await Task.sleep(for: .milliseconds(550))
            withAnimation(.easeIn(duration: 0.2)) { skipped = nil }
        }
    }

    private func send(_ action: YouTubeAction) {
        model.sendStageAction(.youtube(action), in: conversationID)
    }
}
