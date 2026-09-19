import SwiftUI
import TotemKit

/// An extension that can take over a conversation's stage. Metadata only:
/// stage views come from the exhaustive switch in `StageArea` rather than from
/// the protocol, which avoids `AnyView` erasure.
@MainActor
protocol ChatExtension {
    static var id: ChatExtensionID { get }
    static var name: String { get }
}

enum ChatExtensions {
    static let all: [any ChatExtension.Type] = [YouTubeExtension.self, FourExtension.self]
}

/// Hangs a bar off one edge of a scroll view with the navigation bar's
/// progressive blur. It must be `safeAreaBar`, not `safeAreaInset`: both inset
/// the content identically, but only a bar takes part in the scroll edge
/// effect. Before 26 neither exists, so the inset is used instead.
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
    /// What the conversation can spare for the stage; stages fit themselves into
    /// it rather than being handed a frame. The height is a cap that must only
    /// shrink: applied when it exceeds what the stage needs, `maxHeight` claims
    /// the difference as empty bands.
    var stageBox: CGSize {
        get { self[StageBoxKey.self] }
        set { self[StageBoxKey.self] = newValue }
    }
}

/// Renders whatever is on the stage.
struct StageArea: View {
    @Environment(AppModel.self) private var model
    let conversationID: UUID
    let stage: Stage

    var body: some View {
        // One structural branch whatever the OS, since the stage's identity owns
        // a web view that must not be rebuilt.
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
    /// The phone has no menu bar, so the way out of a stage sits under it. A
    /// video is anyone's to close; a game is only its players' to end.
    @ViewBuilder
    private var exit: some View {
        if canExit {
            StageExit(label: stage.state.extensionID == .youtube ? "Close Video" : "End Game",
                      symbol: stage.state.extensionID == .youtube ? "stop.fill" : "xmark") {
                model.closeStage(in: conversationID)
            }
        }
    }

    private var canExit: Bool {
        switch stage.state {
        case .youtube:
            return true
        case .four(let game):
            let me = model.currentUser?.id
            return game.red == me || game.yellow == me
        }
    }
    #endif

    /// From 26 the scroll edge effect blurs the transcript under the stage, so an
    /// opaque pane would put back the hard edge it removes.
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
/// The red exit at the foot of whatever holds the stage: one shape for videos,
/// games, and live voice, so leaving is always in the same place.
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
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.red)
    }
}
#endif
