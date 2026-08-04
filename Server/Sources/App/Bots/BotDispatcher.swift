import Fluent
import Foundation
import Redis
import TotemKit
import Vapor

/// Turns a tagged message into exactly one bot reply.
///
/// The contract, and the reason this type exists rather than a call inlined
/// into the gateway: **an invocation always ends in a message.** Success,
/// upstream failure, timeout, and rate-limiting all produce a bubble in the
/// conversation. Nothing here may return early once a tag has matched, because
/// the sender is watching a thinking indicator that only a message clears.
struct BotDispatcher: Sendable {
    let registry: BotRegistry
    let app: Application
    /// How the reply gets to everyone — the gateway owns fan-out and keying.
    let relay: @Sendable (_ botID: UUID, _ sessionID: UUID, _ text: String) async -> Void

    private var redis: RedisClient { app.redis }

    /// Called off the relay path. A slow bot must never delay the human
    /// message that tagged it, so this returns immediately and answers later.
    func dispatch(body: String, from senderID: UUID, sessionID: UUID,
                  context: [BotContextMessage]?) {
        Task { await run(body: body, from: senderID, sessionID: sessionID, context: context) }
    }

    private func run(body: String, from senderID: UUID, sessionID: UUID,
                     context: [BotContextMessage]?) async {
        guard let (bot, prompt, wantsContext) = await registry.match(body) else { return }
        // Past this point every path ends in `relay`.
        let senderHandle = (try? await UserModel.find(senderID, on: app.db))?.handle ?? ""

        guard await withinRateLimit(senderID) else {
            await relay(bot.id, sessionID, "Rate limited — try again in a minute.")
            return
        }
        guard let backend = await registry.backend(for: bot.id) else {
            await relay(bot.id, sessionID, BotError.notConfigured.spokenText)
            return
        }

        // Cap what the client sent rather than trusting it: the transcript
        // arrives over the wire, so its size is not ours until we bound it.
        let history = wantsContext
            ? Array((context ?? []).suffix(Limits.botContextMaxMessages))
            : []
        let invocation = BotInvocation(
            bot: bot, sessionID: sessionID, senderID: senderID,
            senderHandle: senderHandle, prompt: prompt, context: history)
        let text: String
        do {
            let answer = try await withTimeout(Limits.botResponseTimeout) {
                try await backend.respond(to: invocation)
            }
            text = String(plainText(answer).prefix(Limits.botReplyMaxLength))
        } catch let error as BotError {
            app.logger.warning("Bot \(bot.handle) failed: \(error)")
            text = error.spokenText
        } catch {
            app.logger.report(error: error)
            text = BotError.upstream("\(error)").spokenText
        }
        await relay(bot.id, sessionID, text)
    }

    /// A rolling per-minute cap, counted in Redis so it holds across the whole
    /// deployment rather than per process. A failure to reach Redis lets the
    /// call through — the cap is there to stop runaway spend, not to be a gate
    /// that breaks chat when Redis hiccups.
    private func withinRateLimit(_ userID: UUID) async -> Bool {
        let key = RedisKey("botrate:\(userID.uuidString)")
        do {
            let count = try await redis.increment(key).get()
            if count == 1 {
                _ = try await redis.expire(key, after: .seconds(60)).get()
            }
            return count <= Limits.botInvocationsPerMinute
        } catch {
            app.logger.report(error: error)
            return true
        }
    }
}

/// A chat bubble renders one run of plain text, so markdown arrives as literal
/// asterisks and hashes. Instructing a model not to emit any is unreliable —
/// open-ended "explain X" prompts come back as numbered lists however firmly
/// the system prompt forbids it — and a webhook bot is under no obligation to
/// try. Flattening here makes the guarantee structural, and applies to every
/// backend rather than to whichever one remembered.
func plainText(_ text: String) -> String {
    var out = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        // Strip a leading list marker: "- ", "* ", "1. ", "2) ".
        if let marker = trimmed.range(
            of: #"^([-*+•]|\d+[.)])\s+"#, options: .regularExpression) {
            trimmed.removeSubrange(marker)
        }
        // Strip heading hashes.
        if let hashes = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            trimmed.removeSubrange(hashes)
        }
        guard !trimmed.isEmpty else { continue }
        out += out.isEmpty ? trimmed : " " + trimmed
    }
    // Emphasis markers, once lines are joined. Backticks go too — code spans
    // have nothing to render against here either.
    for marker in ["**", "__", "`"] {
        out = out.replacingOccurrences(of: marker, with: "")
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Races the work against a deadline. `Limits.botResponseTimeout` is the
/// promise the thinking indicator is making to the sender, so it's enforced
/// here rather than left to whatever the backend's own client does.
func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                              _ work: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw BotError.timedOut
        }
        guard let first = try await group.next() else { throw BotError.timedOut }
        group.cancelAll()
        return first
    }
}
