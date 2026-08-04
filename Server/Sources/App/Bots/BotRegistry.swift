import Fluent
import Foundation
import TotemKit
import Vapor

/// Which bots this server runs, and how to reach each one. Loaded once at boot
/// and held in memory — the table changes only by migration today, and by an
/// explicit reload when users can register webhook bots.
///
/// A bot in the table but without a working backend is deliberately *not*
/// registered: clients only learn about bots that can actually answer, so they
/// never bold a tag that will be met with silence.
actor BotRegistry {
    private var bots: [Bot] = []
    private var backends: [UUID: any BotBackend] = [:]

    func load(db: Database, client: Client, logger: Logger) async {
        do {
            var loaded: [Bot] = []
            var wired: [UUID: any BotBackend] = [:]
            for model in try await BotModel.query(on: db).all() {
                guard let id = model.id else { continue }
                guard let backend = Self.backend(for: model, client: client, logger: logger) else {
                    logger.notice("Bot '\(model.handle)' has no usable backend — not registered.")
                    continue
                }
                loaded.append(model.dto)
                wired[id] = backend
            }
            bots = loaded
            backends = wired
            logger.info("Bots registered: \(loaded.map(\.handle).joined(separator: ", "))")
        } catch {
            logger.report(error: error)
        }
    }

    private static func backend(for model: BotModel, client: Client,
                                logger: Logger) -> (any BotBackend)? {
        switch BotKind(rawValue: model.kind) {
        case .builtin:
            // Built-ins are known by handle; an unknown one is a row from a
            // newer deploy and is skipped rather than guessed at.
            switch model.handle {
            case "gemini":
                return GeminiBackend.isConfigured
                    ? GeminiBackend(client: client, logger: logger) : nil
            default:
                return nil
            }
        case .webhook:
            // TODO: WebhookBackend — POST the invocation to model.endpoint,
            // signed with model.secret. The reply is still mandatory.
            return nil
        case nil:
            return nil
        }
    }

    func all() -> [Bot] { bots }

    /// Every tag across every registered bot, for callers that only need to
    /// know whether a body tags *something*.
    func aliases() -> [String] { bots.flatMap(\.aliases) }

    func match(_ body: String) -> (bot: Bot, prompt: String, wantsContext: Bool)? {
        guard let hit = BotTag.match(body, bots: bots) else { return nil }
        return (hit.bot,
                String(hit.match.prompt.prefix(Limits.botPromptMaxLength)),
                hit.bot.wantsContext(hit.match.tag))
    }

    func backend(for botID: UUID) -> (any BotBackend)? { backends[botID] }
}
