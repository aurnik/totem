import SwiftUI
import TotemKit

/// A 1:1 or group conversation. Sending is disabled while the 1:1 peer is
/// offline, since messages are never stored server-side.
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
    /// Shrinks when the keyboard opens, and the stage shrinks with it.
    @State private var conversationSize: CGSize = .zero

    /// An upper bound on the stage, so it never leaves the chat a sliver.
    /// Only bites when space is tight.
    private var stageBox: CGSize {
        CGSize(width: conversationSize.width, height: conversationSize.height * 0.45)
    }

    private var group: SessionInfo? {
        model.groupSessions[conversationID]
    }

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

    /// Whether this chat is actually on screen: the app in front on iOS,
    /// this window key on macOS.
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

    /// The group's sitting ended. The transcript and roster stay readable;
    /// sending resumes only if the same combination is started again.
    private var groupEnded: Bool {
        model.endedGroups.contains(conversationID)
    }

    private var micIsLive: Bool {
        model.liveMicConversation == conversationID
    }

    private var dictating: Bool {
        model.dictationConversation == conversationID
    }

    /// Everyone audible in this chat. The self monitor counts only while the
    /// local mic is live.
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

    /// Another extension holds the stage and would lose state if this one
    /// took it. The owner would refuse anyway, so don't offer it.
    private func stageIsProtected(against id: ChatExtensionID) -> Bool {
        guard let stage = model.stages[conversationID] else { return false }
        return stage.state.extensionID != id && stage.state.preservesState
    }

    private func isOnStage(_ id: ChatExtensionID) -> Bool {
        model.stages[conversationID]?.state.extensionID == id
    }

    /// Up to three participants in the title's handle order. Anyone without
    /// a published avatar is left out.
    private var groupHeaderAvatars: [Avatar] {
        (group?.participants ?? [])
            .filter { $0.id != model.currentUser?.id }
            .sorted { $0.handle < $1.handle }
            .prefix(3)
            .compactMap { model.avatar(of: $0.id) }
    }

    private var peerState: PresenceState {
        peerID.flatMap { model.presences[$0]?.state } ?? .offline
    }

    /// Online but not looking at this chat reads at half strength.
    private var peerAttention: Double {
        peerState == .online && !peerViewing ? 0.5 : 1
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
            // Voice holds the top while anyone is audible or the mic is open.
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
                // For groups the title drops down the member list.
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

    /// The chat's actions, collapsed behind the header's overflow button.
    private var actionMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            actionButton("waveform", "Sounds") { showingSoundboard = true }
            // Lit red while on the stage, and the glyph says what a tap does.
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
        // Sizes to the widest label; rows then stretch to match it.
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

    /// Four's glyph is drawn rather than an SF Symbol, so a live game swaps
    /// the row for a red ✗. Only a player can end a game.
    @ViewBuilder
    private var fourButton: some View {
        if isOnStage(.four), isFourPlayer {
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
            .disabled(stageIsProtected(against: .four) || fourInProgress)
        }
    }

    private var currentGame: FourState? {
        guard case .four(let game)? = model.stages[conversationID]?.state else { return nil }
        return game
    }

    private var isFourPlayer: Bool {
        guard let game = currentGame, let me = model.currentUser?.id else { return false }
        return game.red == me || game.yellow == me
    }

    private var fourInProgress: Bool {
        currentGame?.outcome == nil && currentGame != nil
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
            if group != nil {
                HStack(spacing: -10) {
                    ForEach(Array(groupHeaderAvatars.enumerated()), id: \.offset) { _, avatar in
                        AvatarHeadView(avatar: avatar, size: 26, animated: false)
                    }
                }
            } else if let peerID {
                PresenceAvatar(avatar: model.avatar(of: peerID), state: peerState, size: 26)
                    .opacity(peerAttention)
                    .animation(.default, value: peerAttention)
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

    #if os(macOS)
    private struct ViewingDot: View {
        var body: some View {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("Has this chat open")
        }
    }
    #endif

    private func toggleMembers() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingMembers.toggle()
        }
    }

    /// Every other participant, with an add-friend button for non-friends.
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
            // Request already sent.
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        } else {
            // Accepts their pending request if there is one, else sends ours.
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

    /// Speaking users beside their live EQ, plus a row naming participants
    /// whose device can't play audio.
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
            if let status = model.voiceStatus(in: conversationID) {
                voiceStatusLine(status)
            }
            #if os(iOS)
            voiceExit
            #endif
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.12))
    }

    /// The link state in plain words: a call opens through a relay and moves
    /// to a direct path once hole punching lands.
    private func voiceStatusLine(_ status: AppModel.VoiceStatus) -> some View {
        HStack(spacing: 5) {
            switch status {
            case .connecting:
                Image(systemName: "ellipsis.circle")
                Text("Connecting…")
            case .relay:
                Image(systemName: "antenna.radiowaves.left.and.right")
                Text("Connected · finding a faster route")
            case .direct:
                Image(systemName: "checkmark.circle.fill")
                Text("Best connection")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.default, value: status)
    }

    #if os(iOS)
    /// Ends the mic for a speaker, or mutes for a listener.
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
                                pending: isMine && model.isPendingDelivery(message.id),
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
                        // Only genuinely new messages pop.
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
            .padding(.bottom, 10)
        }
        // Not `scrollTo(_:anchor: .bottom)`: that aligns the target with the
        // scroll view's bounds, which sit below the composer, so it overshoots
        // by a bar's height and drags the newest bubble into the edge blur.
        .defaultScrollAnchor(.bottom)
        // The stage and composer hang off the transcript rather than stacking
        // around it, so messages scroll under them and blur at each edge, and
        // the stage keeps its place in the view tree so the player is never
        // rebuilt mid-video.
        .modifier(ScrollEdgeBar(edge: .top) {
            if let stage = model.stages[conversationID] {
                StageArea(conversationID: conversationID, stage: stage)
                    .environment(\.stageBox, stageBox)
            }
        })
        .modifier(ScrollEdgeBar(edge: .bottom) { composer })
        // Interactively, so the keyboard tracks the finger and a short scroll
        // doesn't dismiss it.
        .scrollDismissesKeyboard(.interactively)
    }

    /// 1 for the newest message, easing to 0 over the last 25.
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

    /// The strip above the composer saying what the field is about to do:
    /// dictation warming up, or the bot a tag will send to.
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

    /// Names the bot the draft tags and whether the conversation rides along.
    private var botHint: String? {
        guard let tagged = model.taggedBot(in: draft) else { return nil }
        return tagged.wantsContext
            ? "Send to \(tagged.bot.displayName) (include chat)"
            : "Send to \(tagged.bot.displayName)"
    }

    /// An outgoing bubble that fills in when dictation is on. Fill and border
    /// are both always present and cross-fade through their colors; swapping
    /// one shape for the other gives SwiftUI nothing to interpolate.
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
                // Outside the color cross-fade so the two don't drive each other.
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
            // Dictation rides on the open mic, so it needs the mic on.
            if model.dictationSupported, micIsLive {
                HStack {
                    Spacer(minLength: 0)
                    dictationToggle
                }
                .padding(.horizontal, 14)
            }
            #if os(iOS)
            HStack(alignment: .bottom, spacing: 0) {
                // Return inserts a newline; the button is how you send.
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
        // The hint comes and goes mid-keystroke, so it fades rather than
        // snapping the composer up a line.
        .animation(.easeInOut(duration: 0.18), value: botHint)
    }

    private func send() {
        guard canSend else { return }
        model.sendMessage(to: conversationID, body: draft)
        draft = ""
    }
}

/// Fade-and-grow entrance for new transcript content, anchored where the
/// bubble sprouts from. Animates from `onAppear` so SwiftUI renders the
/// pre-animation state first instead of coalescing both into one frame.
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

/// An incoming-gray bubble with three staggered pulsing dots.
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
    /// Unacknowledged by at least one recipient, drawn at half strength.
    var pending: Bool = false
    var senderName: String?
    var senderAvatar: Avatar?
    /// Set when a bot sent this, which styles the bubble as the bot's.
    var bot: Bot?
    /// Groups label every speaker, bots included; a 1:1 labels nobody.
    var botIsLabelled = false
    /// Every registered bot tag, for bolding one in a human message.
    var botAliases: [String] = []
    var recencyFraction: Double = 1

    private var incomingBackground: Color { .incomingBubble }

    /// Derived from the body, so the tag is bolded in everyone's copy.
    private var attributedBody: AttributedString {
        var text = AttributedString(message.body)
        guard bot == nil,
              let match = BotTag.match(message.body, aliases: botAliases),
              let range = Range(match.tagRange, in: text)
        else { return text }
        text[range].font = .body.bold()
        return text
    }

    /// iMessage blue for the newest messages, washing out into history. Each
    /// bubble spans a slice of the ramp so the transcript reads as one
    /// continuous gradient.
    private static func historyBlue(_ fraction: Double) -> Color {
        let f = min(max(fraction, 0), 1)
        return Color(
            red: 0.45 * (1 - f),
            green: 0.72 + (0.478 - 0.72) * f,
            blue: 1.0
        )
    }

    /// Marks a spoken message, on the bubble's inward side.
    private var dictationGlyph: some View {
        Image(systemName: "mic.fill")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isMine { Spacer(minLength: 48) }
            // A bot gets a glyph rather than an avatar, and only where other
            // messages carry one. In a 1:1 the bubble color says enough.
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
                // Beside the bubble, not the row, so it stays centered on it.
                HStack(alignment: .center, spacing: 6) {
                    if isMine, message.dictated == true { dictationGlyph }
                    Text(attributedBody)
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
                        .opacity(pending ? 0.5 : 1)
                        .animation(.easeOut(duration: 0.2), value: pending)
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
