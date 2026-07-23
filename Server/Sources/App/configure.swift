import Fluent
import FluentSQLiteDriver
import Redis
import Vapor

func configure(_ app: Application) async throws {
    // Boot-stage markers on print (not the logger): a crash between two
    // stages is findable in container logs even when the logger's output
    // is rate-limited away by the host.
    print("configure: db")
    app.databases.use(
        .sqlite(.file(Environment.get("DB_PATH") ?? "db.sqlite")), as: .sqlite)
    print("configure: redis")
    app.redis.configuration = try await resolveRedis()

    print("configure: migrate")
    app.migrations.add(CreateSchema())
    app.migrations.add(AddSessionParticipants())
    app.migrations.add(DropMessageStorage())
    try await app.autoMigrate()
    print("configure: routes")

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
    print("configure: done")
}

/// `RedisConfiguration(url:)` resolves the hostname eagerly, and Railway's
/// private DNS (`*.railway.internal`) isn't up for the first moments after
/// container start — retry it, then fall back to the public proxy URL.
private func resolveRedis() async throws -> RedisConfiguration {
    guard let redisURL = Environment.get("REDIS_URL") else {
        return try RedisConfiguration(hostname: Environment.get("REDIS_HOST") ?? "localhost")
    }
    var lastError: Error?
    for attempt in 1...10 {
        do {
            return try RedisConfiguration(url: redisURL)
        } catch {
            lastError = error
            print("configure: redis resolve attempt \(attempt) failed: \(error)")
            try? await Task.sleep(for: .seconds(1))
        }
    }
    if let publicURL = Environment.get("REDIS_PUBLIC_URL") {
        print("configure: falling back to public redis URL")
        return try RedisConfiguration(url: publicURL)
    }
    throw lastError!
}
