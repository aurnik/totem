import Fluent
import FluentSQLiteDriver
import Redis
import Vapor

func configure(_ app: Application) async throws {
    app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
    app.redis.configuration = try RedisConfiguration(
        hostname: Environment.get("REDIS_HOST") ?? "localhost")

    app.migrations.add(CreateSchema())
    try await app.autoMigrate()

    let connections = ConnectionManager()
    let gateway = GatewayController(app: app, connections: connections)

    let authed = app.grouped(TokenAuthenticator(), UserModel.guardMiddleware())
    try authed.register(collection: BuddyController(gateway: gateway))
    authed.webSocket("ws") { req, ws in
        await gateway.handleUpgrade(req: req, ws: ws)
    }
    try app.register(collection: AuthController())

    gateway.startLivenessSweep()
    startMessageRetentionSweep(app)
}

/// Messages persist server-side for 24h to cover reconnects and offline
/// delivery, then hard-delete (spec §5). The client keeps its own archive.
private func startMessageRetentionSweep(_ app: Application) {
    Task.detached {
        while !Task.isCancelled {
            do {
                let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
                try await MessageModel.query(on: app.db)
                    .filter(\.$sentAt < cutoff)
                    .delete()
            } catch {
                app.logger.report(error: error)
            }
            try? await Task.sleep(for: .seconds(3600))
        }
    }
}
