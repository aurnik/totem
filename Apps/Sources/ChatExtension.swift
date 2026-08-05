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

/// Renders whatever is on the stage. Adding an extension adds a case here and
/// the compiler finds this spot.
struct StageArea: View {
    let conversationID: UUID
    let stage: Stage

    var body: some View {
        switch stage.state {
        case .youtube(let youtube):
            YouTubeStageView(conversationID: conversationID, youtube: youtube)
        case .four(let four):
            FourStageView(conversationID: conversationID, four: four)
        }
    }
}
