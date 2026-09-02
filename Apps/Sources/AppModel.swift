import AVFoundation
import Foundation
import Observation
import SwiftUI
import TotemKit

#if os(macOS)
import AppKit
#endif

@Observable @MainActor
final class AppModel {
    var currentUser: User?
    var buddies: [Buddy] = []
    var presences: [UUID: Presence] = [:]
    var machine = PresenceStateMachine()

    /// A transcript mixes real messages with centered system notices
    /// (away-status changes), iMessage-group-event style.
    enum TranscriptItem: Identifiable, Hashable {
        case message(ChatMessage)
        case notice(id: UUID, text: String, at: Date)

        var id: UUID {
            switch self {
            case .message(let message): message.id
            case .notice(let id, _, _): id
            }
        }
    }

    /// Transcripts keyed by conversation ID — derived from the participant
    /// set (`ConversationID.derive`), the same value for every shape of chat
    /// and every party in it. Scoped to the local user's own online session:
    /// one continuous log while signed on, no matter how often peers come and
    /// go; cleared when this user's session ends (deliberate sign-off, or a
    /// `freshSignOn` welcome after the server marked them offline). Never
    /// persisted — messages live only in the RAM of currently-online
    /// participants.
    var transcripts: [UUID: [TranscriptItem]] = [:]
    /// Group rosters by conversation ID. Kept after a group's sitting ends so
    /// an open window still renders names — `endedGroups` marks those.
    var groupSessions: [UUID: SessionInfo] = [:]
    /// Groups whose sitting has ended (fewer than two participants left).
    /// The roster stays renderable; sending is over until it's started again.
    var endedGroups: Set<UUID> = []
    /// Derived pair conversation ID → the buddy behind it, rebuilt from the
    /// buddy list. How an incoming conversation-keyed frame gets back to a
    /// person to render.
    private var pairPeers: [UUID: UUID] = [:]
    /// Bots this server runs, by bot ID — from the `welcome` frame, so a new
    /// bot needs no client build. Used to render a bot's bubbles and to bold
    /// its tag; the server alone decides whether a bot actually answers.
    var bots: [UUID: Bot] = [:]
    /// Newest build testers can install, as of the last `welcome`. Nil when the
    /// server hasn't been told one — every comparison against it then fails
    /// closed, so a server without the variable set simply shows no banner.
    private(set) var latestBuild: String?
    /// Peers with messages not yet seen. Local-only — never sent over the
    /// wire; the spec's no-read-receipts rule is about the other party.
    var unreadPeers: Set<UUID> = []
    private var activeConversations: Set<UUID> = []
    /// The one conversation on screen in a frontmost window — narrower than
    /// `activeConversations`, which is every open chat. Sent to the server
    /// on every change and again after a reconnect, since the server forgets
    /// it with the socket.
    private var viewedConversation: UUID? {
        didSet {
            guard viewedConversation != oldValue else { return }
            fire(.viewing(conversationID: viewedConversation))
        }
    }
    /// Pair conversations the peer has on screen right now — the header dot.
    var peerViewing: Set<UUID> = []
    /// Peers currently typing. Plain observable state (expired by tasks, not
    /// polled) so views update reliably — offscreen TimelineViews pause on iOS.
    private var typingPeers: Set<UUID> = []
    private var typingExpiry: [UUID: Task<Void, Never>] = [:]
    /// The most recently appended transcript item, stamped with the local
    /// clock — drives entrance animations without trusting server timestamps.
    private var lastAppended: (id: UUID, at: Date)?
    private var pendingSends: [UUID: UUID] = [:]
    /// Where the last outbound message was typed — server error frames carry
    /// no context, so refusals ("they're offline") surface as notices there.
    private var lastSentConversation: UUID?
    private var lastTypingSentAt: [UUID: Date] = [:]
    /// Live voice: the conversation the local mic streams into (one at a
    /// time) and who we currently hear, per conversation. Speakers are
    /// inferred from chunk arrival and expire after a beat of silence —
    /// no explicit mic-state frames on the wire.
    var liveMicConversation: UUID?
    var speakingUsers: [UUID: Set<UUID>] = [:]
    /// Participants whose device can't play audio right now (volume at zero),
    /// per conversation — drives the crossed-out speaker row while voice is
    /// live so speakers know who can't hear them.
    var mutedListeners: [UUID: Set<UUID>] = [:]
    /// Conversations this user chose not to hear. Packets still arrive and
    /// still drive the meters, so who's talking stays visible; only the
    /// speaker is skipped. Scoped to the chat being open, like voice itself.
    private var mutedConversations: Set<UUID> = []
    /// Conversations we've told peers *we* can't hear — cleared when hearing
    /// comes back (with a follow-up frame) or the chat goes silent.
    private var reportedMutedConversations: Set<UUID> = []
    /// Per-chunk spectrum frames for the speaker meters, keyed by speaking user.
    var speakerSpectrum: [UUID: [Float]] = [:]
    /// What's on each conversation's stage, keyed by conversation ID. The
    /// server owns this: clients send actions and render whatever comes back,
    /// never applying anything optimistically.
    var stages: [UUID: Stage] = [:]
    /// Conversations already told (via notice) that playback is broken —
    /// throttles the notice to once per sign-on.
    private var playbackFailureNoticed: Set<UUID> = []
    private var speakingExpiry: [UUID: Task<Void, Never>] = [:]
    private var captureTask: Task<Void, Never>?
    /// Dictation: the conversation the mic is being transcribed into — one at
    /// a time, and the same mic the broadcast uses.
    var dictationConversation: UUID?
    /// True only while the language model actually downloads.
    var dictationPreparing = false
    /// `VoiceTranscriber` where the OS has it; stored untyped because stored
    /// properties can't carry an availability annotation.
    private var dictationTranscriber: AnyObject?
    private var dictationSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let audio = AudioStreamer()
    /// The peer-to-peer side of live voice, one per sign-on: it exists while
    /// the socket does, since the server is what introduces its peers.
    private var voice: VoiceLink?

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?
    /// Server-side setting: push "X signed on" to this account's devices
    /// while the app is closed.
    var signOnPushes = UserDefaults.standard.object(forKey: "signOnPushes") as? Bool ?? true

    // MARK: - Appearance

    enum Appearance: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    var appearance = Appearance(
        rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system

    func setAppearance(_ appearance: Appearance) {
        self.appearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
    }

    var colorScheme: ColorScheme? {
        switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    // MARK: - Avatar

    /// This account's look, or nil while its owner has never picked one — an
    /// unchosen avatar is never published, so nobody renders a face this user
    /// didn't pick.
    var avatar: Avatar? = {
        guard let data = UserDefaults.standard.data(forKey: "avatar") else { return nil }
        return try? JSONDecoder().decode(Avatar.self, from: data)
    }()

    /// Live value behind the settings sliders — views mutate it freely while
    /// dragging, and `commitAvatar()` persists and uploads on release. The
    /// default look stands in for the editor until the first edit makes it
    /// this owner's actual choice.
    var avatarSetting: Avatar {
        get { avatar ?? Avatar() }
        set { avatar = newValue }
    }

    /// Set while an edit hasn't reached the server. Survives relaunch so a
    /// change made offline still wins the next reconciliation instead of
    /// being silently overwritten by the server's older copy.
    private var avatarNeedsUpload = UserDefaults.standard.bool(forKey: "avatarNeedsUpload")

    /// Persist locally and push to the server, which embeds it in this
    /// user's DTO — and fans it out to everyone currently rendering us.
    func commitAvatar() {
        let committed = avatarSetting
        storeAvatarLocally(committed)
        setAvatarNeedsUpload(true)
        let api = self.api
        Task { [weak self] in
            do {
                try await api.setAvatar(committed)
            } catch {
                return
            }
            // A newer edit may have landed mid-flight; that one still owes an
            // upload of its own.
            guard let self, avatar == committed else { return }
            setAvatarNeedsUpload(false)
        }
    }

    /// Reconciles this device with the account using the `welcome` frame's
    /// copy. An account with no avatar gets this device's chosen one —
    /// installs signed in before avatars existed never pass through `signIn`
    /// again — while a device whose owner never picked one publishes nothing.
    /// Otherwise the account's copy wins, so a second device can't overwrite
    /// it with a stale local one, unless this device is still holding an edit
    /// the server never received.
    private func reconcileAvatar(remote: Avatar?) {
        guard !avatarNeedsUpload else {
            commitAvatar()
            return
        }
        guard let remote else {
            if avatar != nil {
                commitAvatar()
            }
            return
        }
        guard remote != avatar else { return }
        storeAvatarLocally(remote)
    }

    private func storeAvatarLocally(_ avatar: Avatar) {
        self.avatar = avatar
        UserDefaults.standard.set(try? JSONEncoder().encode(avatar), forKey: "avatar")
    }

    private func setAvatarNeedsUpload(_ pending: Bool) {
        avatarNeedsUpload = pending
        UserDefaults.standard.set(pending, forKey: "avatarNeedsUpload")
    }

    init() {
        NotificationManager.shared.activate()
        audio.onOutputVolumeChange = { [weak self] in self?.outputVolumeChanged() }
        pruneUnreadableSamples()
        #if os(macOS)
        observeSystemSleep()
        #endif
        if let saved = UserDefaults.standard.string(forKey: "serverURL"),
           let url = URL(string: saved) {
            api.baseURL = url
        }
        if let token = UserDefaults.standard.string(forKey: "authToken"),
           let data = UserDefaults.standard.data(forKey: "currentUser"),
           let user = try? WireCoder.decoder().decode(User.self, from: data) {
            api.token = token
            currentUser = user
            // Sign on immediately rather than after the buddy fetch: the
            // socket reconnects on its own, whereas gating on a fetch that
            // failed transiently left the app stuck on the Sign On screen.
            signOn()
            Task {
                for attempt in 1...3 {
                    do {
                        try await refreshBuddies()
                        return
                    } catch URLError.userAuthenticationRequired {
                        logOut()
                        return
                    } catch {
                        try? await Task.sleep(for: .seconds(Double(attempt) * 2))
                    }
                }
            }
        }
    }

    /// Dismissed for this launch only: the update is still waiting next time,
    /// and a build nobody updates to is one the server has already moved past.
    var updateBannerDismissed = false

    /// Whether TestFlight is offering something newer than what's running.
    /// Locally-built copies never qualify — see `BuildStamp`.
    var updateAvailable: Bool {
        !updateBannerDismissed
            && BuildStamp.isOutdated(Self.currentBuild, latestAvailable: latestBuild)
    }

    private static let currentBuild = Bundle.main.infoDictionary?["CFBundleVersion"] as? String

    var isSignedOn: Bool { machine.isSignedOn }
    var isReconnecting: Bool { machine.isReconnecting }
    var selfState: PresenceState { machine.displayState }
    var awayMessage: String? { machine.awayMessage }

    var acceptedBuddies: [Buddy] {
        buddies.filter { $0.status == .accepted }.sorted { $0.user.handle < $1.user.handle }
    }

    func presence(of buddy: Buddy) -> Presence {
        presences[buddy.user.id] ?? .offline
    }

    var onlineBuddyCount: Int {
        acceptedBuddies.filter { presence(of: $0).state != .offline }.count
    }

    // MARK: - Auth

    func signIn(handle: String, serverURL: String) async throws {
        guard let url = URL(string: serverURL) else { throw URLError(.badURL) }
        api.baseURL = url
        let response = try await api.devLogin(handle: handle)
        api.token = response.token
        currentUser = response.user

        let defaults = UserDefaults.standard
        defaults.set(response.token, forKey: "authToken")
        defaults.set(try? WireCoder.encoder().encode(response.user), forKey: "currentUser")
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(handle, forKey: "lastHandle")

        try await refreshBuddies()
        // Signing in is already a deliberate act — flow straight into presence.
        // The separate Sign On button is for subsequent launches.
        signOn()
    }

    func logOut() {
        if isSignedOn { signOff() }
        currentUser = nil
        api.token = nil
        buddies = []
        rebuildPairIndex()
        presences = [:]
        groupSessions = [:]
        clearSessionScopedState()
        UserDefaults.standard.removeObject(forKey: "authToken")
        UserDefaults.standard.removeObject(forKey: "currentUser")
    }

    func refreshBuddies() async throws {
        buddies = try await api.buddies()
        rebuildPairIndex()
        // Contextual, never at launch (spec §7): ask only once buddies exist.
        if !buddies.isEmpty {
            NotificationManager.shared.requestPermissionIfNeeded()
        }
    }

    // MARK: - Conversation identity

    /// The 1:1 conversation with a buddy — computed, never fetched, so
    /// tapping a name opens a chat with no round trip.
    func conversationID(with buddyID: UUID) -> UUID? {
        currentUser.map { ConversationID.derive([$0.id, buddyID]) }
    }

    /// The buddy behind a pair conversation, nil for groups (and for pair
    /// IDs no current buddy derives to).
    func peer(of conversationID: UUID) -> UUID? {
        pairPeers[conversationID]
    }

    private func rebuildPairIndex() {
        guard let selfID = currentUser?.id else {
            pairPeers = [:]
            return
        }
        pairPeers = Dictionary(uniqueKeysWithValues: buddies.map {
            (ConversationID.derive([selfID, $0.user.id]), $0.user.id)
        })
    }

    /// Ascending by the requester's open-request count, so people who
    /// blast requests broadly sort to the bottom.
    var incomingRequests: [Buddy] {
        buddies.filter { $0.status == .pending && $0.incoming }
            .sorted {
                let (l, r) = ($0.openRequestCount ?? 0, $1.openRequestCount ?? 0)
                return l == r ? $0.user.handle < $1.user.handle : l < r
            }
    }

    var outgoingRequests: [Buddy] {
        buddies.filter { $0.status == .pending && !$0.incoming }
    }

    func addBuddy(handle: String) async throws {
        try await api.sendBuddyRequest(handle: handle)
        try await refreshBuddies()
    }

    /// The buddy record for a user in any state (accepted or pending, either
    /// direction), or nil when there's no relationship at all.
    func relationship(with userID: UUID) -> Buddy? {
        buddies.first { $0.user.id == userID }
    }

    /// Group-chat co-participants with no buddy relationship: quick-add
    /// candidates, most recent session first.
    var recentNonFriends: [User] {
        let related = Set(buddies.map(\.user.id))
        var seen = Set<UUID>()
        return groupSessions.values
            .sorted { $0.session.startedAt > $1.session.startedAt }
            .flatMap(\.participants)
            .filter {
                $0.id != currentUser?.id && !related.contains($0.id) && seen.insert($0.id).inserted
            }
    }

    func acceptRequest(_ buddy: Buddy) async throws {
        try await api.acceptBuddyRequest(id: buddy.id)
        try await refreshBuddies()
    }

    // MARK: - Presence

    func signOn() {
        guard let token = api.token, !isSignedOn else { return }
        apply(machine.handle(.signOn))
        refreshPushSettings()
        let socket = SocketClient(url: api.socketURL, token: token)
        self.socket = socket
        let voice = VoiceLink(
            onTicket: { [weak self] ticket in
                Task { @MainActor in self?.fire(.announceEndpoint(ticket: ticket)) }
            },
            onFrame: { [weak self] frame in
                Task { @MainActor in
                    self?.receiveAudio(conversationID: frame.conversationID,
                                       senderID: frame.senderID, packet: frame.packet)
                }
            })
        self.voice = voice
        Task { await voice.start() }
        socketTask = Task { [weak self] in
            for await event in await socket.events() {
                await self?.handle(event)
            }
        }
    }

    /// Session-scoped ephemerality: none of this outlives the local user's own
    /// online session, so it is cleared on sign-off, on a fresh sign-on that
    /// ended the previous session, and on log-out.
    private func clearSessionScopedState() {
        transcripts = [:]
        endedGroups = []
        pendingSends = [:]
        unreadPeers = []
        mutedListeners = [:]
        mutedConversations = []
        reportedMutedConversations = []
        stages = [:]
        peerViewing = []
    }

    func signOff() {
        apply(machine.handle(.signOff))
        socketTask?.cancel()
        let socket = self.socket
        Task { await socket?.close() }
        self.socket = nil
        let voice = self.voice
        Task { await voice?.stop() }
        self.voice = nil
        presences = [:]
        // Sign-off closes all conversation windows (spec §3); views observe
        // isSignedOn and dismiss themselves.
        clearSessionScopedState()
        typingPeers = []
        typingExpiry.values.forEach { $0.cancel() }
        typingExpiry = [:]
        stopMic()
        audio.stopAll()
        speakingUsers = [:]
        speakerSpectrum = [:]
        playbackFailureNoticed = []
        speakingExpiry.values.forEach { $0.cancel() }
        speakingExpiry = [:]
    }

    // MARK: - Chat

    func buddy(withID id: UUID) -> Buddy? {
        acceptedBuddies.first { $0.user.id == id }
    }

    // MARK: - Bots

    func bot(withID id: UUID) -> Bot? { bots[id] }

    var botAliases: [String] { bots.values.flatMap(\.aliases) }

    /// The bot a draft or body tags, if any, and whether that tag asks for the
    /// conversation. The same match the server runs, from the same shared
    /// matcher — so what the composer promises is what actually happens.
    func taggedBot(in body: String) -> (bot: Bot, wantsContext: Bool)? {
        guard let hit = BotTag.match(body, bots: Array(bots.values)) else { return nil }
        return (hit.bot, hit.bot.wantsContext(hit.match.tag))
    }

    /// The conversation so far, flattened for a bot prompt — but only when the
    /// tag used asks for it. The server keeps no transcript, so this client is
    /// the only party that can answer "what has been said", and it sends that
    /// nowhere else.
    ///
    /// Notices ("X signed on") are left out: they are chrome this app draws,
    /// not things anyone said.
    private func botContext(for body: String, in conversationID: UUID) -> [BotContextMessage]? {
        guard let tagged = taggedBot(in: body), tagged.wantsContext else { return nil }
        let items = (transcripts[conversationID] ?? []).suffix(Limits.botContextMaxMessages)
        return items.compactMap { item in
            guard case .message(let message) = item else { return nil }
            let speaker: String
            if let bot = bots[message.senderID] {
                speaker = bot.displayName
            } else if message.senderID == currentUser?.id {
                speaker = currentUser?.handle ?? "me"
            } else {
                speaker = handle(of: message.senderID) ?? "someone"
            }
            return BotContextMessage(speaker: speaker, body: message.body)
        }
    }

    func sendMessage(to conversationID: UUID, body: String, dictated: Bool = false) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clientID = UUID()
        pendingSends[clientID] = conversationID
        lastSentConversation = conversationID
        let spoken = dictated ? true : nil
        let context = botContext(for: trimmed, in: conversationID)
        let frame: ClientFrame = .send(
            conversationID: conversationID, body: trimmed,
            clientMessageID: clientID, dictated: spoken, botContext: context)
        let socket = self.socket
        Task { [weak self] in
            do {
                guard let socket else { throw URLError(.networkConnectionLost) }
                try await socket.send(frame)
            } catch {
                // The ack will never come — say so where the message was typed.
                self?.pendingSends[clientID] = nil
                self?.append(.notice(id: UUID(), text: "Message not sent — connection lost",
                                     at: Date()),
                             to: conversationID)
            }
        }
    }

    /// One participant is the pair conversation, whose ID this client can
    /// compute itself — no server involved in opening it. More participants
    /// asks the server to start (or restart) the group's sitting.
    func startChat(with participantIDs: [UUID]) async throws -> UUID {
        if participantIDs.count == 1, let pairID = conversationID(with: participantIDs[0]) {
            return pairID
        }
        let info = try await api.createSession(participantIDs: participantIDs)
        groupSessions[info.session.id] = info
        endedGroups.remove(info.session.id)
        return info.session.id
    }

    func conversationTitle(_ conversationID: UUID) -> String {
        if let info = groupSessions[conversationID] {
            return info.participants
                .filter { $0.id != currentUser?.id }
                .map(\.handle)
                .sorted()
                .joined(separator: ", ")
        }
        if let peerID = peer(of: conversationID) {
            return buddy(withID: peerID)?.user.handle ?? "chat"
        }
        return "chat"
    }

    func handle(of userID: UUID) -> String? {
        if userID == currentUser?.id { return currentUser?.handle }
        if let buddy = buddy(withID: userID) { return buddy.user.handle }
        for info in groupSessions.values {
            if let user = info.participants.first(where: { $0.id == userID }) {
                return user.handle
            }
        }
        return nil
    }

    /// Patches every cached copy of a user's avatar. Both caches are DTO
    /// snapshots — the buddy list is fetched at launch, group participants
    /// when the session opened — so a live change has to be written into
    /// each of them rather than waiting on a refetch.
    private func applyAvatar(_ avatar: Avatar, of userID: UUID) {
        for index in buddies.indices where buddies[index].user.id == userID {
            buddies[index].user.avatar = avatar
        }
        for (sessionID, info) in groupSessions {
            guard info.participants.contains(where: { $0.id == userID }) else { continue }
            var participants = info.participants
            for index in participants.indices where participants[index].id == userID {
                participants[index].avatar = avatar
            }
            groupSessions[sessionID] = SessionInfo(
                session: info.session, participants: participants)
        }
    }

    /// Last known avatar for a user: own live settings, else the buddy list,
    /// else the snapshot a group session carried when it was initiated —
    /// both kept current by `avatarChanged` pushes.
    func avatar(of userID: UUID) -> Avatar? {
        if userID == currentUser?.id { return avatar }
        if let buddyAvatar = buddy(withID: userID)?.user.avatar { return buddyAvatar }
        for info in groupSessions.values {
            if let user = info.participants.first(where: { $0.id == userID }) {
                return user.avatar
            }
        }
        return nil
    }

    // MARK: - Sound samples

    /// A short recorded sound the user can broadcast into a chat from the
    /// mic button's long-press menu. Audio lives on this device only, as
    /// Opus packets in Application Support (`OpusPacketFile`); only the
    /// labels are listed here (persisted in UserDefaults).
    struct SoundSample: Identifiable, Codable, Hashable {
        let id: UUID
        var label: String
    }

    static let maxSoundSamples = 3
    static let sampleMaxSeconds: Double = 10

    var soundSamples: [SoundSample] = {
        guard let data = UserDefaults.standard.data(forKey: "soundSamples"),
              let samples = try? JSONDecoder().decode([SoundSample].self, from: data)
        else { return [] }
        return samples
    }()
    var isRecordingSample = false
    var sampleRecordingSeconds: Double = 0
    private var sampleRecordingPackets: [Data] = []

    private var samplesDir: URL {
        URL.applicationSupportDirectory.appendingPathComponent("SoundSamples", isDirectory: true)
    }

    private func sampleURL(_ id: UUID) -> URL {
        samplesDir.appendingPathComponent("\(id).opus")
    }

    /// Samples recorded before the Opus cutover are in a format nothing can
    /// play any more; their files and labels go together.
    private func pruneUnreadableSamples() {
        let stale = soundSamples.filter { !FileManager.default.fileExists(atPath: sampleURL($0.id).path) }
        guard !stale.isEmpty else { return }
        for sample in stale {
            try? FileManager.default.removeItem(at: samplesDir.appendingPathComponent("\(sample.id).pcm"))
        }
        soundSamples.removeAll { stale.contains($0) }
        persistSamples()
    }

    func startSampleRecording() async -> Bool {
        stopMic()
        sampleRecordingPackets = []
        sampleRecordingSeconds = 0
        let started = await audio.startMic(onPacket: { [weak self] packet, _ in
            Task { @MainActor in self?.appendSamplePacket(packet) }
        })
        isRecordingSample = started
        return started
    }

    private func appendSamplePacket(_ packet: Data) {
        guard isRecordingSample else { return }
        sampleRecordingPackets.append(packet)
        sampleRecordingSeconds = Double(sampleRecordingPackets.count) * 0.02
        if sampleRecordingSeconds >= Self.sampleMaxSeconds {
            stopSampleRecording()
        }
    }

    func stopSampleRecording() {
        guard isRecordingSample else { return }
        isRecordingSample = false
        audio.stopMic()
    }

    func saveRecordedSample(label: String) {
        stopSampleRecording()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sampleRecordingPackets.isEmpty,
              soundSamples.count < Self.maxSoundSamples
        else { return }
        let sample = SoundSample(id: UUID(), label: String(trimmed.prefix(30)))
        do {
            try FileManager.default.createDirectory(
                at: samplesDir, withIntermediateDirectories: true)
            try OpusPacketFile.encode(sampleRecordingPackets).write(to: sampleURL(sample.id))
        } catch {
            print("sample save failed: \(error)")
            return
        }
        soundSamples.append(sample)
        persistSamples()
        sampleRecordingPackets = []
        sampleRecordingSeconds = 0
    }

    func deleteSample(_ sample: SoundSample) {
        try? FileManager.default.removeItem(at: sampleURL(sample.id))
        soundSamples.removeAll { $0.id == sample.id }
        persistSamples()
    }

    private func persistSamples() {
        if let encoded = try? JSONEncoder().encode(soundSamples) {
            UserDefaults.standard.set(encoded, forKey: "soundSamples")
        }
    }

    /// Broadcasts a sample into the chat over the same peer links as the mic,
    /// paced in real time so recipients' meters and speaker expiry behave
    /// normally — and looped back locally so the sender hears it too.
    func playSample(_ sample: SoundSample, in conversationID: UUID) {
        guard let voice, let selfID = currentUser?.id,
              let data = try? Data(contentsOf: sampleURL(sample.id))
        else { return }
        let packets = OpusPacketFile.decode(data)
        guard !packets.isEmpty else { return }
        voice.setRecipients(voiceRecipients(in: conversationID), of: conversationID)
        Task { [weak self] in
            for packet in packets {
                voice.send(packet, in: conversationID)
                self?.receiveAudio(conversationID: conversationID, senderID: selfID, packet: packet)
                try? await Task.sleep(for: AudioStreamer.frameDuration)
            }
        }
    }

    // MARK: - Live voice

    /// Stream the mic to the conversation. Closing it closes dictation too —
    /// that rides on the same mic and has no control of its own once the mic
    /// is off.
    func toggleMic(in conversationID: UUID) {
        if liveMicConversation == conversationID {
            stopSelfMonitor(in: conversationID)
            liveMicConversation = nil
            dictationConversation = nil
        } else {
            claimMic(for: conversationID)
            liveMicConversation = conversationID
        }
        applyCapture(in: conversationID)
    }

    /// Also transcribe the open mic on-device, sending each utterance as an
    /// ordinary message — indistinguishable from typing at the other end.
    /// Rides on the mic rather than claiming it: never changes mic state.
    func toggleDictation(in conversationID: UUID) {
        guard dictationSupported, liveMicConversation == conversationID else { return }
        dictationConversation = dictationConversation == conversationID
            ? nil : conversationID
        applyCapture(in: conversationID)
    }

    /// The mic serves one conversation at a time; opening it elsewhere closes
    /// whatever it was doing before.
    private func claimMic(for conversationID: UUID) {
        guard let previous = liveMicConversation ?? dictationConversation,
              previous != conversationID
        else { return }
        stopSelfMonitor(in: previous)
        liveMicConversation = nil
        dictationConversation = nil
        applyCapture(in: previous)
    }

    /// The self monitor ends with the mic, not after the silence expiry: a
    /// speaker strip that outlives the mic offers the listener's controls.
    /// The tap can still deliver a frame or two after this — those are
    /// dropped where they'd re-light it.
    private func stopSelfMonitor(in conversationID: UUID) {
        guard let selfID = currentUser?.id else { return }
        speakingUsers[conversationID]?.remove(selfID)
        speakerSpectrum[selfID] = nil
        speakingExpiry[selfID]?.cancel()
        speakingExpiry[selfID] = nil
    }

    func stopMic() {
        captureTask?.cancel()
        captureTask = nil
        if let conversationID = liveMicConversation {
            stopSelfMonitor(in: conversationID)
        }
        liveMicConversation = nil
        dictationConversation = nil
        let stopDictating = takeDictationStop()
        audio.stopMic()
        if let stopDictating { Task { await stopDictating() } }
    }

    /// Drops dictation state now and hands back the stop the transcriber still
    /// owes. Clearing has to be synchronous — a caller that returns before the
    /// fields are nil would let the next toggle see a transcriber that is on
    /// its way out — while the stop itself can only be awaited. The two
    /// callers differ in nothing but whether they are able to await it.
    private func takeDictationStop() -> (@Sendable () async -> Void)? {
        dictationPreparing = false
        dictationSink = nil
        let transcriber = dictationTranscriber
        dictationTranscriber = nil
        guard #available(iOS 26.0, macOS 26.0, *),
              let transcriber = transcriber as? VoiceTranscriber
        else { return nil }
        return { await transcriber.stop() }
    }

    /// Reconciles the mic tap with the two toggles: the tap carries exactly
    /// the sinks currently wanted and is torn down once both are off. Runs
    /// serially so rapid toggling can't interleave two setups.
    private func applyCapture(in conversationID: UUID) {
        let previous = captureTask
        captureTask = Task { [weak self] in
            _ = await previous?.value
            // `stopMic` cancels the chain, so a toggle queued before it can't
            // reclaim the mic afterwards — sample recording borrows it too.
            guard !Task.isCancelled else { return }
            await self?.reconcileCapture(in: conversationID)
        }
    }

    private func reconcileCapture(in conversationID: UUID) async {
        if dictationConversation == conversationID {
            await startDictation(in: conversationID)
        } else {
            await stopDictation()
        }
        if liveMicConversation == conversationID, voice == nil {
            liveMicConversation = nil
        }
        let broadcasting = liveMicConversation == conversationID
        guard broadcasting || dictationSink != nil else {
            audio.stopMic()
            return
        }

        var packetSink: (@Sendable (Data, [Float]) -> Void)?
        if broadcasting, let voice {
            voice.setRecipients(voiceRecipients(in: conversationID), of: conversationID)
            let selfID = currentUser?.id
            packetSink = { [weak self] packet, spectrum in
                // Straight off the audio thread: the link is thread-safe and
                // datagrams don't block.
                voice.send(packet, in: conversationID)
                // Meter-only self monitor (no playback — that would echo)
                // so the speaker can see their own audio going out.
                guard let selfID else { return }
                Task { @MainActor in
                    guard let self, self.liveMicConversation == conversationID else { return }
                    self.markSpeaking(selfID, in: conversationID, spectrum: spectrum)
                }
            }
        }

        guard await audio.startMic(onPacket: packetSink, onBuffer: dictationSink) else {
            stopMic()
            return
        }
    }

    /// Who hears voice in a conversation: the buddy of a pair, or everyone
    /// else in a group. Anyone the server hasn't introduced yet is simply
    /// not dialled.
    private func voiceRecipients(in conversationID: UUID) -> Set<UUID> {
        if let peerID = peer(of: conversationID) { return [peerID] }
        var members = Set(groupSessions[conversationID]?.participants.map(\.id) ?? [])
        if let selfID = currentUser?.id { members.remove(selfID) }
        return members
    }

    // MARK: - Dictation

    /// The conversation the mic is open for, whichever way it's being used.
    private var micConversation: UUID? { liveMicConversation ?? dictationConversation }

    var dictationSupported: Bool {
        if #available(iOS 26.0, macOS 26.0, *) {
            return VoiceTranscriber.isSupported
        }
        return false
    }

    private func startDictation(in conversationID: UUID) async {
        guard dictationSink == nil else { return }
        guard #available(iOS 26.0, macOS 26.0, *) else {
            dictationConversation = nil
            return
        }
        let transcriber = VoiceTranscriber(
            onUtterance: { [weak self] text in
                self?.sendMessage(to: conversationID, body: text, dictated: true)
            },
            onDownloading: { [weak self] downloading in
                self?.dictationPreparing = downloading
            })
        do {
            dictationSink = try await transcriber.start()
            dictationTranscriber = transcriber
        } catch {
            print("dictation failed to start: \(error)")
            dictationConversation = nil
            append(.notice(id: UUID(), text: "Dictation unavailable", at: Date()),
                   to: conversationID)
        }
    }

    private func stopDictation() async {
        guard dictationTranscriber != nil else { return }
        if let stopDictating = takeDictationStop() { await stopDictating() }
    }

    /// Voice is scoped to having the chat open, both directions: drop the mic
    /// if it was live here, and stop anything still coming in.
    private func silenceConversation(_ conversationID: UUID) {
        if micConversation == conversationID { stopMic() }
        mutedListeners[conversationID] = nil
        mutedConversations.remove(conversationID)
        reportedMutedConversations.remove(conversationID)
        for senderID in speakingUsers.removeValue(forKey: conversationID) ?? [] {
            audio.stopSpeaker(senderID)
            speakingExpiry[senderID]?.cancel()
            speakingExpiry[senderID] = nil
            speakerSpectrum[senderID] = nil
        }
    }

    func voiceMuted(in conversationID: UUID) -> Bool {
        mutedConversations.contains(conversationID)
    }

    /// Stop (or resume) hearing a conversation. To whoever is talking it is
    /// the same fact as the volume being at zero: this listener can't hear.
    func toggleVoiceMute(in conversationID: UUID) {
        if mutedConversations.remove(conversationID) == nil {
            mutedConversations.insert(conversationID)
            if !(speakingUsers[conversationID] ?? []).isEmpty {
                reportMutedIfNeeded(in: conversationID)
            }
        } else {
            reportHearingIfRestored(in: conversationID)
        }
    }

    /// Whether live voice in a conversation reaches this user's ears right now.
    private func cannotHear(in conversationID: UUID) -> Bool {
        audio.outputMuted || mutedConversations.contains(conversationID)
    }

    /// On transitions only: while audio is audible in a conversation, tell its
    /// participants whether this device can actually play it.
    private func outputVolumeChanged() {
        if audio.outputMuted {
            for conversationID in speakingUsers.keys
            where !(speakingUsers[conversationID] ?? []).isEmpty {
                reportMutedIfNeeded(in: conversationID)
            }
        } else {
            for conversationID in reportedMutedConversations {
                reportHearingIfRestored(in: conversationID)
            }
        }
    }

    private func reportMutedIfNeeded(in conversationID: UUID) {
        guard cannotHear(in: conversationID), !reportedMutedConversations.contains(conversationID)
        else { return }
        reportedMutedConversations.insert(conversationID)
        sendAudioMuted(true, in: conversationID)
    }

    private func reportHearingIfRestored(in conversationID: UUID) {
        guard !cannotHear(in: conversationID),
              reportedMutedConversations.remove(conversationID) != nil
        else { return }
        sendAudioMuted(false, in: conversationID)
    }

    private func sendAudioMuted(_ muted: Bool, in conversationID: UUID) {
        fire(.setMuted(conversationID: conversationID, muted: muted))
    }

    /// Best-effort send: these frames carry no promise to the user, so a
    /// failure is dropped. `sendMessage` reports its own instead.
    private func fire(_ frame: ClientFrame) {
        let socket = self.socket
        Task { try? await socket?.send(frame) }
    }

    /// Throttled to one event per 3s per peer (spec §6).
    func sendTyping(to peerID: UUID) {
        let now = Date()
        if let last = lastTypingSentAt[peerID], now.timeIntervalSince(last) < 3 { return }
        lastTypingSentAt[peerID] = now
        fire(.typing(recipientID: peerID))
    }

    func isTyping(_ peerID: UUID) -> Bool {
        typingPeers.contains(peerID)
    }

    func isNewlyAppended(_ itemID: UUID) -> Bool {
        guard let last = lastAppended, last.id == itemID else { return false }
        return Date().timeIntervalSince(last.at) < 3
    }

    private func append(_ item: TranscriptItem, to peerID: UUID) {
        transcripts[peerID, default: []].append(item)
        lastAppended = (item.id, Date())
    }

    private func clearTyping(_ peerID: UUID) {
        typingPeers.remove(peerID)
        typingExpiry[peerID]?.cancel()
        typingExpiry[peerID] = nil
    }

    /// Termination path: mark signed off and hand the socket to the caller,
    /// which flushes the sign-off frame outside the main actor while the
    /// process winds down. UI cleanup is skipped — the process is dying.
    func detachSocketForTermination() -> SocketClient? {
        guard isSignedOn else { return nil }
        machine.handle(.signOff)
        socketTask?.cancel()
        let detached = socket
        socket = nil
        return detached
    }

    func conversationOpened(_ peerID: UUID) {
        activeConversations.insert(peerID)
        unreadPeers.remove(peerID)
        // Stage pushes that landed while this chat was closed were dropped, so
        // ask for the current one rather than rendering a stale stage.
        fire(.requestStage(conversationID: peerID))
    }

    /// A chat reports itself viewed when it's on screen in the frontmost
    /// window and not otherwise; with one window per conversation on macOS
    /// several can report, so only the one reporting true wins.
    func conversationViewed(_ conversationID: UUID, _ viewed: Bool) {
        if viewed {
            viewedConversation = conversationID
        } else if viewedConversation == conversationID {
            viewedConversation = nil
        }
    }

    // MARK: - Stage

    /// Conditional actions carry the version they were aimed at, so the server
    /// can drop one that no longer applies to what's on the stage now.
    func sendStageAction(_ action: StageAction, in conversationID: UUID) {
        fire(.stageAction(conversationID: conversationID, action: action,
                          expectedVersion: action.isConditional ? stages[conversationID]?.version : nil))
    }

    func closeStage(in conversationID: UUID) {
        fire(.closeStage(conversationID: conversationID))
    }

    func searchYouTube(_ query: String) async throws -> [YouTubeVideo] {
        try await api.searchYouTube(query)
    }

    /// Where the player web view loads from. The start position is resolved
    /// against the shared clock, so a late joiner opens mid-song where
    /// everyone else already is.
    func playerURL(for youtube: YouTubeState) -> URL {
        api.playerURL(videoID: youtube.videoID,
                      start: youtube.position(at: Date()),
                      playing: youtube.isPlaying)
    }

    /// After a reconnect the stage may have moved on without us — anything
    /// pushed during the gap never arrived — and the server forgot what this
    /// socket had told it: what's on screen, and where our voice endpoint is.
    private func resendAfterReconnect() {
        for conversationID in activeConversations {
            fire(.requestStage(conversationID: conversationID))
        }
        if let viewedConversation {
            fire(.viewing(conversationID: viewedConversation))
        }
        if let ticket = voice?.ticket {
            fire(.announceEndpoint(ticket: ticket))
        }
    }

    private func applyStage(_ stage: Stage?, in conversationID: UUID, from senderID: UUID?) {
        let previous = stages[conversationID]
        stages[conversationID] = stage
        // Snapshot replies and re-syncs after a rejected action carry no
        // sender: nobody did anything, so nothing is worth announcing.
        guard let senderID, let handle = handle(of: senderID),
              let text = Self.stageNotice(from: previous, to: stage, by: handle)
        else { return }
        append(.notice(id: UUID(), text: text, at: Date()), to: conversationID)
    }

    /// Only stage changes worth interrupting the transcript for. Play and pause
    /// are deliberately silent — they're visible on the stage and would bury
    /// the conversation.
    private static func stageNotice(from previous: Stage?, to stage: Stage?,
                                    by handle: String) -> String? {
        guard let stage else {
            guard let previous else { return nil }
            switch previous.state {
            case .youtube: return "\(handle) closed the video"
            case .four(let game):
                // A finished game already announced its result; taking the
                // board down afterwards isn't news.
                return game.outcome == nil ? "\(handle) closed the game" : nil
            }
        }
        switch stage.state {
        case .youtube(let youtube):
            if case .youtube(let old)? = previous?.state, old.videoID == youtube.videoID {
                return nil
            }
            return "\(handle) put on \"\(youtube.title)\""

        case .four(let game):
            guard case .four(let old)? = previous?.state else {
                return "\(handle) started a game of Four"
            }
            // Playing again on top of a finished board.
            if old.outcome != nil {
                return game.outcome == nil ? "\(handle) started a game of Four" : nil
            }
            // Joining and every drop are silent — they're plain on the board,
            // and a notice per move would bury the conversation. Only the
            // result is worth interrupting for, and the sender is the player
            // who just made it.
            switch game.outcome {
            case .won: return "\(handle) won"
            case .draw: return "Four ended in a draw"
            case nil: return nil
            }
        }
    }

    func conversationClosed(_ peerID: UUID) {
        activeConversations.remove(peerID)
        conversationViewed(peerID, false)
        silenceConversation(peerID)
    }

    /// Most recent distinct away messages, newest first — the quick-tap
    /// options in the away sheet.
    var recentAwayMessages: [String] =
        UserDefaults.standard.stringArray(forKey: "recentAwayMessages") ?? []

    func setAwayMessage(_ message: String) {
        apply(machine.handle(.setAwayMessage(message)))
        // Record what the machine actually kept (trimmed, truncated).
        guard let saved = machine.awayMessage else { return }
        recentAwayMessages.removeAll { $0 == saved }
        recentAwayMessages.insert(saved, at: 0)
        recentAwayMessages = Array(recentAwayMessages.prefix(3))
        UserDefaults.standard.set(recentAwayMessages, forKey: "recentAwayMessages")
    }

    func clearAwayMessage() {
        apply(machine.handle(.clearAwayMessage))
    }

    #if os(macOS)
    /// System sleep is the "I'm away" boundary. Without this, the reconnect
    /// loop re-establishes the socket during dark wakes (Power Nap), which the
    /// server reads as a fresh sign-on — buddies get pushed "signed on" all
    /// day while the lid is closed. Deliberate sign-off kills the reconnect
    /// loop; dark wakes don't post didWake, so only a real wake signs back on.
    private var resumeOnWake = false

    private func observeSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isSignedOn else { return }
                self.resumeOnWake = true
                self.signOff()
            }
        }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.resumeOnWake else { return }
                self.resumeOnWake = false
                self.signOn()
            }
        }
    }
    #endif

    // MARK: - Push notifications

    /// Called by the app delegate once iOS hands over the APNs token.
    func registerPushToken(_ token: String) {
        let api = self.api
        Task { try? await api.registerPushToken(token) }
    }

    func setSignOnPushes(_ enabled: Bool) {
        signOnPushes = enabled
        UserDefaults.standard.set(enabled, forKey: "signOnPushes")
        let api = self.api
        Task { try? await api.setPushSettings(.init(signOnPushes: enabled)) }
    }

    private func refreshPushSettings() {
        let api = self.api
        Task {
            if let settings = try? await api.pushSettings() {
                signOnPushes = settings.signOnPushes
                UserDefaults.standard.set(settings.signOnPushes, forKey: "signOnPushes")
            }
        }
    }

    private func apply(_ effects: [PresenceStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .sendPresence(let state, let awayMessage):
                fire(.setPresence(state: state, awayMessage: awayMessage))
            case .playSignOnSound:
                SoundPlayer.play(.signOn)
            case .playSignOffSound:
                SoundPlayer.play(.signOff)
            }
        }
    }

    // MARK: - Socket events

    private func handle(_ event: SocketClient.ConnectionEvent) {
        switch event {
        case .connected:
            apply(machine.handle(.reconnected))
        case .disconnected:
            apply(machine.handle(.connectionLost))
        case .frame(let frame):
            handle(frame)
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .welcome(_, let buddies, let sessions, let freshSignOn, let selfAvatar, let bots,
                      let latestBuild):
            // Describes the server, not this sign-on, so it survives the
            // session-scoped wipe below alongside the bot registry.
            self.latestBuild = latestBuild
            reconcileAvatar(remote: selfAvatar)
            // The registry outlives a session — it describes the server, not
            // this sign-on — so it's set before the session-scoped wipe below.
            self.bots = Dictionary(uniqueKeysWithValues: (bots ?? []).map { ($0.id, $0) })
            // A fresh sign-on means the server ended our previous online
            // session (suspension sweep, >90s drop, sign-off) — everything
            // conversation-scoped from before it is gone. A reconnect within
            // the grace window keeps the log intact.
            if freshSignOn {
                clearSessionScopedState()
            }
            // Socket state on the server's side too: anyone still looking is
            // re-announced right after this frame.
            peerViewing = []
            presences = Dictionary(uniqueKeysWithValues: buddies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            let live = Dictionary(
                uniqueKeysWithValues: sessions.filter(\.isGroup).map { ($0.session.id, $0) })
            if freshSignOn {
                groupSessions = live
            } else {
                // A group we knew that's absent from the snapshot died while
                // we weren't looking — no sessionClosed reached us. Its
                // roster stays renderable behind the ended mark.
                for id in groupSessions.keys where live[id] == nil {
                    endedGroups.insert(id)
                }
                groupSessions.merge(live) { _, new in new }
                endedGroups.subtract(live.keys)
            }
            resendAfterReconnect()
        case .sessionStarted(let info):
            if info.isGroup {
                groupSessions[info.session.id] = info
                // The same combination restarted is the same conversation —
                // its sitting is live again.
                endedGroups.remove(info.session.id)
            }
        case .avatarChanged(let userID, let avatar):
            applyAvatar(avatar, of: userID)
        case .presence(let userID, let presence):
            let previous = presences[userID]
            let wasOffline = (previous?.state ?? .offline) == .offline
            presences[userID] = presence
            if presence.state == .offline {
                voice?.removePeer(userID)
            }
            // Where this buddy's conversation lives — notices about a person
            // land in the chat with that person.
            let pairID = conversationID(with: userID)
            let hasConversation = pairID.map {
                !(transcripts[$0] ?? []).isEmpty || activeConversations.contains($0)
            } ?? false
            if let handle = buddy(withID: userID)?.user.handle, wasOffline,
               presence.state != .offline {
                NotificationManager.shared.buddySignedOn(userID, handle: handle)
            }
            if let handle = buddy(withID: userID)?.user.handle, hasConversation,
               let pairID {
                let nowOffline = presence.state == .offline
                if wasOffline != nowOffline {
                    append(.notice(id: UUID(), text: "\(handle) signed \(nowOffline ? "off" : "on")", at: Date()),
                           to: pairID)
                }
                let wasAway = previous?.state == .away
                if let away = presence.awayMessage, away != previous?.awayMessage {
                    append(.notice(id: UUID(), text: "\(handle) is away: \"\(away)\"", at: Date()),
                           to: pairID)
                } else if presence.isUnreachableMark, !wasAway {
                    // The server marked them away because it couldn't reach
                    // them, so there's nothing of theirs to quote.
                    append(.notice(id: UUID(), text: "\(handle) is away", at: Date()),
                           to: pairID)
                }
                // Coming back from away — but not by signing off, which
                // already got its own notice above.
                if wasAway, presence.state != .away, presence.state != .offline {
                    append(.notice(id: UUID(), text: "\(handle) is back", at: Date()),
                           to: pairID)
                }
            }
            // Presence for someone not yet an accepted buddy means the list
            // changed server-side (e.g. our request was just accepted).
            if !buddies.contains(where: { $0.user.id == userID && $0.status == .accepted }) {
                Task { try? await refreshBuddies() }
            }
            if wasOffline && presence.state != .offline {
                SoundPlayer.play(.buddyIn)
            } else if !wasOffline && presence.state == .offline {
                SoundPlayer.play(.buddyOut)
            }
            // An offline user isn't a muted listener, just gone.
            if presence.state == .offline {
                for key in mutedListeners.keys {
                    mutedListeners[key]?.remove(userID)
                }
                // A 1:1 stage dies with the conversation, same as the server's
                // copy — group stages outlive any one member going offline.
                if let pairID {
                    stages[pairID] = nil
                    peerViewing.remove(pairID)
                }
            }
        case .message(let message):
            // The message carries its conversation: `sessionID` is the
            // derived conversation ID, the key this client renders by. No
            // inference from the sender — that inference is what filed 1:1
            // messages into a group when the server keyed them wrong.
            append(.message(message), to: message.sessionID)
            clearTyping(message.senderID)
            if !activeConversations.contains(message.sessionID) {
                unreadPeers.insert(message.sessionID)
            }
            SoundPlayer.play(.messageReceived)
        case .botMessage(let conversationID, let message):
            append(.message(message), to: conversationID)
            if !activeConversations.contains(conversationID) {
                unreadPeers.insert(conversationID)
            }
            SoundPlayer.play(.messageReceived)
        case .messageSent(let clientMessageID, let message):
            if pendingSends.removeValue(forKey: clientMessageID) != nil {
                append(.message(message), to: message.sessionID)
                SoundPlayer.play(.messageSent)
            }
        case .typing(let userID):
            typingPeers.insert(userID)
            typingExpiry[userID]?.cancel()
            typingExpiry[userID] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                self?.typingPeers.remove(userID)
            }
        case .viewing(let conversationID, _, let viewing):
            if viewing {
                peerViewing.insert(conversationID)
            } else {
                peerViewing.remove(conversationID)
            }
        case .endpoint(let userID, let ticket):
            voice?.setPeer(userID, ticket: ticket)
        case .audioMuted(let conversationID, let userID, let muted):
            guard activeConversations.contains(conversationID) else { return }
            if muted {
                mutedListeners[conversationID, default: []].insert(userID)
            } else {
                mutedListeners[conversationID]?.remove(userID)
            }
        case .sessionClosed(let sessionID):
            // The conversation's sitting ended — fewer than two participants
            // left. Our own transcript survives (it's scoped to our online
            // session, not the sitting), and for a group the roster stays
            // renderable behind an `endedGroups` mark; starting the same
            // combination again revives the same conversation ID. Only the
            // live ephemera stop.
            if groupSessions[sessionID] != nil {
                endedGroups.insert(sessionID)
            }
            if let peerID = peer(of: sessionID) {
                clearTyping(peerID)
            }
            silenceConversation(sessionID)
        case .stage(let conversationID, let senderID, let stage):
            applyStage(stage, in: conversationID, from: senderID)
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .error(let message):
            print("server error: \(message)")
            if let conversationID = lastSentConversation {
                append(.notice(id: UUID(), text: message, at: Date()), to: conversationID)
            }
        }
    }

    /// One live-voice packet reaching the ears and meters — from a peer, or
    /// looped back locally while broadcasting a sound sample. A peer's packet
    /// only counts for a conversation they're actually in: the link vouches
    /// for who sent it, not for what they labelled it.
    private func receiveAudio(conversationID: UUID, senderID: UUID, packet: Data) {
        // Live voice only reaches ears with that chat open.
        guard activeConversations.contains(conversationID),
              senderID == currentUser?.id || voiceRecipients(in: conversationID).contains(senderID)
        else { return }
        let spectrum: [Float]
        switch audio.play(packet, from: senderID,
                          audible: !mutedConversations.contains(conversationID)) {
        case .heard(let heard):
            spectrum = heard
        case .silent(let reason):
            spectrum = Array(repeating: 0, count: AudioAnalyzer.bandCount)
            if !playbackFailureNoticed.contains(conversationID) {
                playbackFailureNoticed.insert(conversationID)
                append(.notice(id: UUID(), text: "Can't play live audio — \(reason)", at: Date()),
                       to: conversationID)
            }
        }
        // A silent chat just became audible — if our volume is at zero,
        // that's the moment the speaker needs to know we can't hear.
        if (speakingUsers[conversationID] ?? []).isEmpty {
            reportMutedIfNeeded(in: conversationID)
        }
        markSpeaking(senderID, in: conversationID, spectrum: spectrum)
    }

    /// Lights up the speaker meters for one frame — remote audio, the local
    /// mic monitor, or a sample loopback — and schedules the quiet-expiry.
    private func markSpeaking(_ senderID: UUID, in conversationID: UUID, spectrum: [Float]) {
        speakingUsers[conversationID, default: []].insert(senderID)
        speakerSpectrum[senderID] = spectrum
        speakingExpiry[senderID]?.cancel()
        speakingExpiry[senderID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            self.speakingUsers[conversationID]?.remove(senderID)
            self.speakerSpectrum[senderID] = nil
            self.audio.stopSpeaker(senderID)
        }
    }
}
