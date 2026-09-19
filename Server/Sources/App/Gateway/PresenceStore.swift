import Foundation
import Redis
import TotemKit
import Vapor

/// Presence in Redis: one key per user, refreshed by heartbeats. Key expiry is
/// the offline timeout.
struct PresenceStore {
    let redis: RedisClient

    /// Key expiry is the offline timeout, and the gateway's reconnect grace
    /// period matches it.
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

    /// Annotates an existing presence without extending its lifetime. `SET XX
    /// KEEPTTL`, because a server-side observation about a user is not evidence
    /// they are alive, and an already-expired key must stay expired.
    ///
    /// Returns false when the key had expired and nothing was written: the user
    /// is offline, not away.
    @discardableResult
    func annotate(_ presence: Presence, for userID: UUID) async throws -> Bool {
        let json = String(decoding: try WireCoder.encoder().encode(presence), as: UTF8.self)
        let response = try await redis.send(command: "SET", with: [
            presenceKey(userID).rawValue.convertedToRESPValue(),
            json.convertedToRESPValue(),
            "XX".convertedToRESPValue(),
            "KEEPTTL".convertedToRESPValue(),
        ]).get()
        return !response.isNull
    }

    func get(for userID: UUID) async throws -> Presence {
        guard let json = try await redis.get(presenceKey(userID), as: String.self).get() else {
            return .offline
        }
        return try WireCoder.decoder().decode(Presence.self, from: Data(json.utf8))
    }

    /// How many of `userIDs` are signed on. Any existing key counts, so away
    /// still counts as present.
    func presentCount(among userIDs: [UUID]) async throws -> Int {
        guard !userIDs.isEmpty else { return 0 }
        return try await redis.mget(userIDs.map(presenceKey)).get().filter { !$0.isNull }.count
    }

    func markOffline(for userID: UUID) async throws {
        _ = try await redis.delete(presenceKey(userID)).get()
    }
}
