import Foundation
import Redis
import TotemKit
import Vapor

/// Which conversations are live. A conversation row is permanent; a sitting is
/// one open stretch of chat, starting with the first activity and ending when
/// fewer than two participants remain online. It lives in Redis beside
/// presence so restarts do not end every group chat.
struct SittingStore {
    let redis: RedisClient

    /// One hash rather than a key per sitting: the death check and the welcome
    /// snapshot both read the whole set.
    private static let key: RedisKey = "sittings"

    struct Sitting: Codable {
        let participants: [UUID]
        let startedAt: Date
    }

    /// Opens the sitting if it is not already open and returns the authoritative
    /// one either way. HSETNX, so concurrent opens converge on one `startedAt`.
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
