import Foundation
import TotemKit

/// One tagged message, all a backend gets. The server stores no messages, so
/// there is no history beyond what the invocation carries.
struct BotInvocation: Sendable {
    let bot: Bot
    let sessionID: UUID
    let senderID: UUID
    let senderHandle: String
    /// The text after the tag, trimmed and length-capped.
    let prompt: String
    /// The conversation so far, oldest first, present only when the tag asked
    /// for it. Supplied by the sender's client and used for this prompt alone.
    let context: [BotContextMessage]
}

/// How a bot produces its answer. A backend returns text or throws, never
/// nothing, and the dispatcher turns a throw into the bot's spoken error, so
/// every invocation puts one bubble in the conversation.
protocol BotBackend: Sendable {
    func respond(to invocation: BotInvocation) async throws -> String
}

enum BotError: Error {
    case notConfigured
    case upstream(String)
    case emptyResponse
    case timedOut

    /// What lands in the chat when there is no answer. Phrased as a fact about
    /// the service, since a bot is not a participant.
    var spokenText: String {
        switch self {
        case .notConfigured: "Not configured on this server."
        case .timedOut: "No response — the request timed out."
        case .upstream, .emptyResponse: "No response available."
        }
    }
}
