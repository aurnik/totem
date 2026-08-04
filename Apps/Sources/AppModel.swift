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

        var date: Date {
            switch self {
            case .message(let message): message.sentAt
            case .notice(_, _, let at): at
            }
        }
    }

    /// Transcripts keyed by conversation ID — the peer's user ID for 1:1
    /// chats, the session ID for group chats. Scoped to the local user's own
    /// online session: one continuous log while signed on, no matter how
    /// often peers come and go; cleared when this user's session ends
    /// (deliberate sign-off, or a `freshSignOn` welcome after the server
    /// marked them offline). Never persisted — messages live only in the RAM
    /// of currently-online participants.
    var transcripts: [UUID: [TranscriptItem]] = [:]
    /// Open group sessions by session ID.
    var groupSessions: [UUID: SessionInfo] = [:]
    /// Peers with messages not yet seen. Local-only — never sent over the
    /// wire; the spec's no-read-receipts rule is about the other party.
    var unreadPeers: Set<UUID> = []
    private var activeConversations: Set<UUID> = []
    /// Peers currently typing. Plain observable state (expired by tasks, not
    /// polled) so views update reliably — offscreen TimelineViews pause on iOS.
    private var typingPeers: Set<UUID> = []
    private var typingExpiry: [UUID: Task<Void, Never>] = [:]
    /// The most recently appended transcript item, stamped with the local
    /// clock — drives entrance animations without trusting server timestamps.
    private var lastAppended: (id: UUID, at: Date)?
    private var pendingSends: [UUID: UUID] = [:]
    private var sessionPeers: [UUID: UUID] = [:]
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
    /// Conversations we've told peers *we* can't hear — cleared when the
    /// volume comes back (with a follow-up frame) or the chat goes silent.
    private var reportedMutedConversations: Set<UUID> = []
    /// Per-chunk spectrum frames for the speaker meters, keyed by speaking user.
    var speakerSpectrum: [UUID: [Float]] = [:]
    /// Conversations already told (via notice) that playback is broken —
    /// throttles the notice to once per sign-on.
    private var playbackFailureNoticed: Set<UUID> = []
    private var speakingExpiry: [UUID: Task<Void, Never>] = [:]
    private var micSendTask: Task<Void, Never>?
    private var micChunks: AsyncStream<Data>.Continuation?
    private let audio = AudioStreamer()

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?
    /// A newer ad-hoc build is published on the server (iOS, distributed
    /// builds only — dev builds have build number "1" and never check).
    var updateAvailable = false
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

    /// Live value behind the settings sliders — views mutate it freely while
    /// dragging; `commitAvatar()` persists and uploads on release.
    var avatar: Avatar = {
        guard let data = UserDefaults.standard.data(forKey: "avatar"),
              let avatar = try? JSONDecoder().decode(Avatar.self, from: data)
        else { return Avatar() }
        return avatar
    }()

    /// Set while an edit hasn't reached the server. Survives relaunch so a
    /// change made offline still wins the next reconciliation instead of
    /// being silently overwritten by the server's older copy.
    private var avatarNeedsUpload = UserDefaults.standard.bool(forKey: "avatarNeedsUpload")

    /// Persist locally and push to the server, which embeds it in this
    /// user's DTO — and fans it out to everyone currently rendering us.
    func commitAvatar() {
        storeAvatarLocally(avatar)
        setAvatarNeedsUpload(true)
        let (api, committed) = (self.api, self.avatar)
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
    /// copy. An account with no avatar gets this device's — installs signed
    /// in before avatars existed never pass through `signIn` again. Otherwise
    /// the account's copy wins, so a second device can't overwrite it with a
    /// stale local one, unless this device is still holding an edit the
    /// server never received.
    private func reconcileAvatar(remote: Avatar?) {
        guard !avatarNeedsUpload else {
            commitAvatar()
            return
        }
        guard let remote else {
            commitAvatar()
            return
        }
        guard remote != avatar else { return }
        avatar = remote
        storeAvatarLocally(remote)
    }

    private func storeAvatarLocally(_ avatar: Avatar) {
        UserDefaults.standard.set(try? JSONEncoder().encode(avatar), forKey: "avatar")
        currentUser?.avatar = avatar
        UserDefaults.standard.set(
            try? WireCoder.encoder().encode(currentUser), forKey: "currentUser")
    }

    private func setAvatarNeedsUpload(_ pending: Bool) {
        avatarNeedsUpload = pending
        UserDefaults.standard.set(pending, forKey: "avatarNeedsUpload")
    }

    init() {
        NotificationManager.shared.activate()
        audio.onOutputVolumeChange = { [weak self] in self?.outputVolumeChanged() }
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
        presences = [:]
        transcripts = [:]
        groupSessions = [:]
        unreadPeers = []
        UserDefaults.standard.removeObject(forKey: "authToken")
        UserDefaults.standard.removeObject(forKey: "currentUser")
    }

    func refreshBuddies() async throws {
        buddies = try await api.buddies()
        // Contextual, never at launch (spec §7): ask only once buddies exist.
        if !buddies.isEmpty {
            NotificationManager.shared.requestPermissionIfNeeded()
        }
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
        apply(machine.handle(.signOn(at: Date())))
        refreshPushSettings()
        let socket = SocketClient(url: api.socketURL, token: token)
        self.socket = socket
        socketTask = Task { [weak self] in
            for await event in await socket.events() {
                await self?.handle(event)
            }
        }
    }

    func signOff() {
        apply(machine.handle(.signOff(at: Date())))
        socketTask?.cancel()
        let socket = self.socket
        Task { await socket?.close() }
        self.socket = nil
        presences = [:]
        // Sign-off closes all conversation windows (spec §3); views observe
        // isSignedOn and dismiss themselves.
        // Session-scoped ephemerality: transcripts do not outlive the local
        // user's own online session.
        transcripts = [:]
        sessionPeers = [:]
        pendingSends = [:]
        unreadPeers = []
        typingPeers = []
        typingExpiry.values.forEach { $0.cancel() }
        typingExpiry = [:]
        stopMic()
        audio.stopAll()
        speakingUsers = [:]
        mutedListeners = [:]
        reportedMutedConversations = []
        speakerSpectrum = [:]
        playbackFailureNoticed = []
        speakingExpiry.values.forEach { $0.cancel() }
        speakingExpiry = [:]
    }

    // MARK: - Chat

    func buddy(withID id: UUID) -> Buddy? {
        acceptedBuddies.first { $0.user.id == id }
    }

    func sendMessage(to conversationID: UUID, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let clientID = UUID()
        pendingSends[clientID] = conversationID
        lastSentConversation = conversationID
        let frame: ClientFrame = groupSessions[conversationID] != nil
            ? .sendSessionMessage(sessionID: conversationID, body: trimmed, clientMessageID: clientID)
            : .sendMessage(recipientID: conversationID, body: trimmed, clientMessageID: clientID)
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

    /// One participant opens the existing 1:1 conversation; more creates a
    /// group session server-side. Returns the conversation ID to open.
    func startChat(with participantIDs: [UUID]) async throws -> UUID {
        if participantIDs.count == 1 { return participantIDs[0] }
        let info = try await api.createSession(participantIDs: participantIDs)
        groupSessions[info.session.id] = info
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
        return buddy(withID: conversationID)?.user.handle ?? "chat"
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
    /// wire-format PCM in Application Support; only the labels are listed
    /// here (persisted in UserDefaults).
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
    private var sampleRecordingData = Data()

    private var samplesDir: URL {
        URL.applicationSupportDirectory.appendingPathComponent("SoundSamples", isDirectory: true)
    }

    private func sampleURL(_ id: UUID) -> URL {
        samplesDir.appendingPathComponent("\(id).pcm")
    }

    func startSampleRecording() async -> Bool {
        stopMic()
        sampleRecordingData = Data()
        sampleRecordingSeconds = 0
        let started = await audio.startMic { [weak self] chunk in
            Task { @MainActor in self?.appendSampleChunk(chunk) }
        }
        isRecordingSample = started
        return started
    }

    private func appendSampleChunk(_ chunk: Data) {
        guard isRecordingSample else { return }
        sampleRecordingData.append(chunk)
        let maxBytes = Int(Self.sampleMaxSeconds * AudioWire.sampleRate) * 2
        if sampleRecordingData.count >= maxBytes {
            sampleRecordingData = sampleRecordingData.prefix(maxBytes)
            stopSampleRecording()
        }
        sampleRecordingSeconds = Double(sampleRecordingData.count) / (AudioWire.sampleRate * 2)
    }

    func stopSampleRecording() {
        guard isRecordingSample else { return }
        isRecordingSample = false
        audio.stopMic()
    }

    func saveRecordedSample(label: String) {
        stopSampleRecording()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sampleRecordingData.isEmpty,
              soundSamples.count < Self.maxSoundSamples
        else { return }
        let sample = SoundSample(id: UUID(), label: String(trimmed.prefix(30)))
        do {
            try FileManager.default.createDirectory(
                at: samplesDir, withIntermediateDirectories: true)
            try sampleRecordingData.write(to: sampleURL(sample.id))
        } catch {
            print("sample save failed: \(error)")
            return
        }
        soundSamples.append(sample)
        persistSamples()
        sampleRecordingData = Data()
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

    /// Broadcasts a sample into the chat over the live-audio relay, paced in
    /// real time like mic chunks so recipients' meters and speaker expiry
    /// behave normally — and looped back locally so the sender hears it too.
    func playSample(_ sample: SoundSample, in conversationID: UUID) {
        guard let data = try? Data(contentsOf: sampleURL(sample.id)), !data.isEmpty
        else { return }
        let isGroup = groupSessions[conversationID] != nil
        let socket = self.socket
        let selfID = currentUser?.id
        // 100ms of wire PCM per chunk, matching the mic cadence.
        let step = Int(AudioWire.sampleRate * 2) / 10
        Task { [weak self] in
            var offset = 0
            while offset < data.count {
                let chunk = data.subdata(in: offset..<min(offset + step, data.count))
                let frame: ClientFrame = isGroup
                    ? .sendSessionAudio(sessionID: conversationID, chunk: chunk)
                    : .sendAudio(recipientID: conversationID, chunk: chunk)
                try? await socket?.send(frame)
                if let self, let selfID {
                    self.receiveAudio(conversationID: conversationID, senderID: selfID, chunk: chunk)
                }
                offset += step
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    // MARK: - Live voice

    func toggleMic(in conversationID: UUID) {
        if liveMicConversation == conversationID {
            stopMic()
        } else {
            startMic(in: conversationID)
        }
    }

    private func startMic(in conversationID: UUID) {
        stopMic()
        guard let socket else { return }
        let isGroup = groupSessions[conversationID] != nil
        // Chunks flow through one stream consumed by one task so sends stay
        // ordered — racing per-chunk Tasks would garble the audio.
        let (stream, continuation) = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingNewest(8))
        Task {
            guard await audio.startMic(onChunk: { continuation.yield($0) }) else {
                continuation.finish()
                return
            }
            liveMicConversation = conversationID
            micChunks = continuation
            micSendTask = Task { [weak self] in
                for await chunk in stream {
                    let frame: ClientFrame = isGroup
                        ? .sendSessionAudio(sessionID: conversationID, chunk: chunk)
                        : .sendAudio(recipientID: conversationID, chunk: chunk)
                    try? await socket.send(frame)
                    // Meter-only self monitor (no playback — that would echo)
                    // so the speaker can see their own audio going out.
                    if let self, let selfID = self.currentUser?.id {
                        self.markSpeaking(selfID, in: conversationID, chunk: chunk)
                    }
                }
            }
        }
    }

    func stopMic() {
        audio.stopMic()
        liveMicConversation = nil
        micChunks?.finish()
        micChunks = nil
        micSendTask?.cancel()
        micSendTask = nil
    }

    private func silenceConversation(_ conversationID: UUID) {
        mutedListeners[conversationID] = nil
        reportedMutedConversations.remove(conversationID)
        for senderID in speakingUsers.removeValue(forKey: conversationID) ?? [] {
            audio.stopSpeaker(senderID)
            speakingExpiry[senderID]?.cancel()
            speakingExpiry[senderID] = nil
            speakerSpectrum[senderID] = nil
        }
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
                sendAudioMuted(false, in: conversationID)
            }
            reportedMutedConversations = []
        }
    }

    private func reportMutedIfNeeded(in conversationID: UUID) {
        guard audio.outputMuted, !reportedMutedConversations.contains(conversationID)
        else { return }
        reportedMutedConversations.insert(conversationID)
        sendAudioMuted(true, in: conversationID)
    }

    private func sendAudioMuted(_ muted: Bool, in conversationID: UUID) {
        let frame: ClientFrame = groupSessions[conversationID] != nil
            ? .setSessionAudioMuted(sessionID: conversationID, muted: muted)
            : .setAudioMuted(recipientID: conversationID, muted: muted)
        let socket = self.socket
        Task { try? await socket?.send(frame) }
    }

    /// Throttled to one event per 3s per peer (spec §6).
    func sendTyping(to peerID: UUID) {
        let now = Date()
        if let last = lastTypingSentAt[peerID], now.timeIntervalSince(last) < 3 { return }
        lastTypingSentAt[peerID] = now
        let socket = self.socket
        Task { try? await socket?.send(.typing(recipientID: peerID)) }
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
        machine.handle(.signOff(at: Date()))
        socketTask?.cancel()
        let detached = socket
        socket = nil
        return detached
    }

    func conversationOpened(_ peerID: UUID) {
        activeConversations.insert(peerID)
        unreadPeers.remove(peerID)
    }

    func conversationClosed(_ peerID: UUID) {
        activeConversations.remove(peerID)
        // Voice is scoped to having the chat open, both directions.
        if liveMicConversation == peerID { stopMic() }
        silenceConversation(peerID)
    }

    /// Most recent distinct away messages, newest first — the quick-tap
    /// options in the away sheet.
    var recentAwayMessages: [String] =
        UserDefaults.standard.stringArray(forKey: "recentAwayMessages") ?? []

    func setAwayMessage(_ message: String) {
        apply(machine.handle(.setAwayMessage(message, at: Date())))
        // Record what the machine actually kept (trimmed, truncated).
        guard let saved = machine.awayMessage else { return }
        recentAwayMessages.removeAll { $0 == saved }
        recentAwayMessages.insert(saved, at: 0)
        recentAwayMessages = Array(recentAwayMessages.prefix(3))
        UserDefaults.standard.set(recentAwayMessages, forKey: "recentAwayMessages")
    }

    func clearAwayMessage() {
        apply(machine.handle(.clearAwayMessage(at: Date())))
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background: apply(machine.handle(.appBackgrounded(at: Date())))
        case .active:
            apply(machine.handle(.appForegrounded(at: Date())))
            checkForUpdate()
        default: break
        }
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

    // MARK: - Updates (ad-hoc distribution)

    private func checkForUpdate() {
        #if os(iOS)
        // TestFlight installs (sandbox receipt) update through TestFlight,
        // not the ad-hoc itms-services flow.
        guard Bundle.main.appStoreReceiptURL?.lastPathComponent != "sandboxReceipt",
              !updateAvailable,
              let local = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                .flatMap(Int.init),
              local > 1
        else { return }
        Task {
            if let latest = try? await api.latestBuild(), latest > local {
                updateAvailable = true
            }
        }
        #endif
    }

    /// Opens the itms-services manifest — iOS installs the new build over
    /// this one in place, data preserved.
    func openUpdate() {
        #if os(iOS)
        UIApplication.shared.open(api.updateManifestURL)
        #endif
    }

    private func apply(_ effects: [PresenceStateMachine.Effect]) {
        for effect in effects {
            switch effect {
            case .sendPresence(let state, let awayMessage):
                let socket = self.socket
                Task { try? await socket?.send(.setPresence(state: state, awayMessage: awayMessage)) }
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
            apply(machine.handle(.reconnected(at: Date())))
        case .disconnected:
            apply(machine.handle(.connectionLost(at: Date())))
        case .frame(let frame):
            handle(frame)
        }
    }

    private func handle(_ frame: ServerFrame) {
        switch frame {
        case .welcome(_, let buddies, let sessions, let freshSignOn, let selfAvatar):
            reconcileAvatar(remote: selfAvatar)
            // A fresh sign-on means the server ended our previous online
            // session (suspension sweep, >90s drop, sign-off) — everything
            // conversation-scoped from before it is gone. A reconnect within
            // the grace window keeps the log intact.
            if freshSignOn {
                transcripts = [:]
                sessionPeers = [:]
                pendingSends = [:]
                unreadPeers = []
                mutedListeners = [:]
                reportedMutedConversations = []
            }
            presences = Dictionary(uniqueKeysWithValues: buddies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            groupSessions = Dictionary(
                uniqueKeysWithValues: sessions.filter(\.isGroup).map { ($0.session.id, $0) })
        case .sessionStarted(let info):
            if info.isGroup {
                groupSessions[info.session.id] = info
            }
        case .avatarChanged(let userID, let avatar):
            applyAvatar(avatar, of: userID)
        case .presence(let userID, let presence):
            let previous = presences[userID]
            let wasOffline = (previous?.state ?? .offline) == .offline
            presences[userID] = presence
            let hasConversation = !(transcripts[userID] ?? []).isEmpty
                || activeConversations.contains(userID)
            if let handle = buddy(withID: userID)?.user.handle, wasOffline,
               presence.state != .offline {
                NotificationManager.shared.buddySignedOn(userID, handle: handle)
            }
            if let handle = buddy(withID: userID)?.user.handle, hasConversation {
                let nowOffline = presence.state == .offline
                if wasOffline != nowOffline {
                    append(.notice(id: UUID(), text: "\(handle) signed \(nowOffline ? "off" : "on")", at: Date()),
                           to: userID)
                }
                if let away = presence.awayMessage, away != previous?.awayMessage {
                    append(.notice(id: UUID(), text: "\(handle) is away: \"\(away)\"", at: Date()),
                           to: userID)
                }
                // Coming back from away — but not by signing off, which
                // already got its own notice above.
                if previous?.awayMessage != nil, presence.awayMessage == nil,
                   presence.state != .offline {
                    append(.notice(id: UUID(), text: "\(handle) is back", at: Date()),
                           to: userID)
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
            }
        case .message(let message):
            let key = groupSessions[message.sessionID] != nil ? message.sessionID : message.senderID
            if key == message.senderID {
                sessionPeers[message.sessionID] = key
            }
            append(.message(message), to: key)
            clearTyping(message.senderID)
            if !activeConversations.contains(key) {
                unreadPeers.insert(key)
            }
            SoundPlayer.play(.messageReceived)
        case .messageSent(let clientMessageID, let message):
            if let key = pendingSends.removeValue(forKey: clientMessageID) {
                if groupSessions[message.sessionID] == nil {
                    sessionPeers[message.sessionID] = key
                }
                append(.message(message), to: key)
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
        case .audio(let conversationID, let senderID, let chunk):
            receiveAudio(conversationID: conversationID, senderID: senderID, chunk: chunk)
        case .audioMuted(let conversationID, let userID, let muted):
            guard activeConversations.contains(conversationID) else { return }
            if muted {
                mutedListeners[conversationID, default: []].insert(userID)
            } else {
                mutedListeners[conversationID]?.remove(userID)
            }
        case .sessionClosed(let sessionID):
            // The peer went offline and the server archived the 1:1 session.
            // Our own transcript survives — it's scoped to our online session,
            // not the server's — and the next message simply starts a new
            // server session under the same conversation key. Only the live
            // ephemera stop.
            if let peerID = sessionPeers.removeValue(forKey: sessionID) {
                clearTyping(peerID)
                if liveMicConversation == peerID { stopMic() }
                silenceConversation(peerID)
            }
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .error(let message):
            print("server error: \(message)")
            if let conversationID = lastSentConversation {
                append(.notice(id: UUID(), text: message, at: Date()), to: conversationID)
            }
        }
    }

    /// One live-audio chunk reaching the ears and meters — from the wire, or
    /// looped back locally while broadcasting a sound sample.
    private func receiveAudio(conversationID: UUID, senderID: UUID, chunk: Data) {
        // Live voice only reaches ears with that chat open.
        guard activeConversations.contains(conversationID) else { return }
        if let failure = audio.play(chunk, from: senderID),
           !playbackFailureNoticed.contains(conversationID) {
            playbackFailureNoticed.insert(conversationID)
            append(.notice(id: UUID(), text: "Can't play live audio — \(failure)", at: Date()),
                   to: conversationID)
        }
        // A silent chat just became audible — if our volume is at zero,
        // that's the moment the speaker needs to know we can't hear.
        if (speakingUsers[conversationID] ?? []).isEmpty {
            reportMutedIfNeeded(in: conversationID)
        }
        markSpeaking(senderID, in: conversationID, chunk: chunk)
    }

    /// Lights up the speaker meters for one chunk — remote audio, the local
    /// mic monitor, or a sample loopback — and schedules the quiet-expiry.
    private func markSpeaking(_ senderID: UUID, in conversationID: UUID, chunk: Data) {
        speakingUsers[conversationID, default: []].insert(senderID)
        speakerSpectrum[senderID] = AudioAnalyzer.spectrum(of: chunk)
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
