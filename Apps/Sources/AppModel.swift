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

    /// Transcripts keyed by peer user ID, session-scoped: cleared when a new
    /// session starts after the old one was archived.
    var messages: [UUID: [ChatMessage]] = [:]
    /// Peers whose session ended (either side signed off) — transcript is
    /// showing archived state until the next message starts a fresh session.
    var endedConversations: Set<UUID> = []
    /// Peers with messages not yet seen. Local-only — never sent over the
    /// wire; the spec's no-read-receipts rule is about the other party.
    var unreadPeers: Set<UUID> = []
    private var activeConversations: Set<UUID> = []
    private var typingUntil: [UUID: Date] = [:]
    private var pendingSends: [UUID: UUID] = [:]
    private var sessionPeers: [UUID: UUID] = [:]
    private var lastTypingSentAt: [UUID: Date] = [:]

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "serverURL"),
           let url = URL(string: saved) {
            api.baseURL = url
        }
        if let token = UserDefaults.standard.string(forKey: "authToken"),
           let data = UserDefaults.standard.data(forKey: "currentUser"),
           let user = try? WireCoder.decoder().decode(User.self, from: data) {
            api.token = token
            currentUser = user
            Task {
                do {
                    try await refreshBuddies()
                    // Launching into the buddy list signs on automatically; the
                    // explicit Sign On button only appears after a manual sign-off.
                    signOn()
                } catch URLError.userAuthenticationRequired {
                    logOut()
                } catch {
                    // Offline or server down; keep the session and let sign-on retry.
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
        messages = [:]
        endedConversations = []
        unreadPeers = []
        UserDefaults.standard.removeObject(forKey: "authToken")
        UserDefaults.standard.removeObject(forKey: "currentUser")
    }

    func refreshBuddies() async throws {
        buddies = try await api.buddies()
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
        endedConversations.formUnion(messages.keys)
        typingUntil = [:]
    }

    // MARK: - Chat

    func buddy(withID id: UUID) -> Buddy? {
        acceptedBuddies.first { $0.user.id == id }
    }

    func sendMessage(to peerID: UUID, body: String) {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        startFreshSessionIfEnded(with: peerID)
        let clientID = UUID()
        pendingSends[clientID] = peerID
        let socket = self.socket
        Task { try? await socket?.send(.sendMessage(recipientID: peerID, body: trimmed, clientMessageID: clientID)) }
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
        (typingUntil[peerID] ?? .distantPast) > Date()
    }

    private func startFreshSessionIfEnded(with peerID: UUID) {
        if endedConversations.remove(peerID) != nil {
            messages[peerID] = []
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
        case .welcome(_, let buddies):
            presences = Dictionary(uniqueKeysWithValues: buddies.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        case .presence(let userID, let presence):
            let wasOffline = (presences[userID]?.state ?? .offline) == .offline
            presences[userID] = presence
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
            let peerID = message.senderID
            sessionPeers[message.sessionID] = peerID
            startFreshSessionIfEnded(with: peerID)
            messages[peerID, default: []].append(message)
            typingUntil[peerID] = nil
            if !activeConversations.contains(peerID) {
                unreadPeers.insert(peerID)
            }
            SoundPlayer.play(.messageReceived)
        case .messageSent(let clientMessageID, let message):
            if let peerID = pendingSends.removeValue(forKey: clientMessageID) {
                sessionPeers[message.sessionID] = peerID
                messages[peerID, default: []].append(message)
                SoundPlayer.play(.messageSent)
            }
        case .typing(let userID):
            typingUntil[userID] = Date().addingTimeInterval(5)
        case .sessionClosed(let sessionID):
            if let peerID = sessionPeers.removeValue(forKey: sessionID) {
                endedConversations.insert(peerID)
                typingUntil[peerID] = nil
            }
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .error(let message):
            print("server error: \(message)")
        }
    }
}
