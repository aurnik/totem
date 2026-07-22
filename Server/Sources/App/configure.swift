import Fluent
import FluentSQLiteDriver
import Redis
import Vapor

func configure(_ app: Application) async throws {
    app.databases.use(.sqlite(.file("db.sqlite")), as: .sqlite)
    app.redis.configuration = try RedisConfiguration(
        hostname: Environment.get("REDIS_HOST") ?? "localhost")

    app.migrations.add(CreateSchema())
    app.migrations.add(AddSessionParticipants())
    app.migrations.add(DropMessageStorage())
    try await app.autoMigrate()

    let connections = ConnectionManager()
    let gateway = GatewayController(app: app, connections: connections)

    let authed = app.grouped(TokenAuthenticator(), UserModel.guardMiddleware())
    try authed.register(collection: BuddyController(gateway: gateway))
    try authed.register(collection: SessionController(gateway: gateway))
    authed.webSocket("ws") { req, ws in
        await gateway.handleUpgrade(req: req, ws: ws)
    }
    try app.register(collection: AuthController())

    gateway.startLivenessSweep()
}
