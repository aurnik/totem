import Fluent
import Foundation
import TotemKit
import Vapor

/// The bots this server runs and the backend behind each. Loaded once at boot.
/// A bot without a working backend is not registered, so clients never bold a
/// tag that would get no answer.
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
                    logger.notice("Bot '\(model.handle)' has no usable backend; not registered.")
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
        switch model.handle {
        case "gemini":
            return GeminiBackend.isConfigured
                ? GeminiBackend(client: client, logger: logger) : nil
        default:
            return nil
        }
    }

    func all() -> [Bot] { bots }

    func aliases() -> [String] { bots.flatMap(\.aliases) }

    func match(_ body: String) -> (bot: Bot, prompt: String, wantsContext: Bool)? {
        guard let hit = BotTag.match(body, bots: bots) else { return nil }
        return (hit.bot,
                String(hit.match.prompt.prefix(Limits.botPromptMaxLength)),
                hit.bot.wantsContext(hit.match.tag))
    }

    func backend(for botID: UUID) -> (any BotBackend)? { backends[botID] }
}
