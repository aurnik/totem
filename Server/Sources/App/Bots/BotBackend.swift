import Foundation
import TotemKit

/// One tagged message, everything a backend gets to work with. Stateless by
/// design: no transcript, no history. The server stores no messages, so there
/// is nothing to give a bot beyond what it was just told.
struct BotInvocation: Sendable {
    let bot: Bot
    let sessionID: UUID
    let senderID: UUID
    let senderHandle: String
    /// The text after the tag, already trimmed and length-capped.
    let prompt: String
    /// The conversation so far, oldest first — present only when the tag asked
    /// for it. Supplied by the sender's client, since the server holds no
    /// transcript, and used only to build this one prompt.
    let context: [BotContextMessage]
}

/// How a bot produces its answer. `GeminiBackend` today; a `WebhookBackend`
/// that POSTs the invocation to a user-supplied endpoint slots in here with no
/// changes above it.
///
/// A bot always answers. Backends return text or throw — never nothing — and
/// the dispatcher turns a throw into the bot's spoken error, so every
/// invocation puts exactly one bubble in the conversation.
protocol BotBackend: Sendable {
    func respond(to invocation: BotInvocation) async throws -> String
}

enum BotError: Error {
    case notConfigured
    case upstream(String)
    case emptyResponse
    case timedOut

    /// What lands in the chat when there's no answer. Stated as a fact about
    /// the service, not spoken by a character: a bot is a lookup that returned
    /// nothing, not a participant apologising.
    var spokenText: String {
        switch self {
        case .notConfigured: "Not configured on this server."
        case .timedOut: "No response — the request timed out."
        case .upstream, .emptyResponse: "No response available."
        }
    }
}
