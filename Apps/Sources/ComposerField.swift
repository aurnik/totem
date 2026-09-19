import SwiftUI
import TotemKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The message composer's text field. Unlike SwiftUI's `TextField` on these
/// deployment targets, it bolds a bot tag as it's typed. Storage stays a plain
/// `String`; the styling is re-derived on every edit.
struct ComposerField: View {
    @Binding var text: String
    var placeholder: String
    /// Every registered bot tag. Empty means no bolding.
    var aliases: [String]
    var onSubmit: () -> Void

    @State private var height: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
            }
            TextViewRepresentable(
                text: $text, height: $height, aliases: aliases, onSubmit: onSubmit)
                .frame(height: max(height, Self.minHeight))
        }
    }

    private static var minHeight: CGFloat { 22 }

    /// Bolds the leading bot tag, matching what `MessageRow` renders.
    static func styled(_ text: String, aliases: [String],
                       font: PlatformFont, bold: PlatformFont,
                       color: PlatformColor) -> NSAttributedString {
        let out = NSMutableAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: color])
        if let match = BotTag.match(text, aliases: aliases) {
            out.addAttribute(
                .font, value: bold, range: NSRange(match.tagRange, in: text))
        }
        return out
    }
}

#if os(iOS)
typealias PlatformFont = UIFont
typealias PlatformColor = UIColor
#else
typealias PlatformFont = NSFont
typealias PlatformColor = NSColor
#endif

// MARK: - iOS

#if os(iOS)
private struct TextViewRepresentable: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var aliases: [String]
    var onSubmit: () -> Void

    /// Five lines, then it scrolls rather than pushing the transcript away.
    private var maxHeight: CGFloat { UIFont.preferredFont(forTextStyle: .body).lineHeight * 5 }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            // Restyling replaces the whole string, so the selection has to be
            // restored or the caret jumps to the end on every keystroke.
            let selection = view.selectedRange
            view.attributedText = ComposerField.styled(
                text, aliases: aliases, font: .preferredFont(forTextStyle: .body),
                bold: .boldBody, color: .label)
            view.selectedRange = selection
        }
        resize(view)
    }

    private func resize(_ view: UITextView) {
        let fitted = view.sizeThatFits(
            CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height
        let capped = min(fitted, maxHeight)
        view.isScrollEnabled = fitted > maxHeight
        if abs(height - capped) > 0.5 {
            DispatchQueue.main.async { height = capped }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TextViewRepresentable

        init(parent: TextViewRepresentable) { self.parent = parent }

        func textViewDidChange(_ view: UITextView) {
            let selection = view.selectedRange
            parent.text = view.text
            view.attributedText = ComposerField.styled(
                view.text, aliases: parent.aliases,
                font: .preferredFont(forTextStyle: .body), bold: .boldBody, color: .label)
            view.selectedRange = selection
            parent.resize(view)
        }
    }
}

private extension UIFont {
    static var boldBody: UIFont {
        let body = UIFont.preferredFont(forTextStyle: .body)
        guard let descriptor = body.fontDescriptor.withSymbolicTraits(.traitBold) else { return body }
        return UIFont(descriptor: descriptor, size: body.pointSize)
    }
}
#endif

// MARK: - macOS

#if os(macOS)
private struct TextViewRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var aliases: [String]
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isRichText = false
        view.isVerticallyResizable = false
        view.allowsUndo = true
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        context.coordinator.parent = self
        if view.string != text {
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(ComposerField.styled(
                text, aliases: aliases, font: .preferredFont(forTextStyle: .body),
                bold: .boldBody, color: .labelColor))
            view.setSelectedRange(selection)
        }
        let fitted = view.layoutManager?.usedRect(for: view.textContainer!).height ?? 0
        if abs(height - fitted) > 0.5 {
            DispatchQueue.main.async { height = fitted }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TextViewRepresentable

        init(parent: TextViewRepresentable) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            let selection = view.selectedRange()
            parent.text = view.string
            view.textStorage?.setAttributedString(ComposerField.styled(
                view.string, aliases: parent.aliases,
                font: .preferredFont(forTextStyle: .body), bold: .boldBody,
                color: .labelColor))
            view.setSelectedRange(selection)
        }

        /// Return sends.
        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.onSubmit()
            return true
        }
    }
}

private extension NSFont {
    static var boldBody: NSFont {
        let body = NSFont.preferredFont(forTextStyle: .body)
        return NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
    }
}
#endif
