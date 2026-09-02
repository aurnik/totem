import SwiftUI
import TotemKit

/// A session-scoped conversation — 1:1 with a buddy, or a group session.
/// Live only while parties are on; messages are never stored server-side, so
/// an offline 1:1 peer means sending is disabled. Dismisses when we sign off.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #else
    @Environment(\.controlActiveState) private var controlActiveState
    #endif
    let conversationID: UUID
    @State private var draft = ""
    @State private var pulsing = false
    @State private var showingSoundboard = false
    @State private var showingYouTube = false
    @State private var showingMembers = false
    @State private var showingActions = false
    /// Measured, not assumed: this is what shrinks when the keyboard opens,
    /// and the stage shrinking with it is the point.
    @State private var conversationSize: CGSize = .zero

    /// Rather less than half the conversation, so a stage never leaves the
    /// chat a sliver. Only bites when space is tight — with the keyboard down
    /// it's larger than any stage asks for, and is then not applied at all.
    private var stageBox: CGSize {
        CGSize(width: conversationSize.width, height: conversationSize.height * 0.45)
    }

    private var group: SessionInfo? {
        model.groupSessions[conversationID]
    }

    /// The buddy behind a 1:1 conversation; nil for groups.
    private var peerID: UUID? {
        model.peer(of: conversationID)
    }

    private var title: String {
        model.conversationTitle(conversationID)
    }

    private var peerOffline: Bool {
        guard group == nil else { return false }
        guard let peerID else { return true }
        return (model.presences[peerID]?.state ?? .offline) == .offline
    }

    /// Whether someone looking at their screen would see this chat: the app
    /// in front on iOS, this window key on macOS. Gone while the app is in
    /// the switcher or another app is in front.
    private var isFrontmost: Bool {
        #if os(iOS)
        scenePhase == .active
        #else
        controlActiveState == .key
        #endif
    }

    private var peerViewing: Bool {
        group == nil && model.peerViewing.contains(conversationID)
    }

    /// The group's sitting ended — fewer than two people left. The transcript
    /// and roster stay readable; sending is over until someone starts the
    /// same combination again.
    private var groupEnded: Bool {
        model.endedGroups.contains(conversationID)
    }

    private var micIsLive: Bool {
        model.liveMicConversation == conversationID
    }

    private var dictating: Bool {
        model.dictationConversation == conversationID
    }

    /// Everyone audible in this chat. We only count while our own mic is
    /// live: the monitor exists to show our voice going out, and once the mic
    /// is off there's nothing to show.
    private var speakers: [(id: UUID, handle: String)] {
        (model.speakingUsers[conversationID] ?? [])
            .filter { micIsLive || $0 != model.currentUser?.id }
            .map { (id: $0, handle: model.handle(of: $0) ?? "?") }
            .sorted { $0.handle < $1.handle }
    }

    private var othersSpeaking: Bool {
        speakers.contains { $0.id != model.currentUser?.id }
    }

    private var mutedListenerNames: [String] {
        (model.mutedListeners[conversationID] ?? [])
            .compactMap { model.handle(of: $0) }
            .sorted()
    }

    /// Another extension holds the stage and would lose real state if this one
    /// took it — the server refuses that anyway, so don't offer it.
    private func stageIsProtected(against id: ChatExtensionID) -> Bool {
        guard let stage = model.stages[conversationID] else { return false }
        return stage.state.extensionID != id && stage.state.preservesState
    }

    private func isOnStage(_ id: ChatExtensionID) -> Bool {
        model.stages[conversationID]?.state.extensionID == id
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
                .compactMap { model.avatar(of: $0.id) }
        }
        return [peerID.flatMap { model.avatar(of: $0) }].compactMap { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isReconnecting {
                banner("Reconnecting — messages can't be sent right now.")
            } else if peerOffline {
                banner("\(title) is offline — messages can't be delivered right now.")
            } else if groupEnded {
                banner("This group chat ended — start it again from New Chat.")
            }
            if showingMembers, let group {
                memberList(group)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            // Voice holds the top while anyone is audible or our own mic is
            // open — the speaker is exactly who needs to know a listener
            // can't hear, and the way off the mic lives here.
            if !speakers.isEmpty || micIsLive {
                speakersSection
            }
            transcript
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { conversationSize = proxy.size }
                    .onChange(of: proxy.size) { _, new in conversationSize = new }
            }
        }
        .overlay {
            if showingActions {
                ZStack(alignment: .topTrailing) {
                    // Anywhere else dismisses, the way a menu does.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleActions)
                    actionMenu
                        .padding(.top, 6)
                        .padding(.trailing, 10)
                        .transition(.scale(scale: 0.86, anchor: .topTrailing)
                            .combined(with: .opacity))
                }
            }
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
            // The window title carries the name here, so the dot stands alone.
            if peerViewing {
                ToolbarItem(placement: .principal) {
                    ViewingDot()
                        .help("\(title) has this chat open")
                }
            }
            if group != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: toggleMembers) {
                        Image(systemName: "person.2")
                    }
                }
            }
            #endif
            ToolbarItem(placement: .primaryAction) {
                Button(action: toggleActions) {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showingSoundboard) {
            SoundboardSheet(conversationID: conversationID)
                .environment(model)
        }
        .sheet(isPresented: $showingYouTube) {
            YouTubePickerSheet(conversationID: conversationID)
                .environment(model)
        }
        .onAppear {
            model.conversationOpened(conversationID)
            model.conversationViewed(conversationID, isFrontmost)
        }
        .onDisappear { model.conversationClosed(conversationID) }
        .onChange(of: isFrontmost) { _, frontmost in
            model.conversationViewed(conversationID, frontmost)
        }
        .onChange(of: model.isSignedOn) { _, signedOn in
            if !signedOn { dismiss() }
        }
    }

    /// The chat's actions, collapsed behind the header's overflow button so the bar
    /// carries one control instead of three.
    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            actionButton("waveform", "Sounds") { showingSoundboard = true }
            // Lit red while something is on the stage, the way the mic is while
            // it's open — and the glyph says what tapping it now does: stop.
            actionButton(isOnStage(.youtube) ? "stop.fill" : YouTubeExtension.symbol,
                         "YouTube", tint: isOnStage(.youtube) ? .red : nil) {
                if isOnStage(.youtube) {
                    model.closeStage(in: conversationID)
                } else {
                    showingYouTube = true
                }
            }
            .disabled(stageIsProtected(against: .youtube))
            fourButton
            actionButton(micIsLive ? "mic.fill" : "mic", "Voice",
                         tint: micIsLive ? .red : nil, pulsing: micIsLive) {
                model.toggleMic(in: conversationID)
            }
        }
        // Sizes the sheet to its widest label, then stretches the rest to match
        // so every row is one full-width tap target.
        .fixedSize(horizontal: true, vertical: false)
        .padding(5)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.separator.opacity(0.6), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .disabled(peerOffline || groupEnded)
    }

    /// Four's glyph is drawn rather than an SF Symbol, so while the game is up
    /// the row becomes the way out of it — a red ✗, the same convention as
    /// YouTube's `stop.fill`.
    @ViewBuilder
    private var fourButton: some View {
        if isOnStage(.four) {
            actionButton("xmark", FourExtension.name, tint: .red) {
                model.closeStage(in: conversationID)
            }
        } else {
            actionButton(FourExtension.name, action: {
                model.sendStageAction(.four(.start), in: conversationID)
            }, icon: {
                FourBoardIcon()
                    .fill(style: FillStyle(eoFill: true))
                    .frame(width: 19, height: 16)
            })
            .disabled(stageIsProtected(against: .four))
        }
    }

    private func actionButton(_ symbol: String, _ label: String, tint: Color? = nil,
                              pulsing: Bool = false,
                              action: @escaping () -> Void) -> some View {
        actionButton(label, tint: tint, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .symbolEffect(.pulse, isActive: pulsing)
        }
    }

    private func actionButton<Icon: View>(_ label: String, tint: Color? = nil,
                                          action: @escaping () -> Void,
                                          @ViewBuilder icon: () -> Icon) -> some View {
        Button {
            toggleActions()
            action()
        } label: {
            HStack(spacing: 10) {
                icon()
                    .foregroundStyle(tint ?? Color.accentColor)
                    .frame(width: 22)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(tint ?? Color.primary)
            }
            .frame(height: 38)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggleActions() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            showingActions.toggle()
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
            if peerViewing {
                ViewingDot()
            }
            if group != nil {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(showingMembers ? 180 : 0))
            }
        }
        .contentShape(Rectangle())
    }

    /// The peer has this chat on screen right now.
    private struct ViewingDot: View {
        var body: some View {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Has this chat open")
        }
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
                avatar: model.avatar(of: member.id),
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
                            UserAvatar(avatar: model.avatar(of: speaker.id),
                                       monogram: speaker.handle)
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
            #if os(iOS)
            voiceExit
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    #if os(iOS)
    /// Whoever is talking gets off the mic here; whoever is only listening
    /// decides whether to keep hearing it.
    @ViewBuilder
    private var voiceExit: some View {
        if micIsLive {
            StageExit(label: "End Voice", symbol: "mic.slash.fill") {
                model.toggleMic(in: conversationID)
            }
        } else if othersSpeaking {
            let muted = model.voiceMuted(in: conversationID)
            StageExit(label: muted ? "Unmute Voice" : "Mute Voice",
                      symbol: muted ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                model.toggleVoiceMute(in: conversationID)
            }
        }
    }
    #endif

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
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                ForEach(Array(transcript.enumerated()), id: \.element.id) { index, item in
                    Group {
                        switch item {
                        case .message(let message):
                            let isMine = message.senderID == model.currentUser?.id
                            let bot = model.bot(withID: message.senderID)
                            MessageRow(
                                message: message,
                                isMine: isMine,
                                senderName: (group != nil && !isMine && bot == nil)
                                    ? model.handle(of: message.senderID) : nil,
                                senderAvatar: (group != nil && !isMine)
                                    ? model.avatar(of: message.senderID) : nil,
                                bot: bot,
                                botIsLabelled: group != nil,
                                botAliases: model.botAliases,
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
                if let peerID, model.isTyping(peerID) {
                    HStack {
                        TypingIndicatorBubble()
                        Spacer()
                    }
                    .id("typingIndicator")
                    .modifier(PopInEffect(enabled: true, anchor: .bottomLeading))
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            // Breathing room under the newest bubble at rest.
            .padding(.bottom, 10)
        }
        // Keeps the newest message in view, on open and as messages
        // arrive, without a scrollTo. `scrollTo(_:anchor: .bottom)` aligns
        // the target with the scroll view's *bounds*, which is below the
        // composer — it scrolls a bar's height too far and drags the tail
        // of the transcript into the blur. Resting here instead leaves the
        // newest message crisp, since the edge effect only blurs content
        // actually underneath a bar.
        .defaultScrollAnchor(.bottom)
        // Both the stage and the composer hang off the transcript rather
        // than stacking around it, so messages scroll under them and blur
        // out at each edge. The stage also keeps its place in the view tree
        // whatever else comes and goes, so the player is never rebuilt
        // mid-video.
        .modifier(ScrollEdgeBar(edge: .top) {
            if let stage = model.stages[conversationID] {
                StageArea(conversationID: conversationID, stage: stage)
                    .environment(\.stageBox, stageBox)
            }
        })
        .modifier(ScrollEdgeBar(edge: .bottom) { composer })
        // A swipe down the transcript puts the keyboard away, which is the
        // only thing that reclaims the screen when a stage and the keyboard
        // are up at once. Interactively rather than immediately so the
        // keyboard tracks the finger and a short scroll doesn't lose it.
        .scrollDismissesKeyboard(.interactively)
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
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !peerOffline && !groupEnded
    }

    /// Only the one-time model download — live words go in the draft bubble,
    /// where the message itself will land. A silent multi-second wait
    /// otherwise reads as a hang.
    /// The strip above the composer that says what the field is about to do.
    /// Dictation uses it while it warms up; a bot tag uses it to name where the
    /// message is headed, since a bolded tag says something is different but
    /// not what.
    private func composerHint(_ title: String, detail: String? = nil,
                              systemImage: String, pulsing: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(title)
                    .italic()
                if let detail {
                    Text(detail)
                        .font(.caption2)
                }
            }
            Image(systemName: systemImage)
                .symbolEffect(.variableColor.iterative, isActive: pulsing)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .transition(.opacity)
    }

    private var dictationBar: some View {
        composerHint("Preparing…", detail: "Downloading the language model",
                     systemImage: "waveform", pulsing: true)
    }

    /// Names the bot the draft is tagging, and whether the conversation rides
    /// along. Derived from the draft as it's typed — nothing is sent yet.
    private var botHint: String? {
        guard let tagged = model.taggedBot(in: draft) else { return nil }
        return tagged.wantsContext
            ? "Send to \(tagged.bot.displayName) (include chat)"
            : "Send to \(tagged.bot.displayName)"
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
            } else if let botHint {
                composerHint(botHint, systemImage: "sparkles")
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
                // Return still inserts a newline here, as the vertical-axis
                // TextField this replaced did; the button is how you send.
                ComposerField(text: $draft, placeholder: "Message",
                              aliases: model.botAliases, onSubmit: {})
                    .padding(.leading, 14)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty, let peerID {
                            model.sendTyping(to: peerID)
                        }
                    }
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
                ComposerField(text: $draft, placeholder: "Message",
                              aliases: model.botAliases, onSubmit: send)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                    .onChange(of: draft) { _, newValue in
                        if !newValue.isEmpty, let peerID {
                            model.sendTyping(to: peerID)
                        }
                    }
                Button("Send", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSend)
            }
            .padding(12)
            #endif
        }
        // The hint appears and disappears mid-keystroke as a tag is typed or
        // backspaced, so it fades rather than snapping the composer up a line.
        .animation(.easeInOut(duration: 0.18), value: botHint)
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
    /// Set when a bot sent this — styles the bubble as the bot's.
    var bot: Bot?
    /// Groups label every speaker, so a bot names itself there too. A 1:1
    /// labels nobody, so neither does the bot.
    var botIsLabelled = false
    /// Every registered bot tag, for bolding one at the head of a human
    /// message. Empty when the server runs no bots.
    var botAliases: [String] = []
    var recencyFraction: Double = 1

    private var incomingBackground: Color { .incomingBubble }

    /// A tagged bot's name is read off the bubble body, so it's bolded in
    /// everyone's copy of the message — not just the sender's.
    private var body_: AttributedString {
        var text = AttributedString(message.body)
        guard bot == nil,
              let match = BotTag.match(message.body, aliases: botAliases),
              let range = Range(match.tagRange, in: text)
        else { return text }
        text[range].font = .body.bold()
        return text
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
            // A bot has no avatar to show — and a placeholder head would read
            // as a person's. Its own glyph instead, and only where the rest of
            // the messages carry one: in a 1:1 nothing else is labelled, so a
            // labelled bot bubble sits oddly proud of the conversation. The
            // bubble's colour already says who is speaking.
            if bot != nil {
                if botIsLabelled {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
            } else {
                UserAvatar(avatar: senderAvatar, size: 24)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let name = botIsLabelled ? (bot?.displayName ?? senderName) : senderName {
                    Text(name)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)
                }
                // The glyph rides beside the bubble, not the row, so it stays
                // centered on the bubble whatever else the row carries.
                HStack(alignment: .center, spacing: 6) {
                    if isMine, message.dictated == true { dictationGlyph }
                    Text(body_)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background {
                            if bot != nil {
                                Color.botBubble
                            } else if isMine {
                                LinearGradient(
                                    colors: [Self.historyBlue(recencyFraction - 0.06),
                                             Self.historyBlue(recencyFraction)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            } else {
                                incomingBackground
                            }
                        }
                        .foregroundStyle(botOrOwnForeground)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    if !isMine, message.dictated == true { dictationGlyph }
                }
            }
            if !isMine { Spacer(minLength: 48) }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }

    private var botOrOwnForeground: Color {
        if bot != nil { .botBubbleText } else if isMine { .white } else { .primary }
    }
}
