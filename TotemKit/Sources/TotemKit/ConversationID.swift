import Foundation

/// A conversation's identity is the UUIDv5 of its sorted participant IDs, for
/// pairs and groups alike. Both ends compute it locally, so opening a chat
/// needs no round trip. A derived ID is computable by anyone and so is not a
/// capability: every frame naming one is membership-checked.
public enum ConversationID {
    /// Frozen: changing it re-keys every conversation in existence.
    public static let namespace = UUID(uuidString: "7B0FD8AE-2D8A-4F0B-96D2-D30A2E0B6ED9")!

    /// Participants are treated as a set, in any order.
    public static func derive(_ participants: some Sequence<UUID>) -> UUID {
        var name = uuidBytes(namespace)
        let sorted = Set(participants).map(uuidBytes).sorted { lhs, rhs in
            for (l, r) in zip(lhs, rhs) where l != r { return l < r }
            return false
        }
        for bytes in sorted {
            name.append(contentsOf: bytes)
        }
        var digest = SHA1.hash(name)
        digest[6] = (digest[6] & 0x0F) | 0x50  // version 5
        digest[8] = (digest[8] & 0x3F) | 0x80  // RFC 4122 variant
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                           digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11],
                           digest[12], digest[13], digest[14], digest[15]))
    }

    private static func uuidBytes(_ id: UUID) -> [UInt8] {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }
}

/// Just enough SHA-1 for UUIDv5 (RFC 4122 4.3): name hashing, not security.
/// Embedded because CryptoKit is unavailable on Linux, where the server builds.
private enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var data = message
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        let bitLength = UInt64(message.count) * 8
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        for chunk in stride(from: 0, to: data.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let o = chunk + i * 4
                w[i] = UInt32(data[o]) << 24 | UInt32(data[o + 1]) << 16
                    | UInt32(data[o + 2]) << 8 | UInt32(data[o + 3])
            }
            for i in 16..<80 {
                w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1)
            }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32) = switch i {
                case 0..<20: ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, temp)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e
        }
        return h.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ((3 - $0) * 8)) }
        }
    }

    private static func rotl(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value << amount) | (value >> (32 - amount))
    }
}
