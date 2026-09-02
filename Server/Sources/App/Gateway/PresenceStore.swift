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

    /// Annotate an existing presence without extending its lifetime. The TTL is
    /// the offline timeout, and a server-side observation *about* a user is not
    /// evidence they're alive — refreshing it here would let repeated send
    /// attempts keep a vanished user's key alive indefinitely. KEEPTTL also
    /// keeps this atomic, so a key that expires mid-call stays expired rather
    /// than being resurrected by a read-then-write.
    ///
    /// Returns false if the key had already expired, in which case nothing was
    /// written: the user is offline, not away, and the caller must not announce
    /// otherwise.
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

    /// How many of `userIDs` are signed on. A key that exists is a user who
    /// is present, whatever state it holds — away is still online.
    func presentCount(among userIDs: [UUID]) async throws -> Int {
        guard !userIDs.isEmpty else { return 0 }
        return try await redis.mget(userIDs.map(presenceKey)).get().filter { !$0.isNull }.count
    }

    func markOffline(for userID: UUID) async throws {
        _ = try await redis.delete(presenceKey(userID)).get()
    }
}
