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

    private var api = APIClient()
    private var socket: SocketClient?
    private var socketTask: Task<Void, Never>?

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
        try await refreshBuddies()
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
        case .message:
            // Chat UI is build-sequence step 4 (spec §9); presence dogfood comes first.
            SoundPlayer.play(.messageReceived)
        case .buddyRequest:
            Task { try? await refreshBuddies() }
        case .messageSent, .typing, .sessionClosed:
            break
        case .error(let message):
            print("server error: \(message)")
        }
    }
}
