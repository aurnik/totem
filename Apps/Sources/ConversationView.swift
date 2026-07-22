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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(model.messages[peerID] ?? []) { message in
                        MessageRow(message: message, isMine: message.senderID == model.currentUser?.id)
                            .id(message.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.messages[peerID]?.count ?? 0) {
                if let last = model.messages[peerID]?.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                if model.isTyping(peerID) {
                    Text("\(handle) is typing…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                }
            }
            HStack {
                TextField("Message", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty { model.sendTyping(to: peerID) }
                    }
                    .onSubmit(send)
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(12)
        }
    }

    private func send() {
        model.sendMessage(to: peerID, body: draft)
        draft = ""
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let isMine: Bool

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 40) }
            Text(message.body)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(isMine ? Color.accentColor.opacity(0.85) : Color.gray.opacity(0.2))
                .foregroundStyle(isMine ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if !isMine { Spacer(minLength: 40) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
