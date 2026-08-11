import Foundation
import Redis
import TotemKit
import Vapor

/// Which conversations are live right now. A conversation row is permanent —
/// the combination of people always names it — but a *sitting* is one open
/// stretch of chat: it starts with the first activity and ends when fewer than
/// two participants remain online. That's a fact about the present, so it
/// lives in Redis beside presence, not in a column — a deploy restarts the
/// process several times a day and must not end every group chat in the app,
/// and a liveness bit written to the database would have to be reconciled
/// against presence forever.
struct SittingStore {
    let redis: RedisClient

    /// One hash rather than a key per sitting: the death check and the welcome
    /// snapshot both want the whole (tiny) set, and a single structure can't
    /// drift out of sync with its own index.
    private static let key: RedisKey = "sittings"

    struct Sitting: Codable {
        let participants: [UUID]
        let startedAt: Date
    }

    /// Opens the sitting if it isn't already open, and returns the authoritative
    /// one either way — HSETNX, so concurrent opens converge on one `startedAt`
    /// instead of the last write's.
    @discardableResult
    func open(_ conversationID: UUID, participants: [UUID], at now: Date) async throws -> Sitting {
        let sitting = Sitting(participants: participants, startedAt: now)
        let json = String(decoding: try WireCoder.encoder().encode(sitting), as: UTF8.self)
        let created = try await redis.hsetnx(
            conversationID.uuidString, to: json, in: Self.key).get()
        if created { return sitting }
        return try await get(conversationID) ?? sitting
    }

    func get(_ conversationID: UUID) async throws -> Sitting? {
        guard let json = try await redis.hget(
            conversationID.uuidString, from: Self.key, as: String.self).get()
        else { return nil }
        return try? WireCoder.decoder().decode(Sitting.self, from: Data(json.utf8))
    }

    func close(_ conversationID: UUID) async throws {
        _ = try await redis.hdel(conversationID.uuidString, from: Self.key).get()
    }

    func all() async throws -> [UUID: Sitting] {
        let raw = try await redis.hgetall(from: Self.key).get()
        var sittings: [UUID: Sitting] = [:]
        for (field, value) in raw {
            guard let id = UUID(uuidString: field), let json = value.string,
                  let sitting = try? WireCoder.decoder().decode(
                      Sitting.self, from: Data(json.utf8))
            else { continue }
            sittings[id] = sitting
        }
        return sittings
    }
}
