import SwiftUI
import TotemKit

/// An extension that can take over a conversation's stage. Compiled in and
/// closed — iOS can't load native code at runtime, so a "marketplace" is a
/// catalogue of what shipped, not a download mechanism.
///
/// Deliberately metadata-only: stage views come from the exhaustive switch in
/// `StageArea` rather than from the protocol, which keeps the seam explicit
/// without any `AnyView` erasure.
@MainActor
protocol ChatExtension {
    static var id: ChatExtensionID { get }
    static var name: String { get }
}

enum ChatExtensions {
    static let all: [any ChatExtension.Type] = [YouTubeExtension.self, FourExtension.self]
}

/// Hangs a bar off one edge of a scroll view with the same progressive blur the
/// navigation bar has: content softens as it slides under the bar and feathers
/// out, rather than meeting a hard edge.
///
/// It has to be `safeAreaBar`, not `safeAreaInset`. Both inset the scroll
/// content identically, but only a bar takes part in the scroll edge effect —
/// a plain inset just floats there and the content passes under it untouched.
/// Before 26 neither the bar nor the effect exists, so it falls back to the
/// inset and whatever's in the bar supplies its own backing.
struct ScrollEdgeBar<BarContent: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: BarContent

    init(edge: VerticalEdge, @ViewBuilder content: () -> BarContent) {
        self.edge = edge
        self.bar = content()
    }

    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
                .safeAreaBar(edge: edge, spacing: 0) { bar }
                .scrollEdgeEffectStyle(.soft, for: edge == .top ? .top : .bottom)
        } else {
            content.safeAreaInset(edge: edge, spacing: 0) { bar }
        }
    }
}

private struct StageBoxKey: EnvironmentKey {
    static let defaultValue: CGSize = .zero
}

extension EnvironmentValues {
    /// What the conversation can spare for the stage: its full width, and the
    /// height past which the stage would crowd out the chat. Stages fit
    /// themselves into it rather than being handed a frame, since only they
    /// know their own aspect ratio and what chrome sits below the picture.
    ///
    /// The height is a cap, and a cap only ever shrinks: applied when it is
    /// *larger* than the stage needs, `maxHeight` claims the difference as an
    /// empty band, which is what put grey bars above and below the video.
    var stageBox: CGSize {
        get { self[StageBoxKey.self] }
        set { self[StageBoxKey.self] = newValue }
    }
}

/// Renders whatever is on the stage. Adding an extension adds a case here and
/// the compiler finds this spot.
struct StageArea: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    let stage: Stage

    var body: some View {
        // One structural branch whatever the OS: the backing varies, never the
        // stage itself, whose identity owns a web view that must not be rebuilt.
        VStack(spacing: 0) {
            stageView
            #if os(iOS)
            exit
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            #endif
        }
        .background { backing }
    }

    #if os(iOS)
    /// The phone has no menu bar to fall back on, so the way out of a stage
    /// sits under it.
    private var exit: some View {
        StageExit(label: stage.state.extensionID == .youtube ? "Close Video" : "End Game",
                  symbol: stage.state.extensionID == .youtube ? "stop.fill" : "xmark") {
            model.closeStage(in: conversationID)
        }
    }
    #endif

    /// From 26 the scroll edge effect blurs the transcript as it slides under
    /// the stage and feathers out below it, so a pane of its own would only put
    /// back the hard edge that effect exists to remove. Before 26 there is no
    /// such effect, and the stage needs something to be legible against.
    @ViewBuilder
    private var backing: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            Color.clear
        } else {
            Rectangle().fill(.regularMaterial)
        }
    }

    @ViewBuilder
    private var stageView: some View {
        switch stage.state {
        case .youtube(let youtube):
            YouTubeStageView(conversationID: conversationID, youtube: youtube)
        case .four(let four):
            FourStageView(conversationID: conversationID, four: four)
        }
    }
}

#if os(iOS)
/// The red exit at the foot of whatever holds the stage — a video, a game, or
/// live voice. One shape for all of them, so leaving is always in the same
/// place and always looks like leaving.
struct StageExit: View {
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 30)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
}
#endif
