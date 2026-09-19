import Foundation

/// A service that speaks in chats. Bots have no presence, are never buddies or
/// session participants, and answer only when a message tags them. The server
/// owns the registry and ships it in `welcome`, so adding a bot needs no
/// client build.
public struct Bot: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var displayName: String
    /// Every tag that invokes this bot, lowercased and including the leading "@".
    public var aliases: [String]
    /// The subset of `aliases` that also sends the conversation so far. Declared
    /// here because only the sender's client can supply that context, and both
    /// sides have to agree on which tags ask for it.
    public var contextAliases: [String]

    public init(id: UUID, handle: String, displayName: String, aliases: [String],
                contextAliases: [String] = []) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.aliases = aliases
        self.contextAliases = contextAliases
    }

    /// Absent `contextAliases` means no tag asks for context.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        handle = try c.decode(String.self, forKey: .handle)
        displayName = try c.decode(String.self, forKey: .displayName)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        contextAliases = try c.decodeIfPresent([String].self, forKey: .contextAliases) ?? []
    }

    /// Whether a tag as typed asks for the conversation to be sent along.
    public func wantsContext(_ tag: String) -> Bool {
        contextAliases.contains { $0.lowercased() == tag.lowercased() }
    }
}

/// One prior message, flattened for a bot prompt. Built by the sender's client
/// from its own transcript.
public struct BotContextMessage: Codable, Hashable, Sendable {
    /// Handle, or a bot's display name: read by a language model, not resolved.
    public var speaker: String
    public var body: String

    public init(speaker: String, body: String) {
        self.speaker = speaker
        self.body = body
    }
}

/// Bot tag matching, shared so the server (which decides whether a bot runs)
/// and the client (which bolds the tag) cannot disagree.
public enum BotTag {
    /// The tag as the sender typed it, and the prompt that follows it.
    public struct Match: Hashable, Sendable {
        /// The matched alias in the sender's own casing, so bolding lines up on screen.
        public let tag: String
        /// Everything after the tag, trimmed. May be empty.
        public let prompt: String
        /// Where `tag` sits in the original body, for styling it in place.
        public let tagRange: Range<String.Index>
    }

    /// Matches only at the start of the body, with the alias followed by
    /// whitespace or the end of the string. Longer aliases are tried first.
    public static func match(_ body: String, aliases: [String]) -> Match? {
        guard let start = body.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let rest = body[start...]
        for alias in aliases.sorted(by: { $0.count > $1.count }) {
            guard !alias.isEmpty, rest.count >= alias.count else { continue }
            let end = rest.index(start, offsetBy: alias.count)
            guard rest[start..<end].lowercased() == alias.lowercased() else { continue }
            guard end == rest.endIndex || rest[end].isWhitespace else { continue }
            return Match(
                tag: String(body[start..<end]),
                prompt: String(body[end...]).trimmingCharacters(in: .whitespacesAndNewlines),
                tagRange: start..<end)
        }
        return nil
    }

    /// The bot a body invokes, if any.
    public static func match(_ body: String, bots: [Bot]) -> (bot: Bot, match: Match)? {
        for bot in bots {
            if let m = match(body, aliases: bot.aliases) { return (bot, m) }
        }
        return nil
    }
}
