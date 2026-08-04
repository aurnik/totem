import Foundation

/// A service that speaks in chats. Bots have no presence and are never buddies
/// or session participants — they only answer when a message tags them. The
/// server owns the registry and ships it in the `welcome` frame, so adding a
/// bot never requires a client build: clients learn the tags to bold and the
/// names to render from the wire.
public struct Bot: Codable, Identifiable, Hashable, Sendable {
    public let id: UUID
    public var handle: String
    public var displayName: String
    /// Every tag that invokes this bot, lowercased and including the leading
    /// "@" — e.g. ["@gemini", "@g", "@gemini_", "@g_"].
    public var aliases: [String]
    /// The subset of `aliases` that also sends the conversation so far. The
    /// server stores no messages, so this context can only come from the
    /// sender's own client — which is why the tag has to be declared here,
    /// where both sides can see it, rather than inferred by either alone.
    public var contextAliases: [String]

    public init(id: UUID, handle: String, displayName: String, aliases: [String],
                contextAliases: [String] = []) {
        self.id = id
        self.handle = handle
        self.displayName = displayName
        self.aliases = aliases
        self.contextAliases = contextAliases
    }

    /// Tolerant of a peer that predates `contextAliases`, which then simply
    /// means "no tag asks for context".
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
/// from its own transcript — the server has nothing to build it from.
public struct BotContextMessage: Codable, Hashable, Sendable {
    /// Handle, or a bot's display name. Not an ID: this is for a language
    /// model to read, not for anything to resolve.
    public var speaker: String
    public var body: String

    public init(speaker: String, body: String) {
        self.speaker = speaker
        self.body = body
    }
}

/// Matching a bot tag has to give the same answer on the server, which decides
/// whether a bot runs, and on the client, which bolds the tag it expects to
/// have run. One implementation, no drift.
public enum BotTag {
    /// The tag as the sender typed it, and the prompt that follows it.
    public struct Match: Hashable, Sendable {
        /// The matched alias in the sender's own casing, so bolding lines up
        /// with the characters on screen.
        public let tag: String
        /// Everything after the tag, trimmed. Empty is a legitimate match —
        /// tagging a bot and saying nothing still deserves an answer.
        public let prompt: String
        /// Where `tag` sits in the original body, for styling it in place.
        public let tagRange: Range<String.Index>
    }

    /// Matches only at the start of the body (leading whitespace ignored), and
    /// only when the alias is followed by whitespace or the end of the string —
    /// otherwise "@general" would invoke the bot registered as "@g". Longer
    /// aliases win so "@gemini" isn't shadowed by "@g".
    public static func match(_ body: String, aliases: [String]) -> Match? {
        guard let start = body.firstIndex(where: { !$0.isWhitespace }) else { return nil }
        let rest = body[start...]
        for alias in aliases.sorted(by: { $0.count > $1.count }) {
            guard !alias.isEmpty, rest.count >= alias.count else { continue }
            let end = rest.index(start, offsetBy: alias.count)
            guard rest[start..<end].lowercased() == alias.lowercased() else { continue }
            // A tag has to end where a word ends, or "@g" eats "@general".
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
