import Foundation
import Observation
import SwiftUI
import TotemKit

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
    /// chats, the session ID for group chats. Session-scoped: cleared when a
    /// new session starts after the old one was archived.
    var transcripts: [UUID: [TranscriptItem]] = [:]
    /// Open group sessions by session ID.
    var groupSessions: [UUID: SessionInfo] = [:]
    /// Peers whose session ended (either side signed off) — transcript is
    /// showing archived state until the next message starts a fresh session.
    var endedConversations: Set<UUID> = []
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
    private var lastTypingSentAt: [UUID: Date] = [:]
    /// Live voice: the conversation the local mic streams into (one at a
    /// time) and who we currently hear, per conversation. Speakers are
    /// inferred from chunk arrival and expire after a beat of silence —
    /// no explicit mic-state frames on the wire.
    var liveMicConversation: UUID?
    var speakingUsers: [UUID: Set<UUID>] = [:]
    /// Per-chunk spectrum frames for the meters: own mic, and incoming audio
    /// keyed by speaking user.
    var micSpectrum: [Float]?
    var speakerSpectrum: [UUID: [Float]] = [:]
    private var speakingExpiry: [UUID: Task<Void, Never>] = [:]
    private var micSendTask: Task<Void, Never>?
    private var micChunks: AsyncStream<Data>.Continuation?
    private let audio = AudioStreamer()

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?

    init() {
        NotificationManager.shared.activate()
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
        endedConversations = []
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

    func acceptRequest(_ buddy: Buddy) async throws {
        try await api.acceptBuddyRequest(id: buddy.id)
        try await refreshBuddies()
    }

    // MARK: - Presence

    func signOn() {
        guard let token = api.token, !isSignedOn else { return }
        apply(machine.handle(.signOn(at: Date())))
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
        // Session-scoped ephemerality: signing off ends every session, and
        // transcripts do not outlive their session.
        endedConversations.formUnion(transcripts.keys)
        transcripts = transcripts.mapValues { _ in [] }
        unreadPeers = []
        typingPeers = []
        typingExpiry.values.forEach { $0.cancel() }
        typingExpiry = [:]
        stopMic()
        audio.stopAll()
        speakingUsers = [:]
        speakerSpectrum = [:]
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
        startFreshSessionIfEnded(with: conversationID)
        let clientID = UUID()
        pendingSends[clientID] = conversationID
        let socket = self.socket
        if groupSessions[conversationID] != nil {
            Task { try? await socket?.send(.sendSessionMessage(sessionID: conversationID, body: trimmed, clientMessageID: clientID)) }
        } else {
            Task { try? await socket?.send(.sendMessage(recipientID: conversationID, body: trimmed, clientMessageID: clientID)) }
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
        if let buddy = buddy(withID: userID) { return buddy.user.handle }
        for info in groupSessions.values {
            if let user = info.participants.first(where: { $0.id == userID }) {
                return user.handle
            }
        }
        return nil
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
            micSendTask = Task {
                for await chunk in stream {
                    micSpectrum = AudioAnalyzer.spectrum(of: chunk)
                    let frame: ClientFrame = isGroup
                        ? .sendSessionAudio(sessionID: conversationID, chunk: chunk)
                        : .sendAudio(recipientID: conversationID, chunk: chunk)
                    try? await socket.send(frame)
                }
            }
        }
    }

    func stopMic() {
        audio.stopMic()
        liveMicConversation = nil
        micSpectrum = nil
        micChunks?.finish()
        micChunks = nil
        micSendTask?.cancel()
        micSendTask = nil
    }

    private func silenceConversation(_ conversationID: UUID) {
        for senderID in speakingUsers.removeValue(forKey: conversationID) ?? [] {
            audio.stopSpeaker(senderID)
            speakingExpiry[senderID]?.cancel()
            speakingExpiry[senderID] = nil
            speakerSpectrum[senderID] = nil
        }
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

    private func startFreshSessionIfEnded(with peerID: UUID) {
        if endedConversations.remove(peerID) != nil {
            transcripts[peerID] = []
        }
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

    func setAwayMessage(_ message: String) {
        apply(machine.handle(.setAwayMessage(message, at: Date())))
    }

    func clearAwayMessage() {
        apply(machine.handle(.clearAwayMessage(at: Date())))
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        switch phase {
        case .background: apply(machine.handle(.appBackgrounded(at: Date())))
        case .active: apply(machine.handle(.appForegrounded(at: Date())))
        default: break
        }
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
        case .welcome(_, let buddies, let sessions):
            presences = Dictionary(uniqueKeysWithValues: buddies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
            groupSessions = Dictionary(
                uniqueKeysWithValues: sessions.filter(\.isGroup).map { ($0.session.id, $0) })
        case .sessionStarted(let info):
            if info.isGroup {
                groupSessions[info.session.id] = info
            }
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
        case .message(let message):
            let key = groupSessions[message.sessionID] != nil ? message.sessionID : message.senderID
            if key == message.senderID {
                sessionPeers[message.sessionID] = key
            }
            startFreshSessionIfEnded(with: key)
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
            // Live voice only reaches ears with that chat open.
            guard activeConversations.contains(conversationID) else { return }
            audio.play(chunk, from: senderID)
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
        case .sessionClosed(let sessionID):
            // Transcripts live only until the session ends — no history.
            if groupSessions[sessionID] != nil {
                endedConversations.insert(sessionID)
                transcripts[sessionID] = []
                if liveMicConversation == sessionID { stopMic() }
                silenceConversation(sessionID)
            } else if let peerID = sessionPeers.removeValue(forKey: sessionID) {
                endedConversations.insert(peerID)
                transcripts[peerID] = []
                clearTyping(peerID)
                if liveMicConversation == peerID { stopMic() }
                silenceConversation(peerID)
            }
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .error(let message):
            print("server error: \(message)")
        }
    }
}
