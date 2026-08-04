import SwiftUI

extension View {
    /// Inline navigation title on iOS; macOS has no such display mode.
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension Color {
    /// Fill behind a bubble someone else sent.
    static var incomingBubble: Color {
        #if os(iOS)
        Color(.systemGray5)
        #else
        Color.gray.opacity(0.2)
        #endif
    }
}
