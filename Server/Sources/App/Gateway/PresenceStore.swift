import Foundation
import Redis
import TotemKit
import Vapor

/// Presence lives in Redis, not the database: one key per user with a 90s TTL
/// refreshed by heartbeats (spec §4). Key expiry *is* the offline timeout.
struct PresenceStore {
    let redis: RedisClient

    static let ttl: TimeAmount = .seconds(90)

    private func presenceKey(_ userID: UUID) -> RedisKey { "presence:\(userID.uuidString)" }
    private func lastSeenKey(_ userID: UUID) -> RedisKey { "lastseen:\(userID.uuidString)" }

    func set(_ presence: Presence, for userID: UUID) async throws {
        let json = String(decoding: try WireCoder.encoder().encode(presence), as: UTF8.self)
        _ = try await redis.set(
            presenceKey(userID), to: json,
            onCondition: .none, expiration: .seconds(90)
        ).get()
    }

    func refresh(for userID: UUID) async throws {
        _ = try await redis.expire(presenceKey(userID), after: Self.ttl).get()
    }

    func get(for userID: UUID) async throws -> Presence {
        guard let json = try await redis.get(presenceKey(userID), as: String.self).get() else {
            let lastSeen = try await redis.get(lastSeenKey(userID), as: String.self).get()
                .flatMap { Double($0) }
                .map { Date(timeIntervalSince1970: $0) }
            return Presence(state: .offline, lastSeenAt: lastSeen)
        }
        return try WireCoder.decoder().decode(Presence.self, from: Data(json.utf8))
    }

    func markOffline(for userID: UUID) async throws {
        _ = try await redis.delete(presenceKey(userID)).get()
        _ = try await redis.set(lastSeenKey(userID), to: String(Date().timeIntervalSince1970)).get()
    }
}
