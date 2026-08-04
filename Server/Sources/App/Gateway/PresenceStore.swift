import Foundation
import Redis
import TotemKit
import Vapor

/// Presence lives in Redis, not the database: one key per user with a 90s TTL
/// refreshed by heartbeats (spec §4). Key expiry *is* the offline timeout.
struct PresenceStore {
    let redis: RedisClient

    /// Expiry of this key *is* the offline timeout, so the grace period the
    /// gateway waits out before reaping a dropped socket matches it.
    static let ttlSeconds = 90

    private func presenceKey(_ userID: UUID) -> RedisKey { "presence:\(userID.uuidString)" }

    func set(_ presence: Presence, for userID: UUID) async throws {
        let json = String(decoding: try WireCoder.encoder().encode(presence), as: UTF8.self)
        _ = try await redis.set(
            presenceKey(userID), to: json,
            onCondition: .none, expiration: .seconds(Self.ttlSeconds)
        ).get()
    }

    func refresh(for userID: UUID) async throws {
        _ = try await redis.expire(presenceKey(userID), after: .seconds(Int64(Self.ttlSeconds))).get()
    }

    func get(for userID: UUID) async throws -> Presence {
        guard let json = try await redis.get(presenceKey(userID), as: String.self).get() else {
            return .offline
        }
        return try WireCoder.decoder().decode(Presence.self, from: Data(json.utf8))
    }

    func markOffline(for userID: UUID) async throws {
        _ = try await redis.delete(presenceKey(userID)).get()
    }
}
