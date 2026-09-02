import Foundation
import TotemKit
import Vapor

/// One live socket per user. With the 100-buddy cap, fan-out is a direct loop
/// over connected buddies — no pub/sub topology in v1 (spec §4).
actor ConnectionManager {
    private var sockets: [UUID: WebSocket] = [:]
    /// Bumped on every register; lets the 90s offline-grace task tell whether
    /// the user reconnected while it slept.
    private var generations: [UUID: Int] = [:]
    private var lastActivity: [UUID: Date] = [:]
    private var lastPong: [UUID: Date] = [:]
    /// The 1:1 conversation each connection reports having on screen. State
    /// of the socket, not the user: it's cleared wherever a socket is dropped
    /// or replaced, and a fresh socket has nothing on screen until it says so.
    private var viewing: [UUID: Viewing] = [:]

    struct Viewing: Equatable {
        let conversationID: UUID
        let peerID: UUID
    }
    /// Each connection's live-voice endpoint ticket, socket state the same
    /// way: a fresh socket has none until it announces one.
    private var endpoints: [UUID: String] = [:]

    func register(_ ws: WebSocket, for userID: UUID) async -> Int {
        if let old = sockets[userID] {
            try? await old.close(code: .policyViolation)
        }
        sockets[userID] = ws
        endpoints[userID] = nil
        let generation = (generations[userID] ?? 0) + 1
        generations[userID] = generation
        return generation
    }

    /// True when this socket was the live one and is now gone; false when a
    /// newer socket had already replaced it.
    func unregister(_ userID: UUID, ifStill ws: WebSocket) -> Bool {
        guard sockets[userID] === ws else { return false }
        sockets[userID] = nil
        endpoints[userID] = nil
        return true
    }

    func setEndpoint(_ ticket: String, for userID: UUID) {
        endpoints[userID] = ticket
    }

    func endpoint(of userID: UUID) -> String? {
        endpoints[userID]
    }

    /// Returns what they were viewing before, so the caller can tell that peer.
    func setViewing(_ target: Viewing?, for userID: UUID) -> Viewing? {
        let previous = viewing[userID]
        viewing[userID] = target
        return previous
    }

    /// Everyone currently looking at a conversation with this user.
    func viewers(of userID: UUID) -> [(viewerID: UUID, conversationID: UUID)] {
        viewing.compactMap { viewerID, target in
            target.peerID == userID ? (viewerID, target.conversationID) : nil
        }
    }

    func isConnected(_ userID: UUID) -> Bool {
        sockets[userID] != nil
    }

    func generation(of userID: UUID) -> Int {
        generations[userID] ?? 0
    }

    func connectedUserIDs() -> [UUID] {
        Array(sockets.keys)
    }

    func noteActivity(_ userID: UUID) {
        lastActivity[userID] = Date()
    }

    func notePong(_ userID: UUID) {
        lastPong[userID] = Date()
        lastActivity[userID] = Date()
    }

    /// A registered socket isn't proof of a live app: a suspended or killed
    /// iOS app leaves the connection open and silent. A protocol ping needs
    /// the client's runtime to answer, so no pong within the timeout means
    /// dead. Recent inbound traffic short-circuits the round trip.
    func verifyAlive(_ userID: UUID, timeout: TimeInterval = 3) async -> Bool {
        guard let ws = sockets[userID] else { return false }
        if let recent = lastActivity[userID], Date().timeIntervalSince(recent) < 5 {
            return true
        }
        let sentAt = Date()
        ws.sendPing(Data(), promise: nil)
        while Date().timeIntervalSince(sentAt) < timeout {
            try? await Task.sleep(for: .milliseconds(200))
            if let pong = lastPong[userID], pong >= sentAt { return true }
            if sockets[userID] !== ws { return false }
        }
        return false
    }

    /// Force-close a connection whose heartbeats have gone silent. Bumps the
    /// generation so any pending offline-grace task for the old socket no-ops.
    func expire(_ userID: UUID) async {
        if let ws = sockets.removeValue(forKey: userID) {
            try? await ws.close(code: .goingAway)
        }
        endpoints[userID] = nil
        generations[userID, default: 0] += 1
    }

    func send(_ frame: ServerFrame, to userID: UUID) async {
        guard let ws = sockets[userID],
              let data = try? WireCoder.encoder().encode(frame)
        else { return }
        try? await ws.send(raw: data, opcode: .binary)
    }
}
