import Fluent
import FluentSQLiteDriver
import Redis
import Vapor

func configure(_ app: Application) async throws {
    app.databases.use(
        .sqlite(.file(Environment.get("DB_PATH") ?? "db.sqlite")), as: .sqlite)
    if let redisURL = Environment.get("REDIS_URL") {
        app.redis.configuration = try RedisConfiguration(url: redisURL)
    } else {
        app.redis.configuration = try RedisConfiguration(
            hostname: Environment.get("REDIS_HOST") ?? "localhost")
    }

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
    try app.register(collection: OnboardController())

    gateway.startLivenessSweep()
}
