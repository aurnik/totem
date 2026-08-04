import SwiftUI
import TotemKit

/// A session-scoped conversation — 1:1 with a buddy, or a group session.
/// Live only while parties are on; messages are never stored server-side, so
/// an offline 1:1 peer means sending is disabled. Dismisses when we sign off.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    @State private var draft = ""
    @State private var pulsing = false
    @State private var showingSoundboard = false
    @State private var showingMembers = false

    private var group: SessionInfo? {
        model.groupSessions[conversationID]
    }

    private var title: String {
        model.conversationTitle(conversationID)
    }

    private var peerOffline: Bool {
        group == nil && (model.presences[conversationID]?.state ?? .offline) == .offline
    }

    private var micIsLive: Bool {
        model.liveMicConversation == conversationID
    }

    private var dictating: Bool {
        model.dictationConversation == conversationID
    }

    private var speakers: [(id: UUID, handle: String)] {
        (model.speakingUsers[conversationID] ?? [])
            .map { (id: $0, handle: model.handle(of: $0) ?? "?") }
            .sorted { $0.handle < $1.handle }
    }

    private var mutedListenerNames: [String] {
        (model.mutedListeners[conversationID] ?? [])
            .compactMap { model.handle(of: $0) }
            .sorted()
    }

    /// Who to picture in the header: the peer for 1:1, up to three
    /// participants for groups (matching the title's handle order).
    /// Participants without a published avatar are simply left out.
    private var headerAvatars: [Avatar] {
        if let group {
            return group.participants
                .filter { $0.id != model.currentUser?.id }
                .sorted { $0.handle < $1.handle }
                .prefix(3)
                .compactMap { model.avatar(of: $0.id) ?? $0.avatar }
        }
        return [model.avatar(of: conversationID)].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isReconnecting {
                banner("Reconnecting — messages can't be sent right now.")
            } else if peerOffline {
                banner("\(title) is offline — messages can't be delivered right now.")
            }
            if showingMembers, let group {
                memberList(group)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Also shown while broadcasting with no one talking back — the
            // speaker is exactly who needs to know a listener can't hear.
            if !speakers.isEmpty || (micIsLive && !mutedListenerNames.isEmpty) {
                speakersSection
            }
            transcript
            composer
        }
        .navigationTitle(title)
        .inlineTitle()
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                // For groups the title is a button: tapping drops down the
                // member list (handles, quick-add for non-friends).
                if group != nil {
                    Button(action: toggleMembers) {
                        headerLabel
                    }
                    .buttonStyle(.plain)
                } else {
                    headerLabel
                }
            }
            #else
            if group != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleMembers) {
                        Image(systemName: "person.2")
                    }
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSoundboard = true
                } label: {
                    Image(systemName: "waveform")
                }
                .disabled(peerOffline)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.toggleMic(in: conversationID)
                } label: {
                    Image(systemName: micIsLive ? "mic.fill" : "mic")
                        .foregroundStyle(micIsLive ? Color.red : Color.accentColor)
                        .symbolEffect(.pulse, isActive: micIsLive)
                }
                .disabled(peerOffline)
            }
        }
        .sheet(isPresented: $showingSoundboard) {
            SoundboardSheet(conversationID: conversationID)
                .environment(model)
        }
        .onAppear { model.conversationOpened(conversationID) }
        .onDisappear { model.conversationClosed(conversationID) }
        .onChange(of: model.isSignedOn) { _, signedOn in
            if !signedOn { dismiss() }
        }
    }

    private var headerLabel: some View {
        HStack(spacing: 6) {
            HStack(spacing: -10) {
                ForEach(Array(headerAvatars.enumerated()), id: \.offset) { _, avatar in
                    AvatarHeadView(avatar: avatar, size: 26, animated: false)
                }
            }
            Text(title)
                .font(.subheadline.weight(.semibold))
            if group != nil {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showingMembers ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    private func toggleMembers() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingMembers.toggle()
        }
    }

    /// Dropped down from the header title: every other participant, with
    /// their avatar — or, for non-friends, a one-tap add-friend button.
    private func memberList(_ group: SessionInfo) -> some View {
        let members = group.participants
            .filter { $0.id != model.currentUser?.id }
            .sorted { $0.handle < $1.handle }
        return VStack(alignment: .leading, spacing: 10) {
            ForEach(members) { member in
                HStack(spacing: 10) {
                    memberAccessory(member)
                        .frame(width: 30)
                    Text(member.handle)
                        .font(.subheadline)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5))
    }

    @ViewBuilder
    private func memberAccessory(_ member: User) -> some View {
        let relationship = model.relationship(with: member.id)
        if relationship?.status == .accepted {
            PresenceAvatar(
                avatar: model.avatar(of: member.id) ?? member.avatar,
                state: model.presences[member.id]?.state ?? .offline,
                size: 28)
        } else if let relationship, !relationship.incoming {
            // Request already sent — nothing more to do here.
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        } else {
            // One tap makes friends: accepts their pending request if there
            // is one, otherwise sends ours.
            Button {
                Task {
                    if let relationship {
                        try? await model.acceptRequest(relationship)
                    } else {
                        try? await model.addBuddy(handle: member.handle)
                    }
                }
            } label: {
                Image(systemName: "person.badge.plus")
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    /// Fixed to the top while anyone is audible: two-column grid of speaking
    /// users, each an initial-letter circle beside their live EQ, plus a
    /// crossed-out speaker row for participants whose device can't play audio.
    private var speakersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !speakers.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                          alignment: .leading, spacing: 8) {
                    ForEach(speakers, id: \.id) { speaker in
                        HStack(spacing: 8) {
                            if let avatar = model.avatar(of: speaker.id) {
                                AvatarHeadView(avatar: avatar, size: 28, animated: false)
                            } else {
                                MonogramCircle(handle: speaker.handle)
                            }
                            AudioMeterView(spectrum: model.speakerSpectrum[speaker.id]
                                ?? Array(repeating: 0, count: AudioAnalyzer.bandCount))
                        }
                    }
                }
            }
            if !mutedListenerNames.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "speaker.slash.fill")
                    Text("\(mutedListenerNames.joined(separator: ", ")) can't hear")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
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
        let transcript = model.transcripts[conversationID] ?? []
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(transcript.enumerated()), id: \.element.id) { index, item in
                        Group {
                            switch item {
                            case .message(let message):
                                let isMine = message.senderID == model.currentUser?.id
                                MessageRow(
                                    message: message,
                                    isMine: isMine,
                                    senderName: (group != nil && !isMine)
                                        ? model.handle(of: message.senderID) : nil,
                                    senderAvatar: (group != nil && !isMine)
                                        ? model.avatar(of: message.senderID) : nil,
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
                            // Only genuinely-new messages pop; notices appear
                            // immediately and older items render statically.
                            enabled: popInEnabled(item),
                            anchor: anchor(for: item)
                        ))
                    }
                    if group == nil && model.isTyping(conversationID) {
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

    private func popInEnabled(_ item: AppModel.TranscriptItem) -> Bool {
        if case .message = item { return model.isNewlyAppended(item.id) }
        return false
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
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !peerOffline
    }

    /// Only the one-time model download — live words go in the draft bubble,
    /// where the message itself will land. A silent multi-second wait
    /// otherwise reads as a hang.
    private var dictationBar: some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text("Preparing…")
                    .italic()
                Text("Downloading the language model")
                    .font(.caption2)
            }
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative, isActive: true)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    /// Off, it's an empty outgoing bubble offering the mode; on, it fills in
    /// like a sent one — inverted against the transcript so it still reads as
    /// a control rather than something already said. Fill and border are both
    /// always present and cross-fade through their colors: swapping one shape
    /// for the other gives SwiftUI nothing to interpolate, and it cuts.
    private var dictationToggle: some View {
        Button {
            model.toggleDictation(in: conversationID)
        } label: {
            Text("Voice → text")
                .font(.body)
                .foregroundStyle(dictating ? dictationLabelColor : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 18)
                        .fill(dictating ? Color.primary.opacity(0.85) : Color.clear)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18)
                                .strokeBorder(
                                    dictating ? Color.clear : Color.secondary,
                                    style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                }
                .animation(.easeInOut(duration: 0.25), value: dictating)
                // Outside the color cross-fade so the two don't drive each
                // other: a slow breath while the mic is being transcribed.
                .scaleEffect(pulsing ? 1.035 : 1)
                .opacity(pulsing ? 0.88 : 1)
        }
        .buttonStyle(.plain)
        .disabled(peerOffline)
        .onChange(of: dictating) { _, on in
            if on {
                withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                    pulsing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) { pulsing = false }
            }
        }
    }

    /// Reads against `Color.primary`, so it flips with the color scheme.
    private var dictationLabelColor: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.dictationPreparing {
                dictationBar
            }
            // Dictation rides on the open mic, so it's only offered once the
            // mic is on — and turning the mic off takes it down with it.
            if model.dictationSupported, micIsLive {
                HStack {
                    Spacer(minLength: 0)
                    dictationToggle
                }
                .padding(.horizontal, 14)
            }
            #if os(iOS)
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty, group == nil {
                            model.sendTyping(to: conversationID)
                        }
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
                        if !newValue.isEmpty, group == nil {
                            model.sendTyping(to: conversationID)
                        }
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
        guard canSend else { return }
        model.sendMessage(to: conversationID, body: draft)
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
        .background { Color.incomingBubble }
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
    var senderName: String?
    /// Group chats only: the sender's avatar beside their bubble.
    var senderAvatar: Avatar?
    var recencyFraction: Double = 1

    private var incomingBackground: Color { .incomingBubble }

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

    /// Marks a spoken message, on the bubble's inward side so it reads as an
    /// annotation of that bubble rather than of the row.
    private var dictationGlyph: some View {
        Image(systemName: "mic.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 48) }
            if let senderAvatar {
                AvatarHeadView(avatar: senderAvatar, size: 24, animated: false)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let senderName {
                    Text(senderName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                // The glyph rides beside the bubble, not the row, so it stays
                // centered on the bubble whatever else the row carries.
                HStack(alignment: .center, spacing: 6) {
                    if isMine, message.dictated == true { dictationGlyph }
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
                    if !isMine, message.dictated == true { dictationGlyph }
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}
