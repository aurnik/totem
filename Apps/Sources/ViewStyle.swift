import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

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

    /// A bot's bubble: near-black on light, near-white on dark. Resolved from
    /// the trait environment rather than `\.colorScheme`, so it follows the
    /// in-app appearance override the way system colors do.
    static var botBubble: Color { dynamic(light: 0.11, dark: 0.93) }

    /// The inverse of `botBubble`, so contrast holds in both schemes.
    static var botBubbleText: Color { dynamic(light: 0.96, dark: 0.08) }

    private static func dynamic(light: Double, dark: Double) -> Color {
        #if os(iOS)
        Color(UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? dark : light, alpha: 1)
        })
        #else
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
        #endif
    }
}
