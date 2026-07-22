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

    func register(_ ws: WebSocket, for userID: UUID) async -> Int {
        if let old = sockets[userID] {
            try? await old.close(code: .policyViolation)
        }
        sockets[userID] = ws
        let generation = (generations[userID] ?? 0) + 1
        generations[userID] = generation
        return generation
    }

    func unregister(_ userID: UUID, ifStill ws: WebSocket) {
        if sockets[userID] === ws {
            sockets[userID] = nil
        }
    }

    func isConnected(_ userID: UUID) -> Bool {
        sockets[userID] != nil
    }

    func generation(of userID: UUID) -> Int {
        generations[userID] ?? 0
    }

    func send(_ frame: ServerFrame, to userID: UUID) async {
        guard let ws = sockets[userID],
              let data = try? WireCoder.encoder().encode(frame)
        else { return }
        try? await ws.send(raw: data, opcode: .binary)
    }
}
