import SwiftUI
import TotemKit

/// A session-scoped conversation with one buddy. Live while both parties are
/// on; if the peer is offline this is "leave a message" mode (delivered at
/// their next sign-on, spec §6). Dismisses itself when we sign off.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let peerID: UUID
    @State private var draft = ""

    private var handle: String {
        model.buddy(withID: peerID)?.user.handle ?? "buddy"
    }

    private var peerOffline: Bool {
        (model.presences[peerID]?.state ?? .offline) == .offline
    }

    var body: some View {
        VStack(spacing: 0) {
            if peerOffline {
                banner("\(handle) is offline — messages will be delivered when they next sign on.")
            } else if model.endedConversations.contains(peerID) {
                banner("Conversation archived. New messages start a fresh session.")
            }
            transcript
            composer
        }
        .navigationTitle(handle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(handle)
                    .font(.subheadline.weight(.semibold))
            }
        }
        #endif
        .onAppear { model.conversationOpened(peerID) }
        .onDisappear { model.conversationClosed(peerID) }
        .onChange(of: model.isSignedOn) { _, signedOn in
            if !signedOn { dismiss() }
        }
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(.quaternary.opacity(0.5))
    }

    private var transcript: some View {
        let transcript = model.transcripts[peerID] ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(transcript.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .message(let message):
                                MessageRow(
                                    message: message,
                                    isMine: message.senderID == model.currentUser?.id,
                                    recencyFraction: Self.recencyFraction(index: index, count: transcript.count)
                                )
                            case .notice(_, let text, _):
                                Text(text)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 8)
                            }
                        }
                        .id(item.id)
                        .modifier(PopInEffect(
                            // Only genuinely-new items pop; older ones scrolling
                            // back into view render statically.
                            enabled: index == transcript.count - 1
                                && Date().timeIntervalSince(item.date) < 3,
                            anchor: anchor(for: item)
                        ))
                    }
                    TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                        if model.isTyping(peerID) {
                            HStack {
                                TypingIndicatorBubble()
                                Spacer()
                            }
                            .id("typingIndicator")
                            .modifier(PopInEffect(enabled: true, anchor: .bottomLeading))
                            .onAppear {
                                withAnimation { proxy.scrollTo("typingIndicator", anchor: .bottom) }
                            }
                        }
                    }
                }
                .padding(12)
            }
            .onChange(of: transcript.count) {
                if let last = transcript.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    /// 1 for the newest message, easing toward 0 over the last 25 — drives the
    /// history fade on outgoing bubbles.
    private static func recencyFraction(index: Int, count: Int) -> Double {
        let distanceFromEnd = Double(count - 1 - index)
        return max(0, 1 - distanceFromEnd / 25)
    }

    private func anchor(for item: AppModel.TranscriptItem) -> UnitPoint {
        switch item {
        case .message(let message):
            message.senderID == model.currentUser?.id ? .bottomTrailing : .bottomLeading
        case .notice:
            .bottom
        }
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            #if os(iOS)
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty { model.sendTyping(to: peerID) }
                    }
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 29))
                        .foregroundStyle(Color.white, canSend ? Color.blue : Color(.systemGray3))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .padding(.trailing, 4)
                .padding(.bottom, 4)
            }
            .background(
                RoundedRectangle(cornerRadius: 21)
                    .fill(Color(.systemBackground))
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
            #else
            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty { model.sendTyping(to: peerID) }
                    }
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            .padding(12)
            #endif
        }
    }

    private func send() {
        model.sendMessage(to: peerID, body: draft)
        draft = ""
    }
}

/// Fade-and-grow entrance for newly inserted transcript content, anchored
/// where the bubble sprouts from (sender's side; center for notices).
struct PopInEffect: ViewModifier {
    let enabled: Bool
    var anchor: UnitPoint = .bottomLeading
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(enabled && !appeared ? 0.4 : 1, anchor: anchor)
            .opacity(enabled && !appeared ? 0 : 1)
            .onAppear {
                guard enabled else { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                    appeared = true
                }
            }
    }
}

/// iMessage-style typing indicator: an incoming-gray bubble with three
/// staggered pulsing dots.
struct TypingIndicatorBubble: View {
    var body: some View {
        HStack(spacing: 5) {
            TypingDot(delay: 0)
            TypingDot(delay: 0.18)
            TypingDot(delay: 0.36)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            #if os(iOS)
            Color(.systemGray5)
            #else
            Color.gray.opacity(0.2)
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

private struct TypingDot: View {
    let delay: Double
    @State private var up = false

    var body: some View {
        Circle()
            .fill(.secondary)
            .frame(width: 8, height: 8)
            .offset(y: up ? -2 : 1)
            .opacity(up ? 0.9 : 0.4)
            .animation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(delay), value: up)
            .onAppear { up = true }
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isMine: Bool
    var recencyFraction: Double = 1

    private var incomingBackground: Color {
        #if os(iOS)
        Color(.systemGray5)
        #else
        Color.gray.opacity(0.2)
        #endif
    }

    /// iMessage blue (#007AFF) for the newest messages, washing out toward a
    /// pale sky blue deeper into history. Each bubble spans a small slice of
    /// the ramp top-to-bottom so consecutive bubbles read as one continuous
    /// gradient over the transcript.
    private static func historyBlue(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        return Color(
            red: 0.45 * (1 - f),
            green: 0.72 + (0.478 - 0.72) * f,
            blue: 1.0
        )
    }

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 48) }
            Text(message.body)
                .font(.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    if isMine {
                        LinearGradient(
                            colors: [Self.historyBlue(recencyFraction - 0.06),
                                     Self.historyBlue(recencyFraction)],
                            startPoint: .top, endPoint: .bottom
                        )
                    } else {
                        incomingBackground
                    }
                }
                .foregroundStyle(isMine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            if !isMine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
