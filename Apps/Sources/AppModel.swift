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
    /// When each offline buddy was last knocked on; the button reads "Sent" for the throttle window.
    var knockedBuddies: [UUID: Date] = [:]
    var machine = PresenceStateMachine()

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

    /// Never persisted, and cleared whenever the local session ends.
    var transcripts: [UUID: [TranscriptItem]] = [:]
    /// Group rosters, kept after a sitting ends so a window still has names.
    var groupSessions: [UUID: SessionInfo] = [:]
    var endedGroups: Set<UUID> = []
    private var pairPeers: [UUID: UUID] = [:]
    /// Bots this server runs, by bot ID, from the `welcome` frame.
    var bots: [UUID: Bot] = [:]
    /// Newest build testers can install. Nil shows no banner.
    private(set) var latestBuild: String?
    /// Conversations with messages not yet seen. Local-only, never sent.
    var unreadPeers: Set<UUID> = []
    private var activeConversations: Set<UUID> = []
    /// Resent after a reconnect, since the server forgets it with the socket.
    private var viewedConversation: UUID? {
        didSet {
            guard viewedConversation != oldValue else { return }
            fire(.viewing(conversationID: viewedConversation))
        }
    }
    var peerViewing: Set<UUID> = []
    /// Peers currently typing. Plain observable state expired by tasks rather
    /// than polled, because offscreen TimelineViews pause on iOS.
    private var typingPeers: Set<UUID> = []
    private var typingExpiry: [UUID: Task<Void, Never>] = [:]
    /// Stamped locally, for entrance animations.
    private var lastAppended: (id: UUID, at: Date)?
    /// Server error frames carry no context, so refusals are noticed here.
    private var lastSentConversation: UUID?
    /// Pair conversations whose sitting this client has reported this session.
    private var reportedActive: Set<UUID> = []
    /// A completed write says nothing about delivery, so only an `ack` clears.
    private var unackedRecipients: [UUID: Set<UUID>] = [:]
    static let deliveryTimeout: Duration = .seconds(5)
    private var lastTypingSentAt: [UUID: Date] = [:]
    /// The conversation the local mic streams into, one at a time.
    var liveMicConversation: UUID?
    /// Inferred from packet arrival; there are no mic-state frames.
    var speakingUsers: [UUID: Set<UUID>] = [:]
    /// Participants whose device can't play audio right now, per conversation.
    var mutedListeners: [UUID: Set<UUID>] = [:]
    /// Conversations this user muted. Packets still drive the meters.
    private var mutedConversations: Set<UUID> = []
    var links: [UUID: PeerLink.LinkState] = [:]
    private var reportedMutedConversations: Set<UUID> = []
    var speakerSpectrum: [UUID: [Float]] = [:]
    /// What's on each conversation's stage. The owner (`Stage.ownerID`) runs
    /// the reducer; everyone else renders what the owner broadcasts back.
    var stages: [UUID: Stage] = [:]
    private var playbackFailureNoticed: Set<UUID> = []
    private var speakingExpiry: [UUID: Task<Void, Never>] = [:]
    private var captureTask: Task<Void, Never>?
    /// The conversation the mic is transcribed into, one at a time.
    var dictationConversation: UUID?
    /// True only while the language model downloads.
    var dictationPreparing = false
    /// A `VoiceTranscriber`; stored properties can't carry availability.
    private var dictationTranscriber: AnyObject?
    private var dictationSink: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private let audio = AudioStreamer()
    /// Lives exactly as long as the socket, which introduces its peers.
    private var peers: PeerLink?

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?
    /// Server-side setting: push sign-on alerts while the app is closed.
    var signOnPushes = UserDefaults.standard.object(forKey: "signOnPushes") as? Bool ?? false
    var needsNetworkExplainer = false

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

    /// This account's look, nil until its owner picks one.
    var avatar: Avatar? = {
        guard let data = UserDefaults.standard.data(forKey: "avatar") else { return nil }
        return try? JSONDecoder().decode(Avatar.self, from: data)
    }()

    /// Live value behind the settings sliders; `commitAvatar()` persists it.
    var avatarSetting: Avatar {
        get { avatar ?? Avatar() }
        set { avatar = newValue }
    }

    /// Survives relaunch so an edit made offline wins the next reconciliation.
    private var avatarNeedsUpload = UserDefaults.standard.bool(forKey: "avatarNeedsUpload")

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
            // A newer edit may have landed mid-flight; it owes its own upload.
            guard let self, avatar == committed else { return }
            setAvatarNeedsUpload(false)
        }
    }

    /// The account's copy wins unless this device holds an unuploaded edit,
    /// or the account has no avatar at all.
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
            // Before the buddy fetch: a transient failure there would
            // otherwise strand the app on the Sign On screen.
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

    /// Dismissed for this launch only.
    var updateBannerDismissed = false

    /// Locally-built copies never qualify; see `BuildStamp`.
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

    /// Asks the server to push "is knocking" to an offline buddy.
    func knock(_ buddy: Buddy) {
        knockedBuddies[buddy.user.id] = .now
        fire(.knock(userID: buddy.user.id))
    }

    /// Same window as the server's throttle, so the button re-enables when a knock would land again.
    func hasKnocked(_ buddy: Buddy, at now: Date = .now) -> Bool {
        guard let sent = knockedBuddies[buddy.user.id] else { return false }
        return now.timeIntervalSince(sent) < Limits.knockPushThrottle
    }

    // MARK: - Auth

    func signIn(handle: String, serverURL: String) async throws {
        guard let url = URL(string: serverURL) else { throw URLError(.badURL) }
        api.baseURL = url
        // Before the request: the attempt itself raises the system prompt,
        // whether or not the server answers.
        LocalNetworkExplainer.noteReached(url)
        let response = try await api.devLogin(handle: handle)
        api.token = response.token
        currentUser = response.user

        let defaults = UserDefaults.standard
        defaults.set(response.token, forKey: "authToken")
        defaults.set(try? WireCoder.encoder().encode(response.user), forKey: "currentUser")
        defaults.set(serverURL, forKey: "serverURL")
        defaults.set(handle, forKey: "lastHandle")

        try await refreshBuddies()
        // Signing in flows straight into presence.
        signOn()
    }

    func logOut() {
        if isSignedOn { signOff() }
        currentUser = nil
        api.token = nil
        buddies = []
        rebuildPairIndex()
        presences = [:]
        knockedBuddies = [:]
        groupSessions = [:]
        clearSessionScopedState()
        UserDefaults.standard.removeObject(forKey: "authToken")
        UserDefaults.standard.removeObject(forKey: "currentUser")
    }

    func refreshBuddies() async throws {
        buddies = try await api.buddies()
        rebuildPairIndex()
        // Ask only once buddies exist, never at launch.
        if !buddies.isEmpty {
            NotificationManager.shared.requestPermissionIfNeeded()
        }
    }

    // MARK: - Conversation identity

    /// Computed rather than fetched, so opening a chat costs no round trip.
    func conversationID(with buddyID: UUID) -> UUID? {
        currentUser.map { ConversationID.derive([$0.id, buddyID]) }
    }

    /// The buddy behind a pair conversation, nil for groups.
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

    /// Ascending by open-request count, so broad requesters sort last.
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

    func relationship(with userID: UUID) -> Buddy? {
        buddies.first { $0.user.id == userID }
    }

    /// Group co-participants who aren't buddies, most recent session first.
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
        // Signing on binds the voice endpoint, whose first LAN probe triggers
        // the system's local-network prompt. Explain it first.
        if LocalNetworkExplainer.isNeeded {
            needsNetworkExplainer = true
            return
        }
        apply(machine.handle(.signOn))
        refreshPushSettings()
        let socket = SocketClient(url: api.socketURL, token: token)
        self.socket = socket
        let peers = PeerLink(
            onTicket: { [weak self] ticket in
                Task { @MainActor in self?.fire(.announceEndpoint(ticket: ticket)) }
            },
            onAudio: { [weak self] frame in
                Task { @MainActor in
                    self?.receiveAudio(conversationID: frame.conversationID,
                                       senderID: frame.senderID, packet: frame.packet)
                }
            },
            onFrame: { [weak self] inbound in
                Task { @MainActor in self?.handle(inbound) }
            },
            onLink: { [weak self] userID, state in
                Task { @MainActor in self?.links[userID] = state }
            })
        self.peers = peers
        Task { await peers.start() }
        socketTask = Task { [weak self] in
            for await event in await socket.events() {
                await self?.handle(event)
            }
        }
    }

    func acknowledgeNetworkExplainer() {
        LocalNetworkExplainer.markShown()
        needsNetworkExplainer = false
        LocalNetworkExplainer.triggerPrompt()
        signOn()
    }

    /// Clears everything scoped to the local user's online session.
    private func clearSessionScopedState() {
        transcripts = [:]
        endedGroups = []
        reportedActive = []
        unackedRecipients = [:]
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
        let peers = self.peers
        Task { await peers?.stop() }
        self.peers = nil
        links = [:]
        presences = [:]
        // Views observe isSignedOn and dismiss their own windows.
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

    /// Runs the same shared matcher the server does.
    func taggedBot(in body: String) -> (bot: Bot, wantsContext: Bool)? {
        guard let hit = BotTag.match(body, bots: Array(bots.values)) else { return nil }
        return (hit.bot, hit.bot.wantsContext(hit.match.tag))
    }

    /// The conversation flattened for a bot prompt, minus notices, and only
    /// when the tag asks for it.
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

    /// The server never sees this. The message is appended immediately and
    /// stays half-lit until every recipient acks.
    func sendMessage(to conversationID: UUID, body: String, dictated: Bool = false) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let selfID = currentUser?.id else { return }
        lastSentConversation = conversationID
        let peerID = peer(of: conversationID)
        // A 1:1 to someone offline is refused, never spooled.
        if let peerID, (presences[peerID]?.state ?? .offline) == .offline {
            append(.notice(id: UUID(), text: "Message not delivered — they're offline", at: Date()),
                   to: conversationID)
            return
        }
        let message = ChatMessage(
            id: UUID(), sessionID: conversationID, senderID: selfID, body: trimmed,
            sentAt: Date(), dictated: dictated ? true : nil)
        append(.message(message), to: conversationID)
        SoundPlayer.play(.messageSent)
        noteTraffic(in: conversationID)
        // Bots are server services, so a tagged message is the one thing the
        // server is told about.
        if taggedBot(in: trimmed) != nil {
            fire(.botQuery(conversationID: conversationID, body: trimmed,
                           context: botContext(for: trimmed, in: conversationID)))
        }
        let recipients = participants(in: conversationID)
        // No recipients means delivered to no one, so it never lights.
        if !recipients.isEmpty {
            unackedRecipients[message.id] = recipients
        }
        for userID in recipients {
            peers?.sendBestEffort(.message(message), to: userID)
        }
        // An unacked 1:1 nudges the server to re-check reachability so the
        // buddy list can catch up. The bubble stays half-lit either way.
        if let peerID {
            Task { [weak self] in
                try? await Task.sleep(for: Self.deliveryTimeout)
                guard let self, self.isPendingDelivery(message.id) else { return }
                self.fire(.unreachable(userID: peerID))
            }
        }
    }

    private func markAcked(_ messageID: UUID, by userID: UUID) {
        guard var remaining = unackedRecipients[messageID] else { return }
        remaining.remove(userID)
        unackedRecipients[messageID] = remaining.isEmpty ? nil : remaining
    }

    /// Writes a frame to each recipient and returns whoever it couldn't reach.
    private func deliver(_ frame: PeerFrame, to recipients: Set<UUID>) async -> Set<UUID> {
        guard let peers else { return recipients }
        return await withTaskGroup(of: UUID?.self) { group in
            for userID in recipients {
                group.addTask {
                    do {
                        try await peers.send(frame, to: userID)
                        return nil
                    } catch {
                        return userID
                    }
                }
            }
            var failed = Set<UUID>()
            for await userID in group {
                if let userID { failed.insert(userID) }
            }
            return failed
        }
    }

    private func sendToPeers(_ frame: PeerFrame, _ recipients: Set<UUID>) {
        Task { [weak self] in _ = await self?.deliver(frame, to: recipients) }
    }

    /// Opens a pair's sitting on the first message either way this session.
    private func noteTraffic(in conversationID: UUID) {
        guard peer(of: conversationID) != nil, reportedActive.insert(conversationID).inserted
        else { return }
        fire(.conversationActive(conversationID: conversationID))
    }

    /// One participant derives the pair ID locally; more asks the server.
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

    /// Patches a user's avatar into the buddy list and every group roster.
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

    /// Own live settings, else the buddy list, else a group roster.
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

    /// The audio stays on this device as Opus packets; only the label is here.
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

    /// Drops labels whose Opus file is missing, and any legacy PCM beside it.
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
            Log.model.error("sample save failed: \(error)")
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

    /// Paced in real time so recipients' meters and speaker expiry behave.
    func playSample(_ sample: SoundSample, in conversationID: UUID) {
        guard let peers, let selfID = currentUser?.id,
              let data = try? Data(contentsOf: sampleURL(sample.id))
        else { return }
        let packets = OpusPacketFile.decode(data)
        guard !packets.isEmpty else { return }
        peers.setRecipients(participants(in: conversationID), of: conversationID)
        Task { [weak self] in
            for packet in packets {
                peers.send(packet, in: conversationID)
                self?.receiveAudio(conversationID: conversationID, senderID: selfID, packet: packet)
                try? await Task.sleep(for: AudioStreamer.frameDuration)
            }
        }
    }

    // MARK: - Live voice

    /// Streams the mic to the conversation, closing dictation with it.
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

    /// Also transcribes the open mic on-device, sending each utterance as an
    /// ordinary message. Rides on the mic and never changes its state.
    func toggleDictation(in conversationID: UUID) {
        guard dictationSupported, liveMicConversation == conversationID else { return }
        dictationConversation = dictationConversation == conversationID
            ? nil : conversationID
        applyCapture(in: conversationID)
    }

    /// The mic serves one conversation at a time.
    private func claimMic(for conversationID: UUID) {
        guard let previous = liveMicConversation ?? dictationConversation,
              previous != conversationID
        else { return }
        stopSelfMonitor(in: previous)
        liveMicConversation = nil
        dictationConversation = nil
        applyCapture(in: previous)
    }

    /// Ends with the mic, not the silence expiry, so no speaker strip
    /// outlives it offering listener controls.
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

    /// Clears synchronously, since the next toggle must not see a
    /// transcriber on its way out, and returns its stop to await.
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

    /// Reconciles the mic tap with both toggles, serially so rapid toggling
    /// can't interleave two setups.
    private func applyCapture(in conversationID: UUID) {
        let previous = captureTask
        captureTask = Task { [weak self] in
            _ = await previous?.value
            // `stopMic` cancels the chain, so a toggle queued before it can't
            // reclaim the mic that sample recording may now hold.
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
        if liveMicConversation == conversationID, peers == nil {
            liveMicConversation = nil
        }
        let broadcasting = liveMicConversation == conversationID
        guard broadcasting || dictationSink != nil else {
            audio.stopMic()
            return
        }

        var packetSink: (@Sendable (Data, [Float]) -> Void)?
        if broadcasting, let peers {
            peers.setRecipients(participants(in: conversationID), of: conversationID)
            let selfID = currentUser?.id
            packetSink = { [weak self] packet, spectrum in
                // Off the audio thread: datagrams don't block.
                peers.send(packet, in: conversationID)
                // Meter-only self monitor; playing it back would echo.
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

    /// Everyone else in a conversation: where frames go and who may send them.
    private func participants(in conversationID: UUID) -> Set<UUID> {
        if let peerID = peer(of: conversationID) { return [peerID] }
        var members = Set(groupSessions[conversationID]?.participants.map(\.id) ?? [])
        if let selfID = currentUser?.id { members.remove(selfID) }
        return members
    }

    /// A derived conversation ID is computable by anyone, so naming one is
    /// not a capability; this mirrors the server's `usableConversation`.
    private func canReceive(from senderID: UUID, in conversationID: UUID) -> Bool {
        guard participants(in: conversationID).contains(senderID) else { return false }
        return peer(of: conversationID) != nil || !endedGroups.contains(conversationID)
    }

    /// Keeps links warm to everyone in an open chat.
    private func refreshWarmLinks() {
        var wanted = Set<UUID>()
        for conversationID in activeConversations {
            wanted.formUnion(participants(in: conversationID))
        }
        peers?.keepWarm(wanted)
    }

    // MARK: - Dictation

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
            Log.model.error("dictation failed to start: \(error)")
            dictationConversation = nil
            append(.notice(id: UUID(), text: "Dictation unavailable", at: Date()),
                   to: conversationID)
        }
    }

    private func stopDictation() async {
        guard dictationTranscriber != nil else { return }
        if let stopDictating = takeDictationStop() { await stopDictating() }
    }

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

    enum VoiceStatus {
        case connecting, relay, direct
    }

    func voiceStatus(in conversationID: UUID) -> VoiceStatus? {
        let states = participants(in: conversationID).compactMap { links[$0] }
        guard !states.isEmpty else { return nil }
        if states.contains(.connecting) { return .connecting }
        if states.contains(.relay) { return .relay }
        return .direct
    }

    /// Reported to speakers as the same fact as a device at zero volume.
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

    private func cannotHear(in conversationID: UUID) -> Bool {
        audio.outputMuted || mutedConversations.contains(conversationID)
    }

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
        sendToPeers(.audioMuted(conversationID: conversationID, muted: muted),
                    participants(in: conversationID))
    }

    /// Best-effort socket send; failures are dropped.
    private func fire(_ frame: ClientFrame) {
        let socket = self.socket
        Task { try? await socket?.send(frame) }
    }

    /// Throttled to one event per 3s per peer.
    func sendTyping(to peerID: UUID) {
        guard let pairID = conversationID(with: peerID) else { return }
        let now = Date()
        if let last = lastTypingSentAt[peerID], now.timeIntervalSince(last) < 3 { return }
        lastTypingSentAt[peerID] = now
        sendToPeers(.typing(conversationID: pairID), [peerID])
    }

    private func noteTyping(_ userID: UUID) {
        typingPeers.insert(userID)
        typingExpiry[userID]?.cancel()
        typingExpiry[userID] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.typingPeers.remove(userID)
        }
    }

    func isTyping(_ peerID: UUID) -> Bool {
        typingPeers.contains(peerID)
    }

    func isPendingDelivery(_ messageID: UUID) -> Bool {
        unackedRecipients[messageID] != nil
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

    /// Marks signed off and hands the socket back so the caller can flush the
    /// sign-off frame off the main actor. No UI cleanup: the process is dying.
    func detachSocketForTermination() -> SocketClient? {
        guard isSignedOn else { return nil }
        machine.handle(.signOff)
        socketTask?.cancel()
        let detached = socket
        socket = nil
        return detached
    }

    func conversationOpened(_ conversationID: UUID) {
        activeConversations.insert(conversationID)
        unreadPeers.remove(conversationID)
        refreshWarmLinks()
        requestStage(in: conversationID)
    }

    /// Asked of everyone; only the owner answers, and silence means nothing.
    private func requestStage(in conversationID: UUID) {
        sendToPeers(.stageRequest(conversationID: conversationID), participants(in: conversationID))
    }

    /// Several macOS windows can report, so only the one reporting true wins.
    func conversationViewed(_ conversationID: UUID, _ viewed: Bool) {
        if viewed {
            viewedConversation = conversationID
        } else if viewedConversation == conversationID {
            viewedConversation = nil
        }
    }

    // MARK: - Stage

    /// Applied here when this user owns the stage or nobody does, otherwise
    /// forwarded to the owner with the version it targeted.
    func sendStageAction(_ action: StageAction, in conversationID: UUID) {
        guard let selfID = currentUser?.id else { return }
        let effects = StageHost.act(action, on: stages[conversationID], by: selfID, at: Date())
        // Every client's countdown fires at once, and the owner's broadcast
        // may never arrive if their link is down.
        if case .four(.expire) = action {
            stages[conversationID] = nil
        }
        perform(effects, in: conversationID)
    }

    func closeStage(in conversationID: UUID) {
        guard let selfID = currentUser?.id else { return }
        perform(StageHost.close(on: stages[conversationID], by: selfID), in: conversationID)
    }

    private func perform(_ effects: [StageHost.Effect], in conversationID: UUID) {
        for effect in effects {
            switch effect {
            case .broadcast(let stage, let actorID):
                applyStage(stage, in: conversationID, from: actorID)
                sendToPeers(.stage(conversationID: conversationID, stage: stage, actorID: actorID),
                            participants(in: conversationID))
            case .resync(let stage, let to):
                sendToPeers(.stage(conversationID: conversationID, stage: stage, actorID: nil), [to])
            case .forward(let action, let expectedVersion, let to):
                sendToPeers(.stageAction(conversationID: conversationID, action: action,
                                         expectedVersion: expectedVersion), [to])
            case .forwardClose(let to):
                sendToPeers(.stageClose(conversationID: conversationID), [to])
            }
        }
    }

    /// A stage dies with its owner, a game with either player. Only groups
    /// get a notice; a pair's sign-off notice covers it.
    private func clearStages(dependingOn userID: UUID) {
        for (conversationID, stage) in stages {
            var doomed = stage.ownerID == userID
            if case .four(let game) = stage.state, game.red == userID || game.yellow == userID {
                doomed = true
            }
            guard doomed else { continue }
            stages[conversationID] = nil
            if peer(of: conversationID) == nil, let handle = handle(of: userID) {
                append(.notice(id: UUID(), text: "\(handle) disconnected", at: Date()),
                       to: conversationID)
            }
        }
    }

    func searchYouTube(_ query: String) async throws -> [YouTubeVideo] {
        try await api.searchYouTube(query)
    }

    /// The start position resolves against the shared clock.
    func playerURL(for youtube: YouTubeState) -> URL {
        api.playerURL(videoID: youtube.videoID,
                      start: youtube.position(at: Date()),
                      playing: youtube.isPlaying)
    }

    /// Replays the socket state the server forgot with the old connection.
    private func resendAfterReconnect() {
        for conversationID in activeConversations {
            requestStage(in: conversationID)
        }
        if let viewedConversation {
            fire(.viewing(conversationID: viewedConversation))
        }
        if let ticket = peers?.ticket {
            fire(.announceEndpoint(ticket: ticket))
        }
    }

    private func applyStage(_ stage: Stage?, in conversationID: UUID, from actorID: UUID?) {
        let previous = stages[conversationID]
        stages[conversationID] = stage
        // Snapshot replies and re-syncs carry no actor: nobody did anything.
        guard let actorID, let handle = handle(of: actorID),
              let text = Self.stageNotice(from: previous, to: stage, by: handle)
        else { return }
        append(.notice(id: UUID(), text: text, at: Date()), to: conversationID)
    }

    /// The stage changes that earn a notice; the rest are plain on the stage.
    private static func stageNotice(from previous: Stage?, to stage: Stage?,
                                    by handle: String) -> String? {
        guard let stage else {
            guard let previous else { return nil }
            switch previous.state {
            case .youtube: return "\(handle) closed the video"
            case .four(let game):
                // A finished game already announced its result.
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
            switch game.outcome {
            case .won: return "\(handle) won"
            case .draw: return "Four ended in a draw"
            case nil: return nil
            }
        }
    }

    func conversationClosed(_ conversationID: UUID) {
        activeConversations.remove(conversationID)
        conversationViewed(conversationID, false)
        silenceConversation(conversationID)
        refreshWarmLinks()
    }

    var recentAwayMessages: [String] =
        UserDefaults.standard.stringArray(forKey: "recentAwayMessages") ?? []

    func setAwayMessage(_ message: String) {
        apply(machine.handle(.setAwayMessage(message)))
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
    /// Signs off on sleep: the reconnect loop would otherwise re-establish
    /// the socket on every dark wake, which the server reads as a fresh
    /// sign-on. Dark wakes don't post didWake, so only a real wake resumes.
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
            // These describe the server, not this sign-on, so they are set
            // before the session-scoped wipe below.
            self.latestBuild = latestBuild
            reconcileAvatar(remote: selfAvatar)
            self.bots = Dictionary(uniqueKeysWithValues: (bots ?? []).map { ($0.id, $0) })
            // A fresh sign-on means the server ended our previous session.
            // A reconnect within the grace window keeps the log intact.
            if freshSignOn {
                clearSessionScopedState()
            }
            peerViewing = []
            presences = Dictionary(uniqueKeysWithValues: buddies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            NotificationManager.shared.showOnlineCount(onlineBuddyCount)
            let live = Dictionary(
                uniqueKeysWithValues: sessions.filter(\.isGroup).map { ($0.session.id, $0) })
            if freshSignOn {
                groupSessions = live
            } else {
                // A known group missing from the snapshot died in the gap.
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
                endedGroups.remove(info.session.id)
            }
        case .avatarChanged(let userID, let avatar):
            applyAvatar(avatar, of: userID)
        case .presence(let userID, let presence):
            let previous = presences[userID]
            let wasOffline = (previous?.state ?? .offline) == .offline
            presences[userID] = presence
            NotificationManager.shared.showOnlineCount(onlineBuddyCount)
            if presence.state == .offline {
                peers?.removePeer(userID)
                clearStages(dependingOn: userID)
                // The server's own stamp replaces this on the next refresh.
                for index in buddies.indices where buddies[index].user.id == userID {
                    buddies[index].user.lastSeenAt = Date()
                }
            }
            let pairID = conversationID(with: userID)
            let hasConversation = pairID.map {
                !(transcripts[$0] ?? []).isEmpty || activeConversations.contains($0)
            } ?? false
            if signOnPushes, let handle = buddy(withID: userID)?.user.handle, wasOffline,
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
                    // The server's own mark; there's no message to quote.
                    append(.notice(id: UUID(), text: "\(handle) is away", at: Date()),
                           to: pairID)
                }
                // Back from away, but not by signing off, noticed above.
                if wasAway, presence.state != .away, presence.state != .offline {
                    append(.notice(id: UUID(), text: "\(handle) is back", at: Date()),
                           to: pairID)
                }
            }
            // Presence for a non-buddy means the list changed server-side.
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
                // A 1:1 stage dies with the conversation, whoever owned it.
                if let pairID {
                    stages[pairID] = nil
                    peerViewing.remove(pairID)
                }
            }
        case .botMessage(let conversationID, let message):
            append(.message(message), to: conversationID)
            if !activeConversations.contains(conversationID) {
                unreadPeers.insert(conversationID)
            }
            SoundPlayer.play(.messageReceived)
        case .viewing(let conversationID, _, let viewing):
            if viewing {
                peerViewing.insert(conversationID)
            } else {
                peerViewing.remove(conversationID)
            }
        case .endpoint(let userID, let ticket):
            peers?.setPeer(userID, ticket: ticket)
        case .sessionClosed(let sessionID):
            // Only the live ephemera stop; the transcript and roster stay.
            if groupSessions[sessionID] != nil {
                endedGroups.insert(sessionID)
            }
            if let peerID = peer(of: sessionID) {
                clearTyping(peerID)
            }
            reportedActive.remove(sessionID)
            stages[sessionID] = nil
            silenceConversation(sessionID)
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .error(let message):
            Log.model.error("server error: \(message)")
            if let conversationID = lastSentConversation {
                append(.notice(id: UUID(), text: message, at: Date()), to: conversationID)
            }
        }
    }

    // MARK: - Peer frames

    /// The link vouches for who sent a frame; the conversation it names
    /// counts only if that sender is in it.
    private func handle(_ inbound: PeerLink.Inbound) {
        let senderID = inbound.senderID
        guard let selfID = currentUser?.id else { return }
        switch inbound.frame {
        case .message(var message):
            guard canReceive(from: senderID, in: message.sessionID) else { return }
            message.senderID = senderID
            receiveMessage(message)
            sendToPeers(.ack(messageID: message.id), [senderID])
        case .ack(let messageID):
            markAcked(messageID, by: senderID)
        case .typing(let conversationID):
            guard peer(of: conversationID) == senderID else { return }
            noteTyping(senderID)
        case .audioMuted(let conversationID, let muted):
            guard canReceive(from: senderID, in: conversationID) else { return }
            setMutedListener(senderID, muted: muted, in: conversationID)
        case .stageAction(let conversationID, let action, let expectedVersion):
            guard canReceive(from: senderID, in: conversationID) else { return }
            perform(StageHost.receive(action, expectedVersion: expectedVersion, from: senderID,
                                      on: stages[conversationID], selfID: selfID, at: Date()),
                    in: conversationID)
        case .stageClose(let conversationID):
            guard canReceive(from: senderID, in: conversationID) else { return }
            perform(StageHost.receiveClose(from: senderID, on: stages[conversationID], selfID: selfID),
                    in: conversationID)
        case .stageRequest(let conversationID):
            guard canReceive(from: senderID, in: conversationID) else { return }
            perform(StageHost.receiveRequest(from: senderID, on: stages[conversationID], selfID: selfID),
                    in: conversationID)
        case .stage(let conversationID, let stage, let actorID):
            guard canReceive(from: senderID, in: conversationID),
                  StageHost.accepts(stage, from: senderID, on: stages[conversationID], selfID: selfID)
            else { return }
            applyStage(stage, in: conversationID, from: actorID)
        }
    }

    private func receiveMessage(_ message: ChatMessage) {
        append(.message(message), to: message.sessionID)
        clearTyping(message.senderID)
        if !activeConversations.contains(message.sessionID) {
            unreadPeers.insert(message.sessionID)
        }
        SoundPlayer.play(.messageReceived)
        noteTraffic(in: message.sessionID)
    }

    private func setMutedListener(_ userID: UUID, muted: Bool, in conversationID: UUID) {
        guard activeConversations.contains(conversationID) else { return }
        if muted {
            mutedListeners[conversationID, default: []].insert(userID)
        } else {
            mutedListeners[conversationID]?.remove(userID)
        }
    }

    /// The link vouches for the sender, not the conversation they named.
    private func receiveAudio(conversationID: UUID, senderID: UUID, packet: Data) {
        guard activeConversations.contains(conversationID),
              senderID == currentUser?.id || participants(in: conversationID).contains(senderID)
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
        // A silent chat just became audible: tell speakers we can't hear.
        if (speakingUsers[conversationID] ?? []).isEmpty {
            reportMutedIfNeeded(in: conversationID)
        }
        markSpeaking(senderID, in: conversationID, spectrum: spectrum)
    }

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
